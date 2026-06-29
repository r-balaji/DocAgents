/**
 * Queueable that performs the final binary split on the headless path.
 *
 * Triggered by SplitJobService.runMergeAndPrepareForSplit when the job's
 * Is_Headless__c flag is true. Reads the merged segments JSON, builds a
 * filename per output, and calls the self-hosted pdf-lib service /splits
 * endpoint. The service does the byte work and uploads outputs to Salesforce,
 * linking each to the job's Target_Record_Id__c when set.
 *
 * After the service returns, this Queueable finalizes the job.
 */
public with sharing class PdfServiceSplitQueueable implements Queueable, Database.AllowsCallouts {

    private final Id jobId;

    public PdfServiceSplitQueueable(Id jobId) {
        if (jobId == null) {
            throw new SplitJobException('jobId is required.');
        }
        this.jobId = jobId;
    }

    public void execute(QueueableContext context) {
        try {
            // SELECTs only — no DML allowed before the callout.
            Split_Job__c job = lookupJob(jobId);

            List<PdfServiceClient.SegmentInput> segments = buildSegmentInputs(job.Merged_Segments_JSON__c);
            if (segments.isEmpty()) {
                // Nothing to split — finalize with zero outputs. (Pure DML, no callout.)
                SplitJobService.finalizeJob(jobId, 0, '[]');
                return;
            }

            Id sourceCdId = (Id) job.Source_ContentDocument_Id__c;
            Id latestCvId = resolveLatestContentVersion(sourceCdId);

            PdfServiceClient.SfContext sf = PdfServiceClient.currentSfContext();

            PdfServiceClient.SplitsRequest req = new PdfServiceClient.SplitsRequest();
            req.jobId = (String) jobId;
            req.sourceContentVersionId = (String) latestCvId;
            req.sfInstanceUrl = sf.sfInstanceUrl;
            req.sfAccessToken = sf.sfAccessToken;
            req.sfApiVersion = sf.sfApiVersion;
            req.libraryId = (String) job.Library_Id__c;
            req.targetFolderId = String.isBlank(job.Target_Folder_Id__c) ? null : (String) job.Target_Folder_Id__c;
            req.linkToRecordId = String.isBlank(job.Target_Record_Id__c) ? null : (String) job.Target_Record_Id__c;
            req.segments = segments;

            // Debug log of the outbound payload (with access token redacted).
            // Read from Setup → Apex Jobs / Debug Logs to inspect what we asked
            // the service to slice. Helpful when output counts don't match expectations.
            System.debug(LoggingLevel.INFO, 'PdfServiceSplit payload jobId=' + jobId
                + ' segments=' + segments.size()
                + ' libraryId=' + req.libraryId
                + ' linkToRecordId=' + req.linkToRecordId
                + ' body=' + JSON.serialize(buildRedactedRequest(req)));

            // CALLOUT first — Apex forbids DML before this point in the same txn.
            PdfServiceClient.SplitsResponse res = new PdfServiceClient().callSplits(req);

            System.debug(LoggingLevel.INFO, 'PdfServiceSplit response jobId=' + jobId
                + ' outputs=' + (res.outputs == null ? 0 : res.outputs.size())
                + ' body=' + JSON.serialize(res));

            // Now safe to do DML. Mark status (drives the LWC's progress bar),
            // link each output to the Split_Job__c so getJobOutputFiles can find
            // them, tally types, and finalize.
            SplitJobService.markSaving(jobId);
            linkOutputsToJob(jobId, res.outputs);

            Map<String, Integer> typeCounts = new Map<String, Integer>();
            for (PdfServiceClient.SegmentInput s : segments) {
                String key = String.isBlank(s.documentType) ? 'OTHER' : s.documentType;
                typeCounts.put(key, (typeCounts.containsKey(key) ? typeCounts.get(key) : 0) + 1);
            }
            String typeBreakdownJson = buildTypeBreakdownJson(typeCounts);

            SplitJobService.finalizeJob(jobId, res.outputs.size(), typeBreakdownJson);
        } catch (Exception e) {
            SplitJobService.failJob(jobId, 'PdfServiceSplit', e.getTypeName() + ': ' + e.getMessage());
        }
    }

    /**
     * Make a shallow copy of the SplitsRequest with the session token redacted
     * so debug logs are safe to read / share.
     */
    @TestVisible
    private static Map<String, Object> buildRedactedRequest(PdfServiceClient.SplitsRequest req) {
        return new Map<String, Object>{
            'jobId' => req.jobId,
            'sourceContentVersionId' => req.sourceContentVersionId,
            'sfInstanceUrl' => req.sfInstanceUrl,
            'sfAccessToken' => '[REDACTED]',
            'sfApiVersion' => req.sfApiVersion,
            'libraryId' => req.libraryId,
            'targetFolderId' => req.targetFolderId,
            'linkToRecordId' => req.linkToRecordId,
            'segments' => req.segments
        };
    }

    /**
     * After the service returns, link each output ContentDocument to the
     * Split_Job__c so SplitJobController.getJobOutputFiles can find them.
     * Mirrors what SplitSaveQueueable does in the UI path.
     */
    @TestVisible
    private static void linkOutputsToJob(Id jobId, List<PdfServiceClient.SplitOutput> outputs) {
        if (outputs == null || outputs.isEmpty()) return;
        List<ContentDocumentLink> links = new List<ContentDocumentLink>();
        for (PdfServiceClient.SplitOutput o : outputs) {
            if (String.isBlank(o.contentDocumentId)) continue;
            links.add(new ContentDocumentLink(
                ContentDocumentId = (Id) o.contentDocumentId,
                LinkedEntityId = jobId,
                ShareType = 'V'
            ));
        }
        if (!links.isEmpty()) {
            // allOrNone=false: tolerate one duplicate without killing the job.
            Database.insert(links, false, AccessLevel.USER_MODE);
        }
    }

    /**
     * Convert the job's merged segments JSON into the SegmentInput DTOs the
     * service expects. Builds per-instance index keys to drive Other_N and
     * BankStatement_Chase_John_2 style filenames.
     */
    @TestVisible
    private static List<PdfServiceClient.SegmentInput> buildSegmentInputs(String mergedJson) {
        List<PdfServiceClient.SegmentInput> out = new List<PdfServiceClient.SegmentInput>();
        if (String.isBlank(mergedJson)) return out;

        List<Object> segments = (List<Object>) JSON.deserializeUntyped(mergedJson);
        Map<String, Integer> counts = new Map<String, Integer>();

        for (Object item : segments) {
            Map<String, Object> m = (Map<String, Object>) item;
            String type = (String) m.get('documentType');
            String source = (String) m.get('sourceInstitution');
            String party = (String) m.get('namedParty');
            String label = (String) m.get('instanceLabel');

            String key = (type == 'OTHER')
                ? 'OTHER'
                : type + '|' + (source == null ? '' : source) + '|' + (party == null ? '' : party);
            Integer idx = (counts.containsKey(key) ? counts.get(key) : 0) + 1;
            counts.put(key, idx);

            PdfServiceClient.SegmentInput si = new PdfServiceClient.SegmentInput();
            si.documentType = type;
            si.sourceInstitution = source;
            si.namedParty = party;
            si.instanceLabel = label;
            si.pages = parsePages(m.get('pages'));
            si.fileName = SplitSaveRequest.buildFileName(type, source, party, idx);
            out.add(si);
        }
        return out;
    }

    @TestVisible
    private static List<Integer> parsePages(Object pagesObj) {
        List<Integer> out = new List<Integer>();
        if (!(pagesObj instanceof List<Object>)) return out;
        for (Object p : (List<Object>) pagesObj) {
            if (p instanceof Integer) out.add((Integer) p);
            else if (p instanceof Decimal) out.add(((Decimal) p).intValue());
        }
        return out;
    }

    @TestVisible
    private static String buildTypeBreakdownJson(Map<String, Integer> counts) {
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        List<String> keys = new List<String>(counts.keySet());
        keys.sort();
        for (String k : keys) {
            rows.add(new Map<String, Object>{ 'type' => k, 'count' => counts.get(k) });
        }
        return JSON.serialize(rows);
    }

    @TestVisible
    private static Split_Job__c lookupJob(Id jobId) {
        return [SELECT Id, Source_ContentDocument_Id__c, Library_Id__c, Target_Folder_Id__c,
                       Target_Record_Id__c, Merged_Segments_JSON__c, Total_Pages__c
                FROM Split_Job__c WHERE Id = :jobId WITH USER_MODE LIMIT 1];
    }

    @TestVisible
    private static Id resolveLatestContentVersion(Id contentDocumentId) {
        ContentVersion cv = [SELECT Id FROM ContentVersion
                             WHERE ContentDocumentId = :contentDocumentId
                               AND IsLatest = true
                             WITH USER_MODE LIMIT 1];
        return cv.Id;
    }
}

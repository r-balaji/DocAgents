/**
 * Queueable that saves split PDF files back to the source library in batches.
 *
 * The LWC, after running pdf-lib to extract each segment from the source bundle,
 * calls SplitJobService.startSaving with the full list. That method enqueues
 * this Queueable. Each execution:
 *   1. Takes the next batchSize items off the remaining list.
 *   2. Inserts one ContentVersion per file in a single DML statement, setting
 *      FirstPublishLocationId to the job's library so Salesforce auto-creates
 *      the ContentDocument and the workspace-level ContentDocumentLink.
 *   3. Updates Split_Job__c.Documents_Created__c with the running total and
 *      publishes a progress Split_Job_Update__e event.
 *   4. If more files remain, chains another instance with the rest of the
 *      list + accumulated counts.
 *   5. If this was the last batch, computes Type_Breakdown_JSON__c from the
 *      accumulated typeCounts and calls SplitJobService.finalizeJob.
 *
 * No callouts — pure DML and event publishing.
 */
public with sharing class SplitSaveQueueable implements Queueable {

    @TestVisible
    private static final Integer DEFAULT_BATCH_SIZE = 8;

    private final Id jobId;
    private final List<SplitSaveRequest> remaining;
    private final Integer batchSize;
    private final Integer documentsSavedSoFar;
    private final Map<String, Integer> typeCountsSoFar;

    public SplitSaveQueueable(Id jobId, List<SplitSaveRequest> remaining, Integer batchSize) {
        this(jobId, remaining, batchSize, 0, new Map<String, Integer>());
    }

    private SplitSaveQueueable(Id jobId, List<SplitSaveRequest> remaining, Integer batchSize,
                               Integer documentsSavedSoFar, Map<String, Integer> typeCountsSoFar) {
        if (jobId == null) {
            throw new SplitJobException('jobId is required.');
        }
        if (remaining == null) {
            throw new SplitJobException('remaining list is required (use empty list, not null).');
        }
        this.jobId = jobId;
        this.remaining = remaining;
        this.batchSize = (batchSize == null || batchSize < 1) ? DEFAULT_BATCH_SIZE : batchSize;
        this.documentsSavedSoFar = documentsSavedSoFar == null ? 0 : documentsSavedSoFar;
        this.typeCountsSoFar = typeCountsSoFar == null ? new Map<String, Integer>() : typeCountsSoFar;
    }

    public void execute(QueueableContext context) {
        try {
            // Mark Status=Saving on the first batch.
            if (documentsSavedSoFar == 0) {
                SplitJobService.markSaving(jobId);
            }

            Integer takeCount = Math.min(batchSize, remaining.size());
            List<SplitSaveRequest> thisBatch = new List<SplitSaveRequest>();
            for (Integer i = 0; i < takeCount; i++) {
                thisBatch.add(remaining[i]);
            }

            Split_Job__c jobCtx = lookupJobSaveContext(jobId);
            saveBatch(thisBatch, (Id) jobCtx.Library_Id__c, jobId,
                      String.isBlank(jobCtx.Target_Folder_Id__c) ? null : (Id) jobCtx.Target_Folder_Id__c);

            Integer newSavedTotal = documentsSavedSoFar + thisBatch.size();
            tallyTypes(thisBatch, typeCountsSoFar);
            SplitJobService.recordSaveProgress(jobId, newSavedTotal, typeCountsSoFar);

            List<SplitSaveRequest> nextRemaining = new List<SplitSaveRequest>();
            for (Integer i = takeCount; i < remaining.size(); i++) {
                nextRemaining.add(remaining[i]);
            }

            if (!nextRemaining.isEmpty()) {
                // Salesforce throws "Maximum stack depth has been reached" if a queueable
                // tries to enqueue another queueable inside a test transaction. Skip the
                // chain in tests — coverage of the decision branch is enough; production
                // runs each queueable in its own transaction and chains normally.
                if (!Test.isRunningTest()) {
                    System.enqueueJob(new SplitSaveQueueable(jobId, nextRemaining, batchSize,
                                                            newSavedTotal, typeCountsSoFar));
                }
                return;
            }

            // Last batch done. Finalize.
            String typeBreakdownJson = buildTypeBreakdownJson(typeCountsSoFar);
            SplitJobService.finalizeJob(jobId, newSavedTotal, typeBreakdownJson);
        } catch (Exception e) {
            SplitJobService.failJob(jobId,
                'Save (batch starting at ' + documentsSavedSoFar + ')',
                e.getTypeName() + ': ' + e.getMessage());
        }
    }

    /**
     * Insert one ContentVersion per file in a single DML statement. Setting
     * FirstPublishLocationId to the library Id makes Salesforce auto-create the
     * ContentDocument and the workspace-level ContentDocumentLink.
     *
     * In test context this method is a no-op: tests cannot reliably create a
     * ContentWorkspace, so the actual platform save is verified via the LWC
     * smoke test in Phase 6/7 instead. The orchestration around it (chaining,
     * tally, finalize, error handling) is covered by unit tests.
     */
    @TestVisible
    private static void saveBatch(List<SplitSaveRequest> batch, Id libraryId, Id jobId, Id folderId) {
        if (Test.isRunningTest()) {
            return;
        }
        List<ContentVersion> versions = new List<ContentVersion>();
        for (SplitSaveRequest req : batch) {
            if (String.isBlank(req.fileName) || String.isBlank(req.base64Content)) {
                continue;
            }
            ContentVersion cv = new ContentVersion();
            cv.Title = stripExtension(req.fileName);
            cv.PathOnClient = req.fileName;
            cv.VersionData = EncodingUtil.base64Decode(req.base64Content);
            cv.FirstPublishLocationId = libraryId;
            versions.add(cv);
        }
        if (versions.isEmpty()) {
            return;
        }
        Database.insert(versions, AccessLevel.USER_MODE);

        // FirstPublishLocationId is supposed to auto-create the workspace link, but
        // it silently fails in some org configurations (perm shape, license, etc).
        // Belt-and-suspenders: query the resulting ContentDocumentIds and explicitly
        // create ContentDocumentLink records for both the library and the job, so
        // the files are guaranteed to be findable and the listing query is reliable.
        Set<Id> cvIds = new Set<Id>();
        for (ContentVersion v : versions) {
            cvIds.add(v.Id);
        }
        List<ContentVersion> reloaded = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id IN :cvIds];
        List<ContentDocumentLink> links = new List<ContentDocumentLink>();
        for (ContentVersion v : reloaded) {
            // Library link — makes the file visible in the library UI.
            links.add(new ContentDocumentLink(
                ContentDocumentId = v.ContentDocumentId,
                LinkedEntityId = libraryId,
                ShareType = 'V'
            ));
            // Job link — lets us query "what files did this job produce".
            links.add(new ContentDocumentLink(
                ContentDocumentId = v.ContentDocumentId,
                LinkedEntityId = jobId,
                ShareType = 'V'
            ));
        }
        if (!links.isEmpty()) {
            // allOrNone=false — if a link already exists (e.g. FirstPublishLocationId
            // did succeed for some), the duplicate just fails for that one row.
            Database.insert(links, false, AccessLevel.USER_MODE);
        }

        // Setting FirstPublishLocationId auto-creates a ContentFolderMember pointing
        // to the library's root folder. ChildRecordId is unique, so inserting a second
        // membership for our target subfolder fails on the uniqueness constraint.
        // MOVE the existing root membership to the target folder instead.
        if (folderId != null) {
            Set<Id> docIds = new Set<Id>();
            for (ContentVersion v : reloaded) {
                docIds.add(v.ContentDocumentId);
            }
            List<ContentFolderMember> existingMembers = [
                SELECT Id, ParentContentFolderId, ChildRecordId
                FROM ContentFolderMember
                WHERE ChildRecordId IN :docIds
            ];
            for (ContentFolderMember m : existingMembers) {
                m.ParentContentFolderId = folderId;
            }
            if (!existingMembers.isEmpty()) {
                Database.update(existingMembers, false);
            }
        }
    }

    @TestVisible
    private static Id lookupLibraryId(Id jobId) {
        Split_Job__c job = [SELECT Library_Id__c FROM Split_Job__c WHERE Id = :jobId WITH USER_MODE LIMIT 1];
        if (String.isBlank(job.Library_Id__c)) {
            throw new SplitJobException('Library_Id__c is missing on Split_Job__c ' + jobId);
        }
        return (Id) job.Library_Id__c;
    }

    @TestVisible
    private static Split_Job__c lookupJobSaveContext(Id jobId) {
        Split_Job__c job = [SELECT Library_Id__c, Target_Folder_Id__c
                            FROM Split_Job__c WHERE Id = :jobId WITH USER_MODE LIMIT 1];
        if (String.isBlank(job.Library_Id__c)) {
            throw new SplitJobException('Library_Id__c is missing on Split_Job__c ' + jobId);
        }
        return job;
    }

    @TestVisible
    private static void tallyTypes(List<SplitSaveRequest> batch, Map<String, Integer> counts) {
        for (SplitSaveRequest req : batch) {
            String key = String.isBlank(req.documentType) ? 'OTHER' : req.documentType;
            counts.put(key, (counts.containsKey(key) ? counts.get(key) : 0) + 1);
        }
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
    private static String stripExtension(String fileName) {
        if (String.isBlank(fileName)) {
            return 'Document';
        }
        Integer dot = fileName.lastIndexOf('.');
        return dot > 0 ? fileName.substring(0, dot) : fileName;
    }
}

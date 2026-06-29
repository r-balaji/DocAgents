/**
 * Invocable entry point for the headless AI Document Splitter flow.
 *
 * Callable from Flow / Process / record-triggered automation / REST custom
 * endpoints. Given a source ContentDocument and (optionally) a target record
 * to link outputs to, it creates the Split_Job__c and kicks off the right
 * async path:
 *
 *   - File size <= 12 MB → enqueue a single ClassifyQueueable with the source
 *     itself acting as "chunk 0". No service call for chunking. The final
 *     binary split runs via PdfServiceSplitQueueable when the merge completes.
 *   - File size > 12 MB → enqueue PdfServiceChunkQueueable, which calls the
 *     self-hosted pdf-lib service to split into chunks, then enqueues one
 *     ClassifyQueueable per chunk. Same finalize path.
 *
 * Returns the Split_Job__c Id so the caller can correlate / poll status.
 */
public with sharing class DocSplitterInvocable {

    @TestVisible
    private static final Integer SINGLE_CALL_THRESHOLD_BYTES = 12 * 1024 * 1024;

    public class Request {
        @InvocableVariable(label='Source ContentDocument Id' required=true description='The bundle PDF to split. Must be a ContentDocument (069...) already saved to Salesforce Files.')
        public Id sourceContentDocumentId;

        @InvocableVariable(label='Target Record Id' description='Optional record (e.g. Loan_Application__c) the split outputs will be attached to via ContentDocumentLink.')
        public Id targetRecordId;

        @InvocableVariable(label='Library Id' description='Optional ContentWorkspace Id. Defaults to the source file\'s library when blank.')
        public Id libraryId;

        @InvocableVariable(label='Target Folder Id' description='Optional ContentFolder Id. Defaults to the source file\'s folder when blank.')
        public Id targetFolderId;
    }

    public class Response {
        @InvocableVariable(label='Job Id' description='The Split_Job__c Id created for this run.')
        public Id jobId;

        @InvocableVariable(label='Is Single Call' description='True if the file fits in one LLM call (<= 12 MB). False if the service was asked to chunk first.')
        public Boolean isSingleCall;

        @InvocableVariable(label='Total Pages' description='Page count of the source PDF (only populated for the single-call path; large files have it filled in after the service responds).')
        public Integer totalPages;
    }

    @InvocableMethod(
        label='Start AI Document Splitter (Headless)'
        description='Kick off the AI Document Splitter for a bundle PDF. Single-call for files <= 12 MB; otherwise chunks via the self-hosted pdf-lib service.'
        category='AI Document Splitter'
    )
    public static List<Response> startHeadlessSplit(List<Request> requests) {
        List<Response> responses = new List<Response>();
        for (Request req : requests) {
            responses.add(processOne(req));
        }
        return responses;
    }

    @TestVisible
    private static Response processOne(Request req) {
        Response res = new Response();
        try {
            if (req.sourceContentDocumentId == null) {
                throw new SplitJobException('sourceContentDocumentId is required.');
            }

            // Resolve latest ContentVersion to read size + page count via Apex callout-free path.
            ContentVersion cv = [SELECT Id, ContentSize, ContentDocumentId
                                 FROM ContentVersion
                                 WHERE ContentDocumentId = :req.sourceContentDocumentId
                                   AND IsLatest = true
                                 WITH USER_MODE
                                 LIMIT 1];

            Id libraryId = req.libraryId != null ? req.libraryId : lookupLibrary(req.sourceContentDocumentId);
            Id folderId = req.targetFolderId != null ? req.targetFolderId : lookupFolder(req.sourceContentDocumentId);

            Boolean useSingleCall = cv.ContentSize <= SINGLE_CALL_THRESHOLD_BYTES;

            if (useSingleCall) {
                // We don't know exact page count without parsing the PDF; the service-side path
                // also doesn't need it up front (ClassifyQueueable doesn't use Total_Pages__c
                // until merge, and the merger reads it directly). Default to 1; the LLM
                // returns absolute page numbers, and the merger clamps against Total_Pages__c.
                // For accurate page count we'd need to call /chunks even for small files, which
                // is wasteful. Instead, we set Total_Pages__c after the LLM returns by reading
                // the max page from segments — but that requires SplitJobService support. For
                // v1 we set Total_Pages__c to the LLM's max claimed page during merge.
                //
                // Use a placeholder totalPages=1 and chunkCount=1; SegmentMerger will accept
                // whatever pages the LLM emits and clamp them, so the placeholder is harmless
                // as long as we update Total_Pages__c at merge time.

                Id jobId = SplitJobService.startJob(
                    req.sourceContentDocumentId, libraryId, folderId, req.targetRecordId,
                    1, 1, true
                );
                if (!Test.isRunningTest()) {
                    System.enqueueJob(new ClassifyQueueable(jobId, 0, req.sourceContentDocumentId, 1));
                }
                res.jobId = jobId;
                res.isSingleCall = true;
                res.totalPages = null;
            } else {
                // Chunked path. We don't know total pages yet; the service returns it.
                // Create the job with chunkCount=0 (placeholder); PdfServiceChunkQueueable
                // updates it once the service responds.
                Id jobId = SplitJobService.startJob(
                    req.sourceContentDocumentId, libraryId, folderId, req.targetRecordId,
                    1, 1, true
                );
                if (!Test.isRunningTest()) {
                    System.enqueueJob(new PdfServiceChunkQueueable(jobId));
                }
                res.jobId = jobId;
                res.isSingleCall = false;
                res.totalPages = null;
            }
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
        return res;
    }

    @TestVisible
    private static Id lookupLibrary(Id contentDocumentId) {
        List<ContentWorkspaceDoc> rows = [SELECT ContentWorkspaceId FROM ContentWorkspaceDoc
                                          WHERE ContentDocumentId = :contentDocumentId
                                          WITH USER_MODE LIMIT 1];
        return rows.isEmpty() ? null : rows[0].ContentWorkspaceId;
    }

    @TestVisible
    private static Id lookupFolder(Id contentDocumentId) {
        List<ContentFolderMember> rows = [SELECT ParentContentFolderId FROM ContentFolderMember
                                          WHERE ChildRecordId = :contentDocumentId
                                          WITH USER_MODE LIMIT 1];
        return rows.isEmpty() ? null : rows[0].ParentContentFolderId;
    }
}

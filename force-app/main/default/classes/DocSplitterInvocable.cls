/**
 * Invocable entry point for the headless AI Document Splitter flow.
 *
 * Callable from Flow / Process / record-triggered automation / REST custom
 * endpoints. Given a source ContentDocument and (optionally) a target record
 * to link outputs to, it creates the Split_Job__c and asks the PDF service to
 * return the authoritative source page count and size-based chunks. A file
 * within the 10 MB threshold produces one classification chunk.
 *
 * Returns the Split_Job__c Id so the caller can correlate / poll status.
 */
public with sharing class DocSplitterInvocable {

    @TestVisible
    private static final Integer SINGLE_CALL_THRESHOLD_BYTES = 10 * 1024 * 1024;
    @TestVisible
    private static Boolean forceChunkedPathForTest = false;

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

        @InvocableVariable(label='Is Single Call' description='True if the file fits in one LLM call (<= 10 MB). False if the service was asked to chunk first.')
        public Boolean isSingleCall;

        @InvocableVariable(label='Total Pages' description='Page count is stored on the split job after the PDF service prepares the source file.')
        public Integer totalPages;
    }

    @InvocableMethod(
        label='Start AI Document Splitter (Headless)'
        description='Kick off the AI Document Splitter for a bundle PDF. Single-call for files <= 10 MB; otherwise chunks via the self-hosted pdf-lib service.'
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

            // Resolve latest ContentVersion to choose one or multiple LLM chunks.
            ContentVersion cv = [SELECT Id, ContentSize, ContentDocumentId
                                 FROM ContentVersion
                                 WHERE ContentDocumentId = :req.sourceContentDocumentId
                                   AND IsLatest = true
                                 WITH USER_MODE
                                 LIMIT 1];

            Id libraryId = req.libraryId != null ? req.libraryId : lookupLibrary(req.sourceContentDocumentId);
            Id folderId = req.targetFolderId != null ? req.targetFolderId : lookupFolder(req.sourceContentDocumentId);

            Boolean useSingleCall = !forceChunkedPathForTest && cv.ContentSize <= SINGLE_CALL_THRESHOLD_BYTES;

            // Placeholder counts are replaced by PdfServiceChunkQueueable before
            // classification. Using the same preparation path for every headless
            // file prevents the LLM response from becoming the page-count source.
            Id jobId = SplitJobService.startJob(
                req.sourceContentDocumentId, libraryId, folderId, req.targetRecordId,
                1, 1, true
            );
            if (!Test.isRunningTest()) {
                System.enqueueJob(new PdfServiceChunkQueueable(jobId));
            }
            res.jobId = jobId;
            res.isSingleCall = useSingleCall;
            res.totalPages = null;
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

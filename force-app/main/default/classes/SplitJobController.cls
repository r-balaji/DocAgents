/**
 * Thin @AuraEnabled controller exposing SplitJobService to the documentSplitter LWC.
 *
 * Each method wraps the underlying service call in AuraHandledException so the LWC
 * gets user-friendly errors and we never leak internal stack traces.
 */
public with sharing class SplitJobController {

    /**
     * Look up the latest ContentVersion Id for a ContentDocument. The LWC uses
     * this to construct the shepherd download URL for the source PDF binary.
     */
    @AuraEnabled(cacheable=true)
    public static Id getLatestContentVersionId(Id contentDocumentId) {
        try {
            ContentVersion cv = [SELECT Id FROM ContentVersion
                                 WHERE ContentDocumentId = :contentDocumentId
                                   AND IsLatest = true
                                 WITH USER_MODE
                                 LIMIT 1];
            return cv.Id;
        } catch (QueryException e) {
            throw new AuraHandledException('No file found for ContentDocument ' + contentDocumentId);
        } catch (Exception e) {
            throw new AuraHandledException('Could not load file: ' + e.getMessage());
        }
    }

    /**
     * Upload a chunk PDF (base64) back to Salesforce as a temporary ContentVersion.
     * The LWC slices the source bundle in-browser and calls this once per chunk.
     * Returns the chunk's new ContentDocumentId, which the LWC passes back in
     * enqueueChunkClassification so the AI prompt has a file to read from.
     *
     * The library Id is stored on the resulting ContentVersion so the chunk is
     * visible to the splitter pipeline, but the LWC could also choose to upload
     * to a per-job workspace if isolation matters later.
     */
    @AuraEnabled
    public static Id uploadChunkPdf(String fileName, String base64Content, Id libraryId) {
        if (String.isBlank(fileName)) {
            throw new AuraHandledException('fileName is required.');
        }
        if (String.isBlank(base64Content)) {
            throw new AuraHandledException('base64Content is required.');
        }
        if (libraryId == null) {
            throw new AuraHandledException('libraryId is required.');
        }
        try {
            ContentVersion cv = new ContentVersion(
                Title = fileName,
                PathOnClient = fileName,
                VersionData = EncodingUtil.base64Decode(base64Content),
                FirstPublishLocationId = libraryId
            );
            Database.insert(cv, AccessLevel.USER_MODE);
            ContentVersion saved = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id WITH USER_MODE LIMIT 1];
            return saved.ContentDocumentId;
        } catch (Exception e) {
            throw new AuraHandledException('Chunk upload failed: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static Id startJob(Id sourceContentDocumentId, Id libraryId, Integer totalPages, Integer chunkCount) {
        try {
            return SplitJobService.startJob(sourceContentDocumentId, libraryId, totalPages, chunkCount);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static void enqueueChunkClassification(Id jobId, Integer chunkIndex, Id chunkContentDocumentId, Integer pageOffset) {
        try {
            SplitJobService.enqueueChunkClassification(jobId, chunkIndex, chunkContentDocumentId, pageOffset);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * Kick off the save phase. The LWC passes a JSON-serialized List<SplitSaveRequest>
     * built from pdf-lib's split output. Returns immediately after enqueueing the first
     * SplitSaveQueueable; progress comes back via Split_Job_Update__e events.
     */
    @AuraEnabled
    public static void startSaving(Id jobId, String requestsJson, Integer batchSize) {
        try {
            List<SplitSaveRequest> requests = parseSaveRequests(requestsJson);
            SplitJobService.startSaving(jobId, requests, batchSize);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @TestVisible
    private static List<SplitSaveRequest> parseSaveRequests(String requestsJson) {
        if (String.isBlank(requestsJson)) {
            return new List<SplitSaveRequest>();
        }
        return (List<SplitSaveRequest>) JSON.deserialize(requestsJson, List<SplitSaveRequest>.class);
    }
}

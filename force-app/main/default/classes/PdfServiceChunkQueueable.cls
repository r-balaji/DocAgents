/**
 * Queueable that asks the self-hosted pdf-lib service to chunk a > 10 MB
 * source PDF, then starts a Batch Apex classifier with one chunk per batch
 * transaction.
 *
 * Only used on the headless path; the LWC path still does chunking client-side
 * via pdf-lib in the browser. Single-call (<= 10 MB) headless jobs skip this
 * Queueable entirely -- they start a one-item classification Batch against
 * the source ContentDocument.
 */
public with sharing class PdfServiceChunkQueueable implements Queueable, Database.AllowsCallouts {

    @TestVisible
    private static final Integer MAX_CHUNK_BYTES = 10 * 1024 * 1024;
    @TestVisible
    private static final Integer FALLBACK_CHUNK_OVERLAP_PAGES = 0;

    private final Id jobId;

    /**
     * Creates a PDF service chunking request for one split job.
     * @param jobId Split job to chunk and classify.
     * @throws SplitJobException when jobId is missing.
     */
    public PdfServiceChunkQueueable(Id jobId) {
        if (jobId == null) {
            throw new SplitJobException('jobId is required.');
        }
        this.jobId = jobId;
    }

    /**
     * Calls the PDF service to chunk the source bundle and starts classification.
     * @param context Queueable context.
     */
    public void execute(QueueableContext context) {
        try {
            Split_Job__c job = lookupJob(jobId);
            Id sourceCdId = (Id) job.Source_ContentDocument_Id__c;
            Id latestCvId = resolveLatestContentVersion(sourceCdId);

            PdfServiceClient.SfContext sf = PdfServiceClient.currentSfContext();

            PdfServiceClient.ChunksRequest req = new PdfServiceClient.ChunksRequest();
            req.jobId = (String) jobId;
            req.sourceContentVersionId = (String) latestCvId;
            req.sfInstanceUrl = sf.sfInstanceUrl;
            req.sfAccessToken = sf.sfAccessToken;
            req.sfApiVersion = sf.sfApiVersion;
            req.libraryId = (String) job.Library_Id__c;
            req.maxChunkBytes = MAX_CHUNK_BYTES;
            req.overlap = FALLBACK_CHUNK_OVERLAP_PAGES;

            PdfServiceClient.ChunksResponse res = new PdfServiceClient().callChunks(req);

            List<PdfServiceChunkClassifyBatch.ChunkWork> chunkWork =
                PdfServiceChunkClassifyBatch.fromChunkRecords(res.chunks);
            if (chunkWork.isEmpty()) {
                throw new SplitJobException('chunks is required.');
            }
            SplitJobService.linkTempChunkFiles(jobId, chunkWork);

            // Update the job with the chunk count + total pages we just learned from the service.
            Integer chunkCount = chunkWork.size();
            Split_Job__c jobUpdate = new Split_Job__c(
                Id = jobId,
                Chunk_Count__c = chunkCount,
                Total_Pages__c = res.totalPages,
                Status__c = 'Detecting'
            );
            Database.update(jobUpdate, AccessLevel.USER_MODE);

            // Batch Apex avoids Queueable self-chain depth limits while still
            // giving each chunk its own transaction and callout allowance.
            if (!Test.isRunningTest()) {
                Database.executeBatch(new PdfServiceChunkClassifyBatch(jobId, chunkWork), 1);
            }
        } catch (Exception e) {
            SplitJobService.failJob(jobId, 'PdfServiceChunk', e.getTypeName() + ': ' + e.getMessage());
        }
    }

    @TestVisible
    private static Split_Job__c lookupJob(Id jobId) {
        return [SELECT Id, Source_ContentDocument_Id__c, Library_Id__c, Status__c
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

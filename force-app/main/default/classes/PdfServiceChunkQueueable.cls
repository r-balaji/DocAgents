/**
 * Queueable that asks the self-hosted pdf-lib service to chunk a > 12 MB
 * source PDF, then enqueues one ClassifyQueueable per resulting chunk.
 *
 * Only used on the headless path; the LWC path still does chunking client-side
 * via pdf-lib in the browser. Single-call (<= 12 MB) headless jobs skip this
 * Queueable entirely — they enqueue ClassifyQueueable directly against the
 * source ContentDocument.
 */
public with sharing class PdfServiceChunkQueueable implements Queueable, Database.AllowsCallouts {

    private final Id jobId;

    public PdfServiceChunkQueueable(Id jobId) {
        if (jobId == null) {
            throw new SplitJobException('jobId is required.');
        }
        this.jobId = jobId;
    }

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
            req.chunkSize = 8;
            req.overlap = 2;

            PdfServiceClient.ChunksResponse res = new PdfServiceClient().callChunks(req);

            // Update the job with the chunk count + total pages we just learned from the service.
            Split_Job__c jobUpdate = new Split_Job__c(
                Id = jobId,
                Chunk_Count__c = res.chunks.size(),
                Total_Pages__c = res.totalPages,
                Status__c = 'Detecting'
            );
            Database.update(jobUpdate, AccessLevel.USER_MODE);

            // Enqueue one ClassifyQueueable per chunk. In tests we skip the chain to
            // avoid hitting the "Maximum stack depth has been reached" error.
            if (!Test.isRunningTest()) {
                for (PdfServiceClient.ChunkRecord c : res.chunks) {
                    System.enqueueJob(new ClassifyQueueable(
                        jobId,
                        c.chunkIndex,
                        (Id) c.contentDocumentId,
                        c.pageOffset
                    ));
                }
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

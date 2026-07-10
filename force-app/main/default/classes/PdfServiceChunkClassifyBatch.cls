/**
 * Batch classifier for PDF service chunk outputs.
 *
 * Runs one chunk per transaction when invoked with scope size 1, avoiding
 * Queueable self-chaining depth limits while preserving one common chunk
 * classification service.
 */
public with sharing class PdfServiceChunkClassifyBatch
    implements Database.Batchable<PdfServiceChunkClassifyBatch.ChunkWork>, Database.AllowsCallouts {

    private final Id jobId;
    private final List<ChunkWork> chunks;

    /**
     * Creates a chunk classification batch.
     * @param jobId Split job that owns the chunked source.
     * @param chunks Ordered chunk work returned by the PDF service.
     * @throws SplitJobException when required input is missing.
     */
    public PdfServiceChunkClassifyBatch(Id jobId, List<ChunkWork> chunks) {
        if (jobId == null) {
            throw new SplitJobException('jobId is required.');
        }
        if (chunks == null || chunks.isEmpty()) {
            throw new SplitJobException('chunks is required.');
        }
        this.jobId = jobId;
        this.chunks = new List<ChunkWork>();
        this.chunks.addAll(chunks);
    }

    /**
     * @param context Batch context.
     * @return Chunk work iterable for Batch Apex.
     */
    public Iterable<ChunkWork> start(Database.BatchableContext context) {
        return chunks;
    }

    /**
     * Classifies each chunk in the current batch scope.
     * @param context Batch context.
     * @param scope Chunk work assigned to this transaction.
     */
    public void execute(Database.BatchableContext context, List<ChunkWork> scope) {
        if (scope == null || scope.isEmpty()) {
            return;
        }
        for (ChunkWork current : scope) {
            if (current == null || isJobInError(jobId)) {
                return;
            }
            AIDocSplitClassifierService.classifyChunk(
                jobId,
                current.chunkIndex,
                current.contentDocumentId,
                current.pageOffset
            );
        }
    }

    /**
     * No finish work is needed. The final chunk completion drives merge/split.
     * @param context Batch context.
     */
    public void finish(Database.BatchableContext context) {
        return;
    }

    /**
     * Converts PDF service chunk records into serializable batch work.
     * @param records Chunk records returned by the PDF service.
     * @return Ordered chunk work list.
     */
    public static List<ChunkWork> fromChunkRecords(List<PdfServiceClient.ChunkRecord> records) {
        List<ChunkWork> work = new List<ChunkWork>();
        if (records == null) {
            return work;
        }
        for (PdfServiceClient.ChunkRecord record : records) {
            if (record == null || String.isBlank(record.contentDocumentId)) {
                continue;
            }
            work.add(new ChunkWork(
                record.chunkIndex == null ? work.size() : record.chunkIndex,
                (Id) record.contentDocumentId,
                record.pageOffset == null ? 1 : record.pageOffset
            ));
        }
        return work;
    }

    private static Boolean isJobInError(Id splitJobId) {
        List<Split_Job__c> jobs = [
            SELECT Status__c
            FROM Split_Job__c
            WHERE Id = :splitJobId
            WITH USER_MODE
            LIMIT 1
        ];
        return !jobs.isEmpty() && jobs[0].Status__c == 'Error';
    }

    /**
     * Serializable chunk work item.
     */
    public class ChunkWork {
        public Integer chunkIndex;
        public Id contentDocumentId;
        public Integer pageOffset;

        /**
         * Creates one chunk work item.
         * @param chunkIndex Zero-based chunk index.
         * @param contentDocumentId Chunk ContentDocument Id.
         * @param pageOffset First source-page number represented in the chunk.
         */
        public ChunkWork(Integer chunkIndex, Id contentDocumentId, Integer pageOffset) {
            this.chunkIndex = chunkIndex;
            this.contentDocumentId = contentDocumentId;
            this.pageOffset = pageOffset;
        }
    }
}

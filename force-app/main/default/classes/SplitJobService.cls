/**
 * Orchestrator for the AI Document Splitter pipeline.
 *
 * Responsibilities:
 *  - startJob: persist a new Split_Job__c record (Status=Queued) and return its Id.
 *  - enqueueChunkClassification: enqueue one ClassifyQueueable per chunk uploaded by the LWC.
 *  - recordChunkCompletion: called by each ClassifyQueueable when it finishes its chunk.
 *    Increments Chunks_Completed__c under a row lock; if this was the last chunk,
 *    transitions Status to Merging, runs SegmentMerger, persists the merged JSON,
 *    transitions to Splitting, and publishes a Split_Job_Update__e event so the LWC
 *    can begin the binary split.
 *  - finalizeJob: invoked by the LWC after the binary split + save are done; sets
 *    Status=Complete and publishes a final event.
 *  - failJob: called when any stage errors out; sets Status=Error and publishes an Error event.
 *
 * No prompt invocation lives here -- that happens inside ClassifyQueueable, which uses
 * the AIDocSplitClassifySpike subflow.
 */
public with sharing class SplitJobService {

    @TestVisible
    private static final String FALLBACK_TYPE = 'OTHER';

    private SplitJobService() {
        // Service class -- instantiation prevented.
    }

    /**
     * Create a Split_Job__c for a new bundle. folderId is optional — when set,
     * the save Queueable drops the splits into that folder instead of the
     * library root. The two-arg overload below is kept for callers that don't
     * carry folder context.
     */
    public static Id startJob(Id sourceContentDocumentId, Id libraryId, Id folderId, Integer totalPages, Integer chunkCount) {
        if (sourceContentDocumentId == null) {
            throw new SplitJobException('sourceContentDocumentId is required.');
        }
        if (libraryId == null) {
            throw new SplitJobException('libraryId is required.');
        }
        if (totalPages == null || totalPages < 1) {
            throw new SplitJobException('totalPages must be >= 1.');
        }
        if (chunkCount == null || chunkCount < 1) {
            throw new SplitJobException('chunkCount must be >= 1.');
        }

        Split_Job__c job = new Split_Job__c(
            Source_ContentDocument_Id__c = (String) sourceContentDocumentId,
            Library_Id__c = (String) libraryId,
            Target_Folder_Id__c = folderId == null ? null : (String) folderId,
            Status__c = 'Queued',
            Total_Pages__c = totalPages,
            Chunk_Count__c = chunkCount,
            Chunks_Completed__c = 0,
            Started_By__c = UserInfo.getUserId()
        );
        Database.insert(job, AccessLevel.USER_MODE);
        publishUpdate(job.Id, 'Queued', null, 'Split job created.');
        return job.Id;
    }

    /**
     * Convenience overload — no folder context, saves to library root.
     */
    public static Id startJob(Id sourceContentDocumentId, Id libraryId, Integer totalPages, Integer chunkCount) {
        return startJob(sourceContentDocumentId, libraryId, null, totalPages, chunkCount);
    }

    /**
     * Enqueue one ClassifyQueueable for a chunk that has been uploaded as a separate
     * ContentDocument by the LWC. Called once per chunk.
     */
    public static void enqueueChunkClassification(Id jobId, Integer chunkIndex, Id chunkContentDocumentId, Integer pageOffset) {
        if (jobId == null) {
            throw new SplitJobException('jobId is required.');
        }
        if (chunkIndex == null || chunkIndex < 0) {
            throw new SplitJobException('chunkIndex must be >= 0.');
        }
        if (chunkContentDocumentId == null) {
            throw new SplitJobException('chunkContentDocumentId is required.');
        }
        if (pageOffset == null || pageOffset < 1) {
            throw new SplitJobException('pageOffset must be >= 1.');
        }

        // Move status to Detecting on first enqueue. Idempotent set is fine.
        markStatusIfNotTerminal(jobId, 'Detecting');

        System.enqueueJob(new ClassifyQueueable(jobId, chunkIndex, chunkContentDocumentId, pageOffset));
    }

    /**
     * Called by ClassifyQueueable.execute() after it has stored its chunk's raw segments.
     * Increments the completion counter under a row lock. If this was the last chunk,
     * runs the merge and transitions the job into Splitting.
     */
    public static void recordChunkCompletion(Id jobId) {
        if (jobId == null) {
            return;
        }

        Split_Job__c job = [SELECT Id, Chunk_Count__c, Chunks_Completed__c, Status__c, Raw_Segments_JSON__c, Total_Pages__c
                            FROM Split_Job__c
                            WHERE Id = :jobId
                            WITH USER_MODE
                            FOR UPDATE];

        Decimal currentCount = job.Chunks_Completed__c == null ? 0 : job.Chunks_Completed__c;
        Decimal target = job.Chunk_Count__c == null ? 0 : job.Chunk_Count__c;
        job.Chunks_Completed__c = currentCount + 1;
        Boolean isLastChunk = job.Chunks_Completed__c == target;

        if (isLastChunk) {
            job.Status__c = 'Merging';
        }
        Database.update(job, AccessLevel.USER_MODE);

        publishUpdate(jobId,
            isLastChunk ? 'Merging' : 'Detecting',
            null,
            'Chunk ' + ((Integer) job.Chunks_Completed__c) + ' of ' + ((Integer) target) + ' classified.');

        if (isLastChunk) {
            runMergeAndPrepareForSplit(job);
        }
    }

    /**
     * Kick off the save phase. Called by the LWC after pdf-lib has split the
     * source bundle in-browser. Enqueues a SplitSaveQueueable to process the
     * file list in batches.
     */
    public static void startSaving(Id jobId, List<SplitSaveRequest> files, Integer batchSize) {
        if (jobId == null) {
            throw new SplitJobException('jobId is required.');
        }
        if (files == null) {
            throw new SplitJobException('files is required (use empty list, not null).');
        }
        if (files.isEmpty()) {
            // Nothing to save -- finalize immediately with zero docs.
            finalizeJob(jobId, 0, '[]');
            return;
        }
        Integer effectiveBatchSize = (batchSize == null || batchSize < 1) ? 8 : batchSize;
        System.enqueueJob(new SplitSaveQueueable(jobId, files, effectiveBatchSize));
    }

    /**
     * Transition the job to Saving. Idempotent -- called by the first
     * SplitSaveQueueable batch but safe to call repeatedly.
     */
    public static void markSaving(Id jobId) {
        markStatusIfNotTerminal(jobId, 'Saving');
        publishUpdate(jobId, 'Saving', null, 'Saving split files.');
    }

    /**
     * Called by each SplitSaveQueueable batch after it commits its inserts.
     * Persists the running save count and publishes a progress event.
     */
    public static void recordSaveProgress(Id jobId, Integer documentsSavedSoFar, Map<String, Integer> typeCountsSoFar) {
        if (jobId == null) {
            return;
        }
        Split_Job__c jobUpdate = new Split_Job__c(
            Id = jobId,
            Documents_Created__c = documentsSavedSoFar == null ? 0 : documentsSavedSoFar
        );
        Database.update(jobUpdate, AccessLevel.USER_MODE);

        publishUpdate(jobId, 'Saving', null,
            'Saved ' + (documentsSavedSoFar == null ? 0 : documentsSavedSoFar) + ' files so far.',
            documentsSavedSoFar == null ? 0 : documentsSavedSoFar);
    }

    /**
     * Called by the LWC after it has split the bundle and SplitSaveQueueable has
     * saved all child files. Transitions the job to Complete and deletes the
     * temp chunk PDFs the LWC uploaded during preparation — they are no longer
     * needed once everything is saved successfully.
     */
    public static void finalizeJob(Id jobId, Integer documentsCreated, String typeBreakdownJson) {
        if (jobId == null) {
            throw new SplitJobException('jobId is required.');
        }

        Split_Job__c job = new Split_Job__c(
            Id = jobId,
            Status__c = 'Complete',
            Documents_Created__c = documentsCreated == null ? 0 : documentsCreated,
            Type_Breakdown_JSON__c = typeBreakdownJson
        );
        Database.update(job, AccessLevel.USER_MODE);

        cleanupTempChunkFiles(jobId);
        deleteSourceIfReplacedByOneFile(jobId);

        publishUpdate(jobId, 'Complete', typeBreakdownJson, 'Split complete.',
            documentsCreated == null ? 0 : documentsCreated);
    }

    /**
     * When the AI produced exactly one well-typed segment that covers the entire
     * source bundle, the newly-saved file is essentially a renamed duplicate of
     * the source. Delete the source so the library doesn't accumulate redundancy.
     * Best-effort — never blocks the job from being marked Complete.
     */
    @TestVisible
    private static void deleteSourceIfReplacedByOneFile(Id jobId) {
        if (Test.isRunningTest()) {
            return;
        }
        try {
            Split_Job__c job = [SELECT Source_ContentDocument_Id__c, Total_Pages__c,
                                       Documents_Created__c, Merged_Segments_JSON__c
                                FROM Split_Job__c WHERE Id = :jobId LIMIT 1];
            if (!shouldReplaceSource(job)) {
                return;
            }
            Database.delete(new ContentDocument(Id = (Id) job.Source_ContentDocument_Id__c), false);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Source replacement skipped: ' + e.getMessage());
        }
    }

    /**
     * Pure-logic guard for source auto-deletion. Returns true only when the job
     * produced a single, fully-covering, non-OTHER segment — meaning the saved
     * output is a renamed duplicate of the source.
     */
    @TestVisible
    private static Boolean shouldReplaceSource(Split_Job__c job) {
        if (job == null) return false;
        if (job.Documents_Created__c == null || job.Documents_Created__c != 1) return false;
        if (String.isBlank(job.Merged_Segments_JSON__c)) return false;
        if (job.Total_Pages__c == null) return false;
        if (String.isBlank(job.Source_ContentDocument_Id__c)) return false;

        List<Object> segments;
        try {
            segments = (List<Object>) JSON.deserializeUntyped(job.Merged_Segments_JSON__c);
        } catch (Exception e) {
            return false;
        }
        if (segments == null || segments.size() != 1) return false;

        Map<String, Object> only = (Map<String, Object>) segments[0];
        String type = (String) only.get('documentType');
        if (String.isBlank(type) || FALLBACK_TYPE.equalsIgnoreCase(type)) return false;

        Integer startPage = (Integer) only.get('startPage');
        Integer endPage = (Integer) only.get('endPage');
        if (startPage == null || endPage == null) return false;
        return startPage == 1 && endPage == (Integer) job.Total_Pages__c;
    }

    /**
     * Mark a job as Error. Safe to call from any pipeline stage; persists the
     * error detail and publishes an Error event for the LWC to render.
     */
    public static void failJob(Id jobId, String stage, String errorDetail) {
        if (jobId == null) {
            return;
        }

        String detail = '[' + (stage == null ? 'Unknown' : stage) + '] ' + (errorDetail == null ? '' : errorDetail);
        Split_Job__c job = new Split_Job__c(
            Id = jobId,
            Status__c = 'Error',
            Error_Detail__c = detail
        );
        Database.update(job, AccessLevel.USER_MODE);

        publishUpdate(jobId, 'Error', null, detail.left(255));
    }

    // ----- Helpers ---------------------------------------------------------

    /**
     * Merge the accumulated raw segments using SegmentMerger and persist the result
     * so the LWC can pick it up. Transitions Status to Splitting. Also cleans up the
     * temporary chunk PDFs the LWC uploaded for AI classification — they're done
     * being read by this point and we don't want them cluttering the library.
     */
    @TestVisible
    private static void runMergeAndPrepareForSplit(Split_Job__c job) {
        List<DocSegment> raw = deserializeRawSegments(job.Raw_Segments_JSON__c);
        List<DocSegment> merged = SegmentMerger.mergeSegments(raw, (Integer) job.Total_Pages__c, FALLBACK_TYPE);
        String mergedJson = JSON.serialize(merged);

        Split_Job__c statusUpdate = new Split_Job__c(
            Id = job.Id,
            Status__c = 'Splitting',
            Merged_Segments_JSON__c = mergedJson.left(32768)
        );
        Database.update(statusUpdate, AccessLevel.USER_MODE);

        publishUpdate(job.Id, 'Splitting', mergedJson, 'Merged into ' + merged.size() + ' segments.');
    }

    /**
     * Delete the temp chunk PDFs the LWC uploaded for this job. They're named
     * `bundle_chunk_*.pdf` and aren't needed after classification finishes.
     * Failures here are logged but never propagated — cleanup is best-effort.
     */
    @TestVisible
    private static void cleanupTempChunkFiles(Id jobId) {
        if (Test.isRunningTest()) {
            return;
        }
        try {
            // The LWC uploaded chunks to the library between the source download
            // and the startJob call, so they're titled bundle_chunk_N and exist
            // as ContentDocuments in the same library. Find them by title pattern.
            Split_Job__c job = [SELECT Library_Id__c, CreatedDate FROM Split_Job__c WHERE Id = :jobId LIMIT 1];
            Id libraryId = (Id) job.Library_Id__c;
            Datetime jobStart = job.CreatedDate;
            // 5-minute window before the job for the temp-chunk uploads.
            Datetime windowStart = jobStart.addMinutes(-5);

            List<ContentWorkspaceDoc> memberships = [SELECT ContentDocumentId
                                                     FROM ContentWorkspaceDoc
                                                     WHERE ContentWorkspaceId = :libraryId];
            Set<Id> libraryDocIds = new Set<Id>();
            for (ContentWorkspaceDoc m : memberships) {
                libraryDocIds.add(m.ContentDocumentId);
            }
            List<ContentDocument> chunkDocs = [SELECT Id FROM ContentDocument
                                               WHERE Id IN :libraryDocIds
                                                 AND Title LIKE 'bundle_chunk_%'
                                                 AND CreatedDate >= :windowStart
                                                 AND CreatedDate <= :jobStart];
            if (!chunkDocs.isEmpty()) {
                Database.delete(chunkDocs, false);
            }
        } catch (Exception e) {
            // best-effort — don't kill the job over cleanup failure
            System.debug(LoggingLevel.WARN, 'Temp chunk cleanup failed: ' + e.getMessage());
        }
    }

    /**
     * Idempotent helper: set status to the requested value unless the job is already
     * in a terminal state (Complete or Error).
     */
    @TestVisible
    private static void markStatusIfNotTerminal(Id jobId, String newStatus) {
        Split_Job__c job = [SELECT Id, Status__c FROM Split_Job__c WHERE Id = :jobId WITH USER_MODE LIMIT 1];
        if (job.Status__c == 'Complete' || job.Status__c == 'Error') {
            return;
        }
        if (job.Status__c == newStatus) {
            return;
        }
        job.Status__c = newStatus;
        Database.update(job, AccessLevel.USER_MODE);
    }

    /**
     * Parse the JSON-array accumulator into typed DocSegment instances.
     * Tolerates an empty or null field by returning an empty list.
     */
    @TestVisible
    private static List<DocSegment> deserializeRawSegments(String raw) {
        List<DocSegment> out = new List<DocSegment>();
        if (String.isBlank(raw)) {
            return out;
        }
        List<Object> items = (List<Object>) JSON.deserializeUntyped(raw);
        for (Object item : items) {
            Map<String, Object> m = (Map<String, Object>) item;
            DocSegment s = new DocSegment();
            s.documentType      = (String) m.get('documentType');
            s.sourceInstitution = (String) m.get('sourceInstitution');
            s.namedParty        = (String) m.get('namedParty');
            s.startPage         = (Integer) m.get('startPage');
            s.endPage           = (Integer) m.get('endPage');
            out.add(s);
        }
        return out;
    }

    /**
     * Publish a Split_Job_Update__e event. Failures here are logged but never
     * rethrown -- a published-event failure should not roll back the underlying
     * job state change.
     */
    @TestVisible
    private static void publishUpdate(Id jobId, String status, String summaryJson, String message) {
        publishUpdate(jobId, status, summaryJson, message, null);
    }

    @TestVisible
    private static void publishUpdate(Id jobId, String status, String summaryJson, String message, Integer documentsCreated) {
        Split_Job_Update__e evt = new Split_Job_Update__e(
            Job_Id__c = (String) jobId,
            Status__c = status,
            Summary_JSON__c = summaryJson == null ? null : summaryJson.left(32768),
            Message__c = message == null ? null : message.left(255),
            Documents_Created__c = documentsCreated
        );
        EventBus.publish(evt);
    }
}

/**
 * Orchestrator for the AI Document Splitter pipeline.
 *
 * Responsibilities:
 *  - startJob: persist a new Split_Job__c record (Status=Queued) and return its Id.
 *  - enqueueChunkClassifications: start Batch Apex classification for uploaded chunks.
 *  - recordChunkCompletion: called after each chunk is classified.
 *    Increments Chunks_Completed__c under a row lock; if this was the last chunk,
 *    transitions Status to Merging, runs SegmentMerger, persists the merged JSON,
 *    transitions to Splitting, and publishes a Split_Job_Update__e event so the LWC
 *    can begin the binary split.
 *  - finalizeJob: invoked by the LWC after the binary split + save are done; sets
 *    Status=Complete and publishes a final event.
 *  - failJob: called when any stage errors out; sets Status=Error and publishes an Error event.
 *
 * No prompt invocation lives here -- that happens inside AIDocSplitClassifierService,
 * which uses the AIDocSplitClassifySpike subflow.
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
        return startJob(sourceContentDocumentId, libraryId, folderId, null, totalPages, chunkCount, false);
    }

    /**
     * Headless overload — used by the @InvocableMethod entry point. Sets
     * Is_Headless__c so SplitJobService.runMergeAndPrepareForSplit enqueues
     * the self-hosted service for the binary split step instead of waiting
     * on the LWC.
     *
     * targetRecordId — typically a Loan_Application__c. The service attaches
     * each split output to this record via ContentDocumentLink.
     */
    public static Id startJob(Id sourceContentDocumentId, Id libraryId, Id folderId, Id targetRecordId,
                              Integer totalPages, Integer chunkCount, Boolean isHeadless) {
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
            Target_Record_Id__c = targetRecordId == null ? null : (String) targetRecordId,
            Is_Headless__c = isHeadless == true,
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
     * Start Batch Apex classification for one or many uploaded chunks.
     */
    public static void enqueueChunkClassifications(Id jobId, List<PdfServiceChunkClassifyBatch.ChunkWork> chunks) {
        if (jobId == null) {
            throw new SplitJobException('jobId is required.');
        }
        if (chunks == null || chunks.isEmpty()) {
            throw new SplitJobException('chunks is required.');
        }

        List<PdfServiceChunkClassifyBatch.ChunkWork> work = new List<PdfServiceChunkClassifyBatch.ChunkWork>();
        for (PdfServiceChunkClassifyBatch.ChunkWork chunk : chunks) {
            work.add(validateChunkWork(chunk));
        }

        // Move status to Detecting on first enqueue. Idempotent set is fine.
        markStatusIfNotTerminal(jobId, 'Detecting');

        if (Test.isRunningTest()) {
            new PdfServiceChunkClassifyBatch(jobId, work).execute(null, work);
            return;
        }
        Database.executeBatch(new PdfServiceChunkClassifyBatch(jobId, work), 1);
    }

    /**
     * Link service-created temporary chunk files to the Split_Job__c so cleanup
     * can delete the exact files for this job instead of relying on timestamps.
     * Best-effort: a link failure must not block the splitter pipeline.
     */
    public static void linkTempChunkFiles(Id jobId, List<PdfServiceChunkClassifyBatch.ChunkWork> chunks) {
        if (jobId == null || chunks == null || chunks.isEmpty()) {
            return;
        }
        try {
            Set<Id> contentDocumentIds = new Set<Id>();
            for (PdfServiceChunkClassifyBatch.ChunkWork chunk : chunks) {
                if (chunk != null && chunk.contentDocumentId != null) {
                    contentDocumentIds.add(chunk.contentDocumentId);
                }
            }
            if (contentDocumentIds.isEmpty()) {
                return;
            }

            Set<Id> alreadyLinkedIds = new Set<Id>();
            for (ContentDocumentLink existing : [
                SELECT ContentDocumentId
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :jobId
                  AND ContentDocumentId IN :contentDocumentIds
                WITH USER_MODE
            ]) {
                alreadyLinkedIds.add(existing.ContentDocumentId);
            }

            List<ContentDocumentLink> links = new List<ContentDocumentLink>();
            for (Id contentDocumentId : contentDocumentIds) {
                if (!alreadyLinkedIds.contains(contentDocumentId)) {
                    links.add(new ContentDocumentLink(
                        ContentDocumentId = contentDocumentId,
                        LinkedEntityId = jobId,
                        ShareType = 'V'
                    ));
                }
            }
            if (!links.isEmpty()) {
                Database.insert(links, false, AccessLevel.USER_MODE);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Temp chunk link skipped: ' + e.getMessage());
        }
    }

    /**
     * Marks the latest ContentVersion for final split output documents.
     *
     * @param contentDocumentIds ContentDocument ids returned by the split save path.
     * @return Number of latest ContentVersion rows successfully updated.
     */
    public static Integer markContentDocumentsAiCreated(Set<Id> contentDocumentIds) {
        if (contentDocumentIds == null || contentDocumentIds.isEmpty()) {
            return 0;
        }

        List<ContentVersion> versionsToUpdate = new List<ContentVersion>();
        for (ContentVersion version : [
            SELECT Id, AI_Created_Doc__c
            FROM ContentVersion
            WHERE ContentDocumentId IN :contentDocumentIds
              AND IsLatest = true
            WITH USER_MODE
        ]) {
            if (version.AI_Created_Doc__c == true) {
                continue;
            }
            versionsToUpdate.add(new ContentVersion(
                Id = version.Id,
                AI_Created_Doc__c = true
            ));
        }

        if (versionsToUpdate.isEmpty()) {
            return 0;
        }

        Integer successCount = 0;
        for (Database.SaveResult result : Database.update(versionsToUpdate, false, AccessLevel.USER_MODE)) {
            if (result.isSuccess()) {
                successCount++;
            }
        }
        return successCount;
    }

    private static PdfServiceChunkClassifyBatch.ChunkWork validateChunkWork(PdfServiceChunkClassifyBatch.ChunkWork chunk) {
        if (chunk == null) {
            throw new SplitJobException('chunk is required.');
        }
        if (chunk.chunkIndex == null || chunk.chunkIndex < 0) {
            throw new SplitJobException('chunkIndex must be >= 0.');
        }
        if (chunk.contentDocumentId == null) {
            throw new SplitJobException('chunkContentDocumentId is required.');
        }
        if (chunk.pageOffset == null || chunk.pageOffset < 1) {
            throw new SplitJobException('pageOffset must be >= 1.');
        }
        return chunk;
    }

    /**
     * Called by AIDocSplitClassifierService after it has stored its chunk's raw segments.
     * Increments the completion counter under a row lock. If this was the last chunk,
     * runs the merge and transitions the job into Splitting.
     */
    public static void recordChunkCompletion(Id jobId) {
        if (jobId == null) {
            return;
        }

        Split_Job__c job = [SELECT Id, Chunk_Count__c, Chunks_Completed__c, Status__c, Raw_Segments_JSON__c,
                                   Total_Pages__c, Is_Headless__c
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
     * Save one browser-produced batch of split PDFs. Unlike startSaving(), this
     * does not carry the full file list in one Apex request or one Queueable
     * state payload. The LWC calls it repeatedly with small payloads and marks
     * only the final call as final.
     *
     * @param jobId Split job being saved.
     * @param files Small batch of split files to insert.
     * @param documentsSavedSoFar Number of files saved before this request.
     * @param typeBreakdownJson Final type breakdown, supplied on the final call.
     * @param isFinalBatch True when this is the last browser save request.
     * @return Updated number of saved documents.
     * @throws SplitJobException when required input is missing or invalid.
     */
    public static Integer saveBrowserBatch(
        Id jobId,
        List<SplitSaveRequest> files,
        Integer documentsSavedSoFar,
        String typeBreakdownJson,
        Boolean isFinalBatch
    ) {
        if (jobId == null) {
            throw new SplitJobException('jobId is required.');
        }
        if (files == null) {
            throw new SplitJobException('files is required (use empty list, not null).');
        }
        Integer priorSaved = documentsSavedSoFar == null ? 0 : documentsSavedSoFar;
        if (priorSaved < 0) {
            throw new SplitJobException('documentsSavedSoFar must be >= 0.');
        }

        if (priorSaved == 0) {
            markSaving(jobId);
        }

        if (!files.isEmpty()) {
            Split_Job__c jobCtx = SplitSaveQueueable.lookupJobSaveContext(jobId);
            SplitSaveQueueable.saveBatch(
                files,
                (Id) jobCtx.Library_Id__c,
                jobId,
                String.isBlank(jobCtx.Target_Folder_Id__c) ? null : (Id) jobCtx.Target_Folder_Id__c
            );
        }

        Integer savedTotal = priorSaved + files.size();
        if (isFinalBatch == true) {
            finalizeJob(jobId, savedTotal, String.isBlank(typeBreakdownJson) ? '[]' : typeBreakdownJson);
        } else {
            recordSaveProgress(jobId, savedTotal, null);
        }
        return savedTotal;
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
     * Called after all child files are saved. Transitions the job to Complete
     * and deletes temporary chunk PDFs created during preparation — they are no
     * longer needed once everything is saved successfully.
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
        AIDocIntakeService.markSplitComplete(jobId);

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
                                FROM Split_Job__c WHERE Id = :jobId WITH USER_MODE LIMIT 1];
            if (!shouldReplaceSource(job)) {
                return;
            }
            Database.delete(new ContentDocument(Id = (Id) job.Source_ContentDocument_Id__c), false, AccessLevel.USER_MODE);
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
        // Defensive: if the job thinks the source has <= 1 page, refuse to delete.
        // 1-page Total_Pages__c is suspicious for a "real" source — usually it's
        // either an actual 1-page file (small risk if we keep it) or an unset/
        // placeholder value (high risk if we delete the source).
        if (job.Total_Pages__c <= 1) return false;

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

        Object pagesObj = only.get('pages');
        if (!(pagesObj instanceof List<Object>)) return false;
        List<Object> pages = (List<Object>) pagesObj;
        Integer totalPages = (Integer) job.Total_Pages__c;
        if (pages.size() != totalPages) return false;
        // After SegmentMerger validation, all pages are unique and within [1..totalPages].
        // size == totalPages therefore implies the segment covers every page.
        return true;
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
        AIDocIntakeService.markSplitFailed(jobId, detail);
        cleanupTempChunkFiles(jobId);

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

        Integer totalPages = job.Total_Pages__c == null ? 0 : ((Integer) job.Total_Pages__c);
        if (totalPages < 1) {
            throw new SplitJobException('Total_Pages__c must contain the PDF service or browser page count.');
        }

        List<DocSegment> merged = SegmentMerger.mergeSegments(raw, totalPages, FALLBACK_TYPE);
        String mergedJson = JSON.serialize(merged);

        Split_Job__c statusUpdate = new Split_Job__c(
            Id = job.Id,
            Status__c = 'Splitting',
            Merged_Segments_JSON__c = mergedJson.left(32768)
        );
        Database.update(statusUpdate, AccessLevel.USER_MODE);

        publishUpdate(job.Id, 'Splitting', mergedJson, 'Merged into ' + merged.size() + ' segments.');

        System.debug(LoggingLevel.INFO, 'runMergeAndPrepareForSplit jobId=' + job.Id
            + ' totalPages=' + totalPages
            + ' rawCount=' + raw.size()
            + ' mergedCount=' + merged.size());

        // Headless flow: there's no LWC subscriber to drive the split step, so
        // enqueue the pdf-lib service to do the binary work and finalize.
        if (job.Is_Headless__c == true && !Test.isRunningTest()) {
            System.enqueueJob(new PdfServiceSplitQueueable(job.Id));
        }
    }

    /**
     * Delete temp chunk PDFs for this job. They're named `bundle_chunk_*.pdf`
     * and aren't needed after classification/splitting finishes. Failures here
     * are logged but never propagated — cleanup is best-effort.
     */
    @TestVisible
    private static void cleanupTempChunkFiles(Id jobId) {
        if (Test.isRunningTest()) {
            return;
        }
        try {
            Split_Job__c job = [SELECT Library_Id__c, CreatedDate, LastModifiedDate
                                 FROM Split_Job__c
                                 WHERE Id = :jobId
                                 WITH USER_MODE
                                 LIMIT 1];
            Set<Id> chunkDocIds = findLinkedTempChunkDocumentIds(jobId);
            if (chunkDocIds.isEmpty()) {
                chunkDocIds.addAll(findLibraryTempChunkDocumentIds(job));
            }
            if (!chunkDocIds.isEmpty()) {
                List<ContentDocument> docsToDelete = [
                    SELECT Id
                    FROM ContentDocument
                    WHERE Id IN :chunkDocIds
                    WITH USER_MODE
                ];
                Database.delete(docsToDelete, false, AccessLevel.USER_MODE);
            }
        } catch (Exception e) {
            // best-effort — don't kill the job over cleanup failure
            System.debug(LoggingLevel.WARN, 'Temp chunk cleanup failed: ' + e.getMessage());
        }
    }

    private static Set<Id> findLinkedTempChunkDocumentIds(Id jobId) {
        Set<Id> chunkDocIds = new Set<Id>();
        for (ContentDocumentLink link : [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :jobId
              AND ContentDocument.Title LIKE 'bundle_chunk_%'
            WITH USER_MODE
        ]) {
            chunkDocIds.add(link.ContentDocumentId);
        }
        return chunkDocIds;
    }

    private static Set<Id> findLibraryTempChunkDocumentIds(Split_Job__c job) {
        Set<Id> chunkDocIds = new Set<Id>();
        if (job == null || String.isBlank(job.Library_Id__c)) {
            return chunkDocIds;
        }
        Id libraryId = (Id) job.Library_Id__c;
        Datetime jobStart = job.CreatedDate;
        Datetime windowEnd = job.LastModifiedDate == null ? System.now() : job.LastModifiedDate.addMinutes(1);
        // Browser chunks are uploaded just before the job starts; service chunks
        // are uploaded just after. Keep this as a fallback for older/unlinked
        // chunks, while linked chunks above are the primary cleanup path.
        Datetime windowStart = jobStart.addMinutes(-5);

        List<ContentWorkspaceDoc> memberships = [SELECT ContentDocumentId
                                                 FROM ContentWorkspaceDoc
                                                 WHERE ContentWorkspaceId = :libraryId
                                                 WITH USER_MODE];
        Set<Id> libraryDocIds = new Set<Id>();
        for (ContentWorkspaceDoc m : memberships) {
            libraryDocIds.add(m.ContentDocumentId);
        }
        List<ContentDocument> chunkDocs = [SELECT Id
                                           FROM ContentDocument
                                           WHERE Id IN :libraryDocIds
                                             AND Title LIKE 'bundle_chunk_%'
                                             AND CreatedDate >= :windowStart
                                             AND CreatedDate <= :windowEnd
                                           WITH USER_MODE];
        for (ContentDocument doc : chunkDocs) {
            chunkDocIds.add(doc.Id);
        }
        return chunkDocIds;
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
            s.instanceLabel     = (String) m.get('instanceLabel');
            List<Integer> pages = new List<Integer>();
            Object pagesObj = m.get('pages');
            if (pagesObj instanceof List<Object>) {
                for (Object p : (List<Object>) pagesObj) {
                    if (p instanceof Integer) {
                        pages.add((Integer) p);
                    } else if (p instanceof Decimal) {
                        pages.add(((Decimal) p).intValue());
                    }
                }
            }
            s.pages = pages;
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

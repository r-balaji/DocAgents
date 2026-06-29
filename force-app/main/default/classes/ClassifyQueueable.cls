/**
 * Queueable that classifies one chunk of a document bundle.
 *
 * The LWC uploads each chunk as a separate ContentDocument and enqueues one
 * instance of this Queueable per chunk. Each instance:
 *   1. Invokes the AIDocSplitClassifySpike autolaunched flow, which runs the
 *      AIDocSplitClassify vision prompt against the chunk's ContentDocument
 *      and returns the raw JSON segments string.
 *   2. Parses the JSON, applies the page-offset shift so segment page numbers
 *      are absolute (1-based within the original bundle, not within the chunk).
 *   3. Appends the shifted segments to Split_Job__c.Raw_Segments_JSON__c under
 *      a row lock so concurrent Queueables don't clobber each other's writes.
 *   4. Calls SplitJobService.recordChunkCompletion which handles the
 *      "am I the last one?" decision and triggers the merge step.
 *
 * Implements Database.AllowsCallouts because the underlying prompt invocation
 * (via Flow.Interview -> generatePromptResponse action) counts as a callout.
 */
public with sharing class ClassifyQueueable implements Queueable, Database.AllowsCallouts {

    @TestVisible
    private static final String SPIKE_FLOW_NAME = 'AIDocSplitClassifySpike';

    private final Id jobId;
    private final Integer chunkIndex;
    private final Id chunkContentDocumentId;
    private final Integer pageOffset;

    public ClassifyQueueable(Id jobId, Integer chunkIndex, Id chunkContentDocumentId, Integer pageOffset) {
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
        this.jobId = jobId;
        this.chunkIndex = chunkIndex;
        this.chunkContentDocumentId = chunkContentDocumentId;
        this.pageOffset = pageOffset;
    }

    public void execute(QueueableContext context) {
        try {
            String rawJson = invokeClassifyFlow(chunkContentDocumentId);
            List<DocSegment> segments = parseAndShift(rawJson, pageOffset);
            appendSegmentsToJob(jobId, segments);
            SplitJobService.recordChunkCompletion(jobId);
        } catch (Exception e) {
            SplitJobService.failJob(jobId,
                'Classify chunk ' + chunkIndex,
                e.getTypeName() + ': ' + e.getMessage());
        }
    }

    /**
     * Invokes the AIDocSplitClassifySpike autolaunched flow with the chunk's
     * ContentDocument Id. Returns the raw JSON segments string the flow's
     * generatePromptResponse action produced.
     *
     * Overridable in tests via the testStubResponse static field to avoid making
     * a real prompt callout during unit tests.
     */
    @TestVisible
    private static String invokeClassifyFlow(Id contentDocumentId) {
        if (Test.isRunningTest() && testStubResponse != null) {
            return testStubResponse;
        }
        Map<String, Object> inputs = new Map<String, Object>{
            'fileContentDocumentId' => (String) contentDocumentId
        };
        Flow.Interview interview = Flow.Interview.createInterview(SPIKE_FLOW_NAME, inputs);
        interview.start();
        String response = (String) interview.getVariableValue('segmentsJson');
        return response == null ? '' : response;
    }

    /**
     * Parse the prompt's JSON array, drop any malformed entries, and shift
     * page numbers by (pageOffset - 1) so they're absolute in the bundle.
     * The prompt returns 1-based page numbers WITHIN the chunk; if the chunk
     * starts at absolute page 9 (pageOffset=9), chunk-local page 1 -> absolute 9.
     *
     * Expected JSON shape per item: { document_type, source_institution,
     * named_party, instance_label, pages: [int, ...] }.
     */
    @TestVisible
    private static List<DocSegment> parseAndShift(String rawJson, Integer pageOffset) {
        List<DocSegment> out = new List<DocSegment>();
        if (String.isBlank(rawJson)) {
            return out;
        }
        String cleaned = rawJson.trim();
        if (cleaned.startsWith('```')) {
            Integer arrStart = cleaned.indexOf('[');
            Integer arrEnd = cleaned.lastIndexOf(']');
            if (arrStart >= 0 && arrEnd > arrStart) {
                cleaned = cleaned.substring(arrStart, arrEnd + 1);
            }
        }
        List<Object> items = (List<Object>) JSON.deserializeUntyped(cleaned);
        Integer shift = pageOffset - 1;
        for (Object item : items) {
            if (!(item instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> m = (Map<String, Object>) item;
            Object pagesObj = m.get('pages');
            if (!(pagesObj instanceof List<Object>)) {
                continue;
            }
            List<Integer> shiftedPages = new List<Integer>();
            for (Object p : (List<Object>) pagesObj) {
                if (p instanceof Integer) {
                    shiftedPages.add(((Integer) p) + shift);
                } else if (p instanceof Decimal) {
                    shiftedPages.add(((Decimal) p).intValue() + shift);
                }
            }
            if (shiftedPages.isEmpty()) {
                continue;
            }
            DocSegment s = new DocSegment();
            s.documentType      = (String) m.get('document_type');
            s.sourceInstitution = (String) m.get('source_institution');
            s.namedParty        = (String) m.get('named_party');
            s.instanceLabel     = (String) m.get('instance_label');
            s.pages             = shiftedPages;
            out.add(s);
        }
        return out;
    }

    /**
     * Append a chunk's segments to Split_Job__c.Raw_Segments_JSON__c under a
     * row lock. The lock serializes concurrent Queueables -- only one at a time
     * reads the current accumulator, appends, and writes back.
     *
     * Stores the segments using DocSegment's field names (documentType,
     * sourceInstitution, namedParty, instanceLabel, pages) so SplitJobService.
     * deserializeRawSegments can read them back as typed objects.
     *
     * Also raises Total_Pages__c to the max page seen across all segments in
     * this chunk. The single-call headless path (DocSplitterInvocable) creates
     * the job with totalPages=1 as a placeholder since pdf-lib isn't in the
     * loop; the LLM's response is the first time we learn the real page count.
     * SegmentMerger uses Total_Pages__c to clamp page numbers, so getting this
     * right is load-bearing — wrong totalPages drops every page above it.
     */
    private static void appendSegmentsToJob(Id jobId, List<DocSegment> segments) {
        if (segments.isEmpty()) {
            return;
        }
        Split_Job__c job = [SELECT Id, Raw_Segments_JSON__c, Total_Pages__c
                            FROM Split_Job__c
                            WHERE Id = :jobId
                            WITH USER_MODE
                            FOR UPDATE];
        List<Object> accumulator = String.isBlank(job.Raw_Segments_JSON__c)
            ? new List<Object>()
            : (List<Object>) JSON.deserializeUntyped(job.Raw_Segments_JSON__c);

        Integer maxPageInChunk = 0;
        for (DocSegment s : segments) {
            if (s.pages != null) {
                for (Integer p : s.pages) {
                    if (p != null && p > maxPageInChunk) maxPageInChunk = p;
                }
            }
            accumulator.add(new Map<String, Object>{
                'documentType' => s.documentType,
                'sourceInstitution' => s.sourceInstitution,
                'namedParty' => s.namedParty,
                'instanceLabel' => s.instanceLabel,
                'pages' => s.pages
            });
        }

        job.Raw_Segments_JSON__c = JSON.serialize(accumulator).left(32768);
        Integer currentTotal = job.Total_Pages__c == null ? 0 : ((Integer) job.Total_Pages__c);
        if (maxPageInChunk > currentTotal) {
            job.Total_Pages__c = maxPageInChunk;
        }
        Database.update(job, AccessLevel.USER_MODE);
    }

    /**
     * Test hook -- when set, invokeClassifyFlow returns this string instead of
     * actually invoking the prompt flow. Lets unit tests exercise the parse +
     * accumulate + recordChunkCompletion path without an AI callout.
     */
    @TestVisible
    private static String testStubResponse;
}

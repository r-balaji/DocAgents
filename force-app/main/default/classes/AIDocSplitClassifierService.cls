/**
 * Service that classifies one uploaded PDF chunk by calling the split prompt
 * Flow and appending normalized page segments to Split_Job__c.
 *
 * The async boundary is owned by PdfServiceChunkClassifyBatch. This service is
 * deliberately synchronous so UI, headless, and test paths all use the same
 * chunk classification logic.
 */
public with sharing class AIDocSplitClassifierService {

    @TestVisible
    private static final String SPLIT_FLOW_NAME = 'AIDocSplitClassifySpike';
    private static final Integer MAX_AUDITED_RESPONSE_CHARS = 4000;

    /**
     * Test hook -- when set, invokeClassifyFlow returns this string instead of
     * actually invoking the prompt flow.
     */
    @TestVisible
    private static String testStubResponse;

    private AIDocSplitClassifierService() {
        // Service class -- instantiation prevented.
    }

    /**
     * Classifies one chunk in the current transaction.
     * @param jobId Split job accumulating this chunk result.
     * @param chunkIndex Zero-based chunk index for diagnostics.
     * @param chunkContentDocumentId ContentDocument Id for the chunk PDF.
     * @param pageOffset First source-page number represented in the chunk.
     */
    public static void classifyChunk(Id jobId, Integer chunkIndex, Id chunkContentDocumentId, Integer pageOffset) {
        try {
            String rawJson = invokeClassifyFlow(chunkContentDocumentId);
            appendLlmResponseAudit(jobId, chunkIndex, chunkContentDocumentId, pageOffset, rawJson);
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
     * Invokes the AIDocSplitClassifySpike autolaunched Flow with the chunk's
     * ContentDocument Id. Returns the raw JSON segments string the Flow's prompt
     * action produced.
     */
    @TestVisible
    private static String invokeClassifyFlow(Id contentDocumentId) {
        if (Test.isRunningTest() && testStubResponse != null) {
            return testStubResponse;
        }
        Map<String, Object> inputs = new Map<String, Object>{
            'fileContentDocumentId' => (String) contentDocumentId
        };
        Flow.Interview interview = Flow.Interview.createInterview(SPLIT_FLOW_NAME, inputs);
        interview.start();
        String response = (String) interview.getVariableValue('segmentsJson');
        return response == null ? '' : response;
    }

    /**
     * Parses the prompt JSON array and shifts chunk-local page numbers to
     * absolute bundle page numbers.
     */
    @TestVisible
    private static List<DocSegment> parseAndShift(String rawJson, Integer pageOffset) {
        List<DocSegment> out = new List<DocSegment>();
        if (String.isBlank(rawJson)) {
            return out;
        }
        String cleaned = extractJsonArray(rawJson);
        if (String.isBlank(cleaned)) {
            return out;
        }

        List<Object> items;
        try {
            items = (List<Object>) JSON.deserializeUntyped(cleaned);
        } catch (JSONException e) {
            return out;
        }
        Integer shift = pageOffset - 1;
        for (Object item : items) {
            if (!(item instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> row = (Map<String, Object>) item;
            Object pagesObj = row.get('pages');
            if (!(pagesObj instanceof List<Object>)) {
                continue;
            }
            List<Integer> shiftedPages = new List<Integer>();
            for (Object page : (List<Object>) pagesObj) {
                if (page instanceof Integer) {
                    shiftedPages.add(((Integer) page) + shift);
                } else if (page instanceof Decimal) {
                    shiftedPages.add(((Decimal) page).intValue() + shift);
                }
            }
            if (shiftedPages.isEmpty()) {
                continue;
            }
            DocSegment segment = new DocSegment();
            segment.documentType = (String) row.get('document_type');
            segment.sourceInstitution = (String) row.get('source_institution');
            segment.namedParty = (String) row.get('named_party');
            segment.instanceLabel = (String) row.get('instance_label');
            segment.pages = shiftedPages;
            out.add(segment);
        }
        return out;
    }

    @TestVisible
    private static String extractJsonArray(String rawJson) {
        if (String.isBlank(rawJson)) {
            return '';
        }
        String cleaned = rawJson.trim();
        Integer arrStart = cleaned.indexOf('[');
        Integer arrEnd = cleaned.lastIndexOf(']');
        if (arrStart >= 0 && arrEnd > arrStart) {
            return cleaned.substring(arrStart, arrEnd + 1);
        }
        return cleaned.startsWith('[') ? cleaned : '';
    }

    @TestVisible
    private static void appendLlmResponseAudit(
        Id jobId,
        Integer chunkIndex,
        Id chunkContentDocumentId,
        Integer pageOffset,
        String rawResponse
    ) {
        Split_Job__c job = [
            SELECT Id, LLM_Response_Audit_JSON__c
            FROM Split_Job__c
            WHERE Id = :jobId
            WITH USER_MODE
            FOR UPDATE
        ];
        List<Object> auditRows = parseAuditRows(job.LLM_Response_Audit_JSON__c);

        String response = rawResponse == null ? '' : rawResponse;
        Boolean wasTruncated = response.length() > MAX_AUDITED_RESPONSE_CHARS;
        auditRows.add(new Map<String, Object>{
            'chunkIndex' => chunkIndex,
            'chunkContentDocumentId' => String.valueOf(chunkContentDocumentId),
            'pageOffset' => pageOffset,
            'responseLength' => response.length(),
            'responseWasTruncated' => wasTruncated,
            'rawResponse' => wasTruncated ? response.left(MAX_AUDITED_RESPONSE_CHARS) : response
        });

        job.LLM_Response_Audit_JSON__c = serializeBoundedAudit(auditRows);
        Database.update(job, AccessLevel.USER_MODE);
    }

    private static List<Object> parseAuditRows(String auditJson) {
        if (String.isBlank(auditJson)) {
            return new List<Object>();
        }
        try {
            Object parsed = JSON.deserializeUntyped(auditJson);
            return parsed instanceof List<Object> ? (List<Object>) parsed : new List<Object>();
        } catch (JSONException e) {
            return new List<Object>();
        }
    }

    private static String serializeBoundedAudit(List<Object> auditRows) {
        String serialized = JSON.serialize(auditRows);
        while (serialized.length() > 32768 && auditRows.size() > 1) {
            auditRows.remove(0);
            serialized = JSON.serialize(auditRows);
        }
        return serialized.left(32768);
    }

    private static void appendSegmentsToJob(Id jobId, List<DocSegment> segments) {
        if (segments.isEmpty()) {
            return;
        }
        Split_Job__c job = [
            SELECT Id, Raw_Segments_JSON__c, Total_Pages__c
            FROM Split_Job__c
            WHERE Id = :jobId
            WITH USER_MODE
            FOR UPDATE
        ];
        List<Object> accumulator = String.isBlank(job.Raw_Segments_JSON__c)
            ? new List<Object>()
            : (List<Object>) JSON.deserializeUntyped(job.Raw_Segments_JSON__c);

        Integer maxPageInChunk = 0;
        for (DocSegment segment : segments) {
            if (segment.pages != null) {
                for (Integer page : segment.pages) {
                    if (page != null && page > maxPageInChunk) {
                        maxPageInChunk = page;
                    }
                }
            }
            accumulator.add(new Map<String, Object>{
                'documentType' => segment.documentType,
                'sourceInstitution' => segment.sourceInstitution,
                'namedParty' => segment.namedParty,
                'instanceLabel' => segment.instanceLabel,
                'pages' => segment.pages
            });
        }

        job.Raw_Segments_JSON__c = JSON.serialize(accumulator).left(32768);
        Integer currentTotal = job.Total_Pages__c == null ? 0 : ((Integer) job.Total_Pages__c);
        if (maxPageInChunk > currentTotal) {
            job.Total_Pages__c = maxPageInChunk;
        }
        Database.update(job, AccessLevel.USER_MODE);
    }
}

/**
 * Thin HTTP client for the self-hosted pdf-lib service.
 *
 * Apex sends only IDs + a short-lived OAuth access token in the request body.
 * The service uses that token to talk directly to Salesforce Files REST for
 * the byte transfer, so PDF bytes never go through the Apex callout payload
 * (~12 MB cap). File size is bounded by Salesforce Files (2 GB), not Apex.
 *
 * Endpoint resolution (in order):
 *   1. Pdf_Service_Config__mdt.Default.Endpoint_Override__c — if populated
 *   2. callout:PdfLibService — the Named Credential's configured URL
 *
 * Auth: the platform auto-injects "Authorization: Bearer <key>" via the
 * PdfLibServiceCred External Credential. No Apex code touches the key.
 */
public with sharing class PdfServiceClient {

    @TestVisible
    private static final String CHUNKS_PATH = '/v1/chunks';
    @TestVisible
    private static final String SPLITS_PATH = '/v1/splits';

    private static final String NAMED_CRED_PREFIX = 'callout:PdfLibService';
    private static final Integer CALLOUT_TIMEOUT_MS = 120000;   // 2 min — chunk + slice of 30 MB can take ~30-60s
    private static final String SF_API_VERSION = '60.0';

    private final String endpointBase;

    /**
     * Test-only endpoint override so HttpCalloutMock tests can use a non-
     * Named-Credential URL. Auth is mocked at the HTTP layer regardless.
     */
    @TestVisible
    private static String testEndpointOverride;

    public PdfServiceClient() {
        if (Test.isRunningTest() && String.isNotBlank(testEndpointOverride)) {
            this.endpointBase = testEndpointOverride;
            return;
        }
        Pdf_Service_Config__mdt cfg = readConfig();
        this.endpointBase = (cfg != null && String.isNotBlank(cfg.Endpoint_Override__c))
            ? cfg.Endpoint_Override__c
            : NAMED_CRED_PREFIX;
    }

    /**
     * POST /v1/chunks — service downloads source from Salesforce, splits into
     * overlapping chunks, uploads each chunk back as a ContentVersion, returns
     * the chunk metadata.
     */
    public ChunksResponse callChunks(ChunksRequest req) {
        String payload = JSON.serialize(req);
        HttpResponse res = post(CHUNKS_PATH, payload);
        return (ChunksResponse) JSON.deserialize(res.getBody(), ChunksResponse.class);
    }

    /**
     * POST /v1/splits — service downloads source from Salesforce, slices by
     * the segment manifest, uploads each output as a ContentVersion (optionally
     * linked to a record), returns the output metadata.
     */
    public SplitsResponse callSplits(SplitsRequest req) {
        String payload = JSON.serialize(req);
        HttpResponse res = post(SPLITS_PATH, payload);
        return (SplitsResponse) JSON.deserialize(res.getBody(), SplitsResponse.class);
    }

    /**
     * Build a session token + SF context block to embed in every request.
     * Uses UserInfo.getSessionId() so the service inherits the running user's
     * permissions. Apex async (Queueable) supports getSessionId().
     */
    public static SfContext currentSfContext() {
        SfContext ctx = new SfContext();
        ctx.sfInstanceUrl = URL.getOrgDomainUrl().toExternalForm();
        ctx.sfAccessToken = UserInfo.getSessionId();
        ctx.sfApiVersion = SF_API_VERSION;
        return ctx;
    }

    @TestVisible
    private HttpResponse post(String path, String body) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpointBase + path);
        req.setMethod('POST');
        // Authorization header is injected automatically by the PdfLibServiceCred
        // External Credential via the Named Credential's generateAuthorizationHeader.
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        req.setTimeout(CALLOUT_TIMEOUT_MS);
        req.setBody(body);

        Http http = new Http();
        HttpResponse res = http.send(req);

        Integer code = res.getStatusCode();
        if (code >= 200 && code < 300) {
            return res;
        }
        if (code >= 500) {
            // One retry on 5xx with a short backoff. PDF service errors are usually
            // deterministic, but a cold-start or transient hiccup deserves one chance.
            HttpResponse retry = http.send(req);
            if (retry.getStatusCode() >= 200 && retry.getStatusCode() < 300) {
                return retry;
            }
            throw new PdfServiceException('PDF service returned ' + retry.getStatusCode() + ': ' + retry.getBody().left(500));
        }
        throw new PdfServiceException('PDF service returned ' + code + ': ' + res.getBody().left(500));
    }

    @TestVisible
    private static Pdf_Service_Config__mdt readConfig() {
        // Optional record — used only for the Endpoint_Override__c escape hatch.
        // Returns null cleanly when the record isn't deployed; constructor falls
        // back to the Named Credential URL.
        return Pdf_Service_Config__mdt.getInstance('Default');
    }

    // ----- DTOs --------------------------------------------------------------

    public class SfContext {
        public String sfInstanceUrl;
        public String sfAccessToken;
        public String sfApiVersion;
    }

    public class ChunksRequest {
        public String jobId;
        public String sourceContentVersionId;
        public String sfInstanceUrl;
        public String sfAccessToken;
        public String sfApiVersion;
        public String libraryId;
        public Integer chunkSize;
        public Integer overlap;
    }

    public class ChunkRecord {
        public Integer chunkIndex;
        public String contentDocumentId;
        public String contentVersionId;
        public Integer pageOffset;
        public Integer pageCount;
    }

    public class ChunksResponse {
        public Integer totalPages;
        public List<ChunkRecord> chunks;
    }

    public class SegmentInput {
        public String documentType;
        public String sourceInstitution;
        public String namedParty;
        public String instanceLabel;
        public List<Integer> pages;
        public String fileName;
    }

    public class SplitsRequest {
        public String jobId;
        public String sourceContentVersionId;
        public String sfInstanceUrl;
        public String sfAccessToken;
        public String sfApiVersion;
        public String libraryId;
        public String targetFolderId;
        public String linkToRecordId;
        public List<SegmentInput> segments;
    }

    public class SplitOutput {
        public String fileName;
        public String contentDocumentId;
        public String contentVersionId;
        public String documentType;
        public List<Integer> pages;
    }

    public class SplitsResponse {
        public List<SplitOutput> outputs;
    }

    public class PdfServiceException extends Exception {}
}

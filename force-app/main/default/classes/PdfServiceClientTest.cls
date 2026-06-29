/**
 * Tests for PdfServiceClient.
 *
 * Uses Test.setMock(HttpCalloutMock) to fake responses from the self-hosted
 * pdf-lib service. Exercises happy path, retry-on-5xx, error mapping, and
 * the config-missing guard. The Custom Metadata Type record is bypassed via
 * the @TestVisible testApiKeyOverride / testEndpointOverride static fields.
 */
@IsTest
private class PdfServiceClientTest {

    private static void stubConfig() {
        // Override the endpoint so HttpCalloutMock fires on a clean URL.
        // Auth is mocked at the HTTP layer — no API key required from Apex
        // since the platform injects it via the External Credential.
        PdfServiceClient.testEndpointOverride = 'https://pdf.example.test';
    }

    @IsTest
    static void shouldConstructCleanly_WhenNoEndpointOverride() {
        // Without a CMT endpoint override, the client uses the Named Credential.
        // Constructor must not throw — the External Credential handles auth.
        Test.startTest();
        PdfServiceClient client = new PdfServiceClient();
        Assert.isNotNull(client);
        Test.stopTest();
    }

    @IsTest
    static void shouldReturnChunks_WhenServiceResponds200() {
        stubConfig();
        Test.setMock(HttpCalloutMock.class, new MockResponse(200, fakeChunksResponseJson()));

        Test.startTest();
        PdfServiceClient.ChunksResponse res = new PdfServiceClient().callChunks(buildChunksRequest());
        Test.stopTest();

        Assert.areEqual(14, res.totalPages, 'Total pages echoed');
        Assert.areEqual(2, res.chunks.size(), 'Two chunks returned');
        Assert.areEqual(0, res.chunks[0].chunkIndex);
        Assert.areEqual('069fakechunk0', res.chunks[0].contentDocumentId);
        Assert.areEqual(1, res.chunks[0].pageOffset);
    }

    @IsTest
    static void shouldReturnSplits_WhenServiceResponds200() {
        stubConfig();
        Test.setMock(HttpCalloutMock.class, new MockResponse(200, fakeSplitsResponseJson()));

        Test.startTest();
        PdfServiceClient.SplitsResponse res = new PdfServiceClient().callSplits(buildSplitsRequest());
        Test.stopTest();

        Assert.areEqual(2, res.outputs.size(), 'Two outputs returned');
        Assert.areEqual('BankStatement_Chase_John_Smith.pdf', res.outputs[0].fileName);
        Assert.areEqual('BANK_STATEMENT', res.outputs[0].documentType);
    }

    @IsTest
    static void shouldRetryOnce_WhenServiceReturns500ThenSucceeds() {
        stubConfig();
        MockResponse mock = new MockResponse();
        mock.queue.add(new MockFrame(500, 'transient'));
        mock.queue.add(new MockFrame(200, fakeChunksResponseJson()));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        PdfServiceClient.ChunksResponse res = new PdfServiceClient().callChunks(buildChunksRequest());
        Test.stopTest();

        Assert.areEqual(2, mock.callCount, 'Should have retried once on 5xx');
        Assert.areEqual(14, res.totalPages, 'Retry response parsed');
    }

    @IsTest
    static void shouldThrow_WhenServiceReturns400() {
        stubConfig();
        Test.setMock(HttpCalloutMock.class, new MockResponse(400, '{"error":"bad payload"}'));

        Test.startTest();
        try {
            new PdfServiceClient().callChunks(buildChunksRequest());
            Assert.fail('Expected exception on 4xx');
        } catch (PdfServiceClient.PdfServiceException e) {
            Assert.isTrue(e.getMessage().contains('400'), 'Message should include status code');
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldThrow_WhenBoth500Responses() {
        stubConfig();
        MockResponse mock = new MockResponse();
        mock.queue.add(new MockFrame(500, 'fail1'));
        mock.queue.add(new MockFrame(500, 'fail2'));
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        try {
            new PdfServiceClient().callChunks(buildChunksRequest());
            Assert.fail('Expected exception when retry also fails');
        } catch (PdfServiceClient.PdfServiceException e) {
            Assert.isTrue(e.getMessage().contains('500'));
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldBuildSfContext_WithSessionAndInstance() {
        Test.startTest();
        PdfServiceClient.SfContext ctx = PdfServiceClient.currentSfContext();
        Test.stopTest();
        Assert.isNotNull(ctx.sfAccessToken, 'Session id present');
        Assert.isTrue(ctx.sfInstanceUrl.startsWith('https://'), 'Instance URL has https scheme');
        Assert.areEqual('60.0', ctx.sfApiVersion);
    }

    // ----- Helpers ----------------------------------------------------------

    private static PdfServiceClient.ChunksRequest buildChunksRequest() {
        PdfServiceClient.ChunksRequest r = new PdfServiceClient.ChunksRequest();
        r.jobId = 'fakeJobId';
        r.sourceContentVersionId = '068fakecv';
        r.sfInstanceUrl = 'https://example.my.salesforce.com';
        r.sfAccessToken = 'fakeToken';
        r.sfApiVersion = '60.0';
        r.chunkSize = 8;
        r.overlap = 2;
        return r;
    }

    private static PdfServiceClient.SplitsRequest buildSplitsRequest() {
        PdfServiceClient.SplitsRequest r = new PdfServiceClient.SplitsRequest();
        r.jobId = 'fakeJobId';
        r.sourceContentVersionId = '068fakecv';
        r.sfInstanceUrl = 'https://example.my.salesforce.com';
        r.sfAccessToken = 'fakeToken';
        r.sfApiVersion = '60.0';
        r.segments = new List<PdfServiceClient.SegmentInput>();
        PdfServiceClient.SegmentInput s1 = new PdfServiceClient.SegmentInput();
        s1.documentType = 'BANK_STATEMENT';
        s1.fileName = 'BankStatement_Chase_John_Smith.pdf';
        s1.pages = new List<Integer>{1, 2, 3};
        r.segments.add(s1);
        return r;
    }

    private static String fakeChunksResponseJson() {
        return '{"totalPages":14,"chunks":['
            + '{"chunkIndex":0,"contentDocumentId":"069fakechunk0","contentVersionId":"068fakecv0","pageOffset":1,"pageCount":8},'
            + '{"chunkIndex":1,"contentDocumentId":"069fakechunk1","contentVersionId":"068fakecv1","pageOffset":7,"pageCount":8}'
            + ']}';
    }

    private static String fakeSplitsResponseJson() {
        return '{"outputs":['
            + '{"fileName":"BankStatement_Chase_John_Smith.pdf","contentDocumentId":"069out0","contentVersionId":"068out0","documentType":"BANK_STATEMENT","pages":[1,2,3]},'
            + '{"fileName":"DriversLicense_John_Smith.pdf","contentDocumentId":"069out1","contentVersionId":"068out1","documentType":"DRIVERS_LICENSE","pages":[4]}'
            + ']}';
    }

    // ----- Mock with optional queue for retry testing -----------------------

    private class MockFrame {
        Integer status;
        String body;
        MockFrame(Integer status, String body) {
            this.status = status;
            this.body = body;
        }
    }

    public class MockResponse implements HttpCalloutMock {
        Integer fixedStatus;
        String fixedBody;
        List<MockFrame> queue = new List<MockFrame>();
        Integer callCount = 0;

        public MockResponse() {}
        public MockResponse(Integer status, String body) {
            this.fixedStatus = status;
            this.fixedBody = body;
        }

        public HttpResponse respond(HttpRequest req) {
            callCount++;
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            MockFrame frame = queue.isEmpty()
                ? new MockFrame(fixedStatus, fixedBody)
                : queue.remove(0);
            res.setStatusCode(frame.status);
            res.setBody(frame.body);
            return res;
        }
    }
}

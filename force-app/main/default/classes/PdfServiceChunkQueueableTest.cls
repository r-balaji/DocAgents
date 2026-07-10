/**
 * Tests for PdfServiceChunkQueueable.
 *
 * The Queueable mints a SF session token via UserInfo.getSessionId() and calls
 * the self-hosted service. We mock the HTTP response. The downstream
 * Batch Apex handoff is skipped via Test.isRunningTest() inside the Queueable
 * so this test can focus on the chunk service boundary.
 */
@IsTest
private class PdfServiceChunkQueueableTest {

    @TestSetup
    static void createUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            FirstName = 'AIDoc', LastName = 'ChunkTest',
            Email = 'aidoc.chunk@example.com.invalid',
            Username = 'aidoc.chunk+' + System.currentTimeMillis() + '@example.com.invalid',
            Alias = 'aidocc', TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US', ProfileId = p.Id
        );
        insert u;
        PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'AIDocAccess' LIMIT 1];
        insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
    }

    private static User getUser() {
        return [SELECT Id FROM User WHERE Username LIKE 'aidoc.chunk+%@example.com.invalid' LIMIT 1];
    }

    @IsTest
    static void shouldThrowWhenConstructedWithNullJobId() {
        Test.startTest();
        try {
            new PdfServiceChunkQueueable(null);
            Assert.fail('Expected SplitJobException');
        } catch (SplitJobException e) {
            Assert.isTrue(e.getMessage().contains('jobId'));
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldFailJobWhenServiceErrorsOut() {
        // ContentVersion lookup fails because no actual file exists; that's enough
        // to exercise the catch path. The Queueable should mark the job as Error.
        PdfServiceClient.testEndpointOverride = 'https://pdf.example.test';

        Id jobId;
        Test.startTest();
        System.runAs(getUser()) {
            jobId = SplitJobService.startJob(fakeContentDocumentId(), fakeLibraryId(), null, null, 14, 2, true);
            new PdfServiceChunkQueueable(jobId).execute(null);
        }
        Test.stopTest();

        Split_Job__c after = [SELECT Status__c, Error_Detail__c FROM Split_Job__c WHERE Id = :jobId];
        Assert.areEqual('Error', after.Status__c, 'No source CV should use the Error path');
        Assert.isTrue(after.Error_Detail__c.contains('PdfServiceChunk'), 'Stage label captured');
    }

    @IsTest
    static void shouldUpdateJobWhenServiceReturnsChunks() {
        PdfServiceClient.testEndpointOverride = 'https://pdf.example.test';
        Test.setMock(HttpCalloutMock.class, new MockResponse(200, fakeChunksResponseJson()));
        Id sourceContentDocumentId = createContentDocument('large_source_bundle');
        Id jobId;
        jobId = SplitJobService.startJob(sourceContentDocumentId, fakeLibraryId(), null, null, 1, 1, true);

        Test.startTest();
        System.enqueueJob(new PdfServiceChunkQueueable(jobId));
        Test.stopTest();

        Split_Job__c after = [
            SELECT Status__c, Chunk_Count__c, Total_Pages__c
            FROM Split_Job__c
            WHERE Id = :jobId
        ];
        Assert.areEqual('Detecting', after.Status__c, 'chunk response should advance job to Detecting');
        Assert.areEqual(2, after.Chunk_Count__c, 'chunk count should come from service response');
        Assert.areEqual(14, after.Total_Pages__c, 'total pages should come from service response');
    }

    private static Id createContentDocument(String title) {
        ContentVersion version = new ContentVersion(
            Title = title,
            PathOnClient = title + '.pdf',
            VersionData = Blob.valueOf('PDF-BYTES-' + title),
            IsMajorVersion = true
        );
        insert version;
        return [
            SELECT ContentDocumentId
            FROM ContentVersion
            WHERE Id = :version.Id
            LIMIT 1
        ].ContentDocumentId;
    }

    private static Id fakeLibraryId() {
        return (Id) (ContentWorkspace.SObjectType
            .getDescribe(SObjectDescribeOptions.DEFERRED)
            .getKeyPrefix() + String.valueOf(UserInfo.getOrganizationId()).right(12));
    }

    private static Id fakeContentDocumentId() {
        return (Id) (ContentDocument.SObjectType
            .getDescribe(SObjectDescribeOptions.DEFERRED)
            .getKeyPrefix() + String.valueOf(UserInfo.getOrganizationId()).right(12));
    }

    private static Id fakeContentDocumentId(Integer seed) {
        String suffix = String.valueOf(UserInfo.getOrganizationId()).right(11) + String.valueOf(seed == null ? 1 : seed);
        return (Id) (ContentDocument.SObjectType
            .getDescribe(SObjectDescribeOptions.DEFERRED)
            .getKeyPrefix() + suffix);
    }

    private static String fakeChunksResponseJson() {
        String firstChunkId = String.valueOf(fakeContentDocumentId(1));
        String secondChunkId = String.valueOf(fakeContentDocumentId(2));
        return '{"totalPages":14,"chunks":['
            + '{"chunkIndex":0,"contentDocumentId":"' + firstChunkId + '","contentVersionId":"068fakecv000000","pageOffset":1,"pageCount":8},'
            + '{"chunkIndex":1,"contentDocumentId":"' + secondChunkId + '","contentVersionId":"068fakecv000001","pageOffset":7,"pageCount":8}'
            + ']}';
    }

    private class MockResponse implements HttpCalloutMock {
        private final Integer statusCode;
        private final String responseBody;

        private MockResponse(Integer statusCode, String responseBody) {
            this.statusCode = statusCode;
            this.responseBody = responseBody;
        }

        public HttpResponse respond(HttpRequest req) {
            Assert.isTrue(req.getBody().contains('"maxChunkBytes":10485760'), 'Chunk request should target 10 MB chunks');
            Assert.isFalse(req.getBody().contains('chunkSize'), 'Chunk request should not include the legacy page-count cap');
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setStatusCode(statusCode);
            res.setBody(responseBody);
            return res;
        }
    }
}

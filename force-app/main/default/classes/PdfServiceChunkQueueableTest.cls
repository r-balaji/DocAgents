/**
 * Tests for PdfServiceChunkQueueable.
 *
 * The Queueable mints a SF session token via UserInfo.getSessionId() and calls
 * the self-hosted service. We mock the HTTP response. The downstream
 * enqueueJob for ClassifyQueueable is skipped via Test.isRunningTest() inside
 * the Queueable so the test transaction doesn't blow chain depth.
 */
@IsTest
private class PdfServiceChunkQueueableTest {

    private static final Id FAKE_SOURCE_CD = '069000000000001AAA';
    private static final Id FAKE_LIBRARY = '058000000000001AAA';

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
    static void shouldThrow_WhenConstructedWithNullJobId() {
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
    static void shouldFailJob_WhenServiceErrorsOut() {
        // ContentVersion lookup fails because no actual file exists — that's enough
        // to exercise the catch path. The Queueable should mark the job as Error.
        PdfServiceClient.testEndpointOverride = 'https://pdf.example.test';

        Id jobId;
        Test.startTest();
        System.runAs(getUser()) {
            jobId = SplitJobService.startJob(FAKE_SOURCE_CD, FAKE_LIBRARY, null, null, 14, 2, true);
            new PdfServiceChunkQueueable(jobId).execute(null);
        }
        Test.stopTest();

        Split_Job__c after = [SELECT Status__c, Error_Detail__c FROM Split_Job__c WHERE Id = :jobId];
        Assert.areEqual('Error', after.Status__c, 'No source CV → Error path');
        Assert.isTrue(after.Error_Detail__c.contains('PdfServiceChunk'), 'Stage label captured');
    }
}

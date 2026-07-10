/**
 * Tests for DocSplitterInvocable @InvocableMethod.
 *
 * Exercises input validation. End-to-end behavior requires a real
 * ContentVersion to inspect ContentSize; that path is verified in the
 * sandbox smoke test described in the splitter walkthrough.
 */
@IsTest
private class DocSplitterInvocableTest {

    @TestSetup
    static void createUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            FirstName = 'AIDoc', LastName = 'InvocableTest',
            Email = 'aidoc.invocable@example.com.invalid',
            Username = 'aidoc.invocable+' + System.currentTimeMillis() + '@example.com.invalid',
            Alias = 'aidoci', TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US', ProfileId = p.Id
        );
        insert u;
        PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'AIDocAccess' LIMIT 1];
        insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
    }

    @IsTest
    static void shouldStartSingleCallJob_WhenFileWithinThreshold() {
        List<DocSplitterInvocable.Response> responses;

        System.runAs(getUser()) {
            DocSplitterInvocable.Request req = new DocSplitterInvocable.Request();
            req.sourceContentDocumentId = createContentDocument('small_bundle');
            req.libraryId = fakeLibraryId();

            Test.startTest();
            responses = DocSplitterInvocable.startHeadlessSplit(new List<DocSplitterInvocable.Request>{ req });
            Test.stopTest();
        }

        Assert.areEqual(1, responses.size(), 'One response should be returned');
        Assert.isTrue(responses[0].isSingleCall, 'Small file should use single-call path');
        Split_Job__c job = [SELECT Status__c, Chunk_Count__c, Is_Headless__c FROM Split_Job__c WHERE Id = :responses[0].jobId];
        Assert.areEqual('Queued', job.Status__c, 'Job should be queued in tests');
        Assert.areEqual(1, job.Chunk_Count__c, 'Single-call path has one classification unit');
        Assert.isTrue(job.Is_Headless__c, 'Invocable creates headless jobs');
    }

    @IsTest
    static void shouldStartChunkedJob_WhenFileExceedsThreshold() {
        List<DocSplitterInvocable.Response> responses;

        try {
            DocSplitterInvocable.forceChunkedPathForTest = true;
            System.runAs(getUser()) {
                DocSplitterInvocable.Request req = new DocSplitterInvocable.Request();
                req.sourceContentDocumentId = createContentDocument('large_bundle');
                req.libraryId = fakeLibraryId();

                Test.startTest();
                responses = DocSplitterInvocable.startHeadlessSplit(new List<DocSplitterInvocable.Request>{ req });
                Test.stopTest();
            }
        } finally {
            DocSplitterInvocable.forceChunkedPathForTest = false;
        }

        Assert.areEqual(1, responses.size(), 'One response should be returned');
        Assert.isFalse(responses[0].isSingleCall, 'Forced large-file path should use service chunking');
        Split_Job__c job = [SELECT Status__c, Chunk_Count__c, Is_Headless__c FROM Split_Job__c WHERE Id = :responses[0].jobId];
        Assert.areEqual('Queued', job.Status__c, 'Chunked path creates the placeholder job');
        Assert.areEqual(1, job.Chunk_Count__c, 'Placeholder chunk count is used until service returns chunks');
        Assert.isTrue(job.Is_Headless__c, 'Invocable creates headless jobs');
    }

    @IsTest
    static void shouldThrow_WhenSourceContentDocumentIdMissing() {
        DocSplitterInvocable.Request req = new DocSplitterInvocable.Request();
        req.sourceContentDocumentId = null;

        Test.startTest();
        try {
            DocSplitterInvocable.startHeadlessSplit(new List<DocSplitterInvocable.Request>{ req });
            Assert.fail('Expected AuraHandledException for null sourceContentDocumentId');
        } catch (AuraHandledException e) {
            Assert.areNotEqual(null, e);
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldThrow_WhenSourceNotFound() {
        DocSplitterInvocable.Request req = new DocSplitterInvocable.Request();
        req.sourceContentDocumentId = '069000000000999AAA';   // doesn't exist
        req.targetRecordId = '001000000000001AAA';

        Test.startTest();
        try {
            DocSplitterInvocable.startHeadlessSplit(new List<DocSplitterInvocable.Request>{ req });
            Assert.fail('Expected AuraHandledException for missing ContentVersion');
        } catch (AuraHandledException e) {
            Assert.areNotEqual(null, e);
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldExposeSingleCallThresholdConstant() {
        // Defensive check for the headless threshold. The LWC/browser threshold
        // is intentionally lower because UI mode moves bytes through Apex/LWC.
        Test.startTest();
        Integer threshold = DocSplitterInvocable.SINGLE_CALL_THRESHOLD_BYTES;
        Test.stopTest();
        Assert.areEqual(10 * 1024 * 1024, threshold, '10 MB headless threshold should remain unchanged');
    }

    private static User getUser() {
        return [SELECT Id FROM User WHERE Username LIKE 'aidoc.invocable+%@example.com.invalid' LIMIT 1];
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
}

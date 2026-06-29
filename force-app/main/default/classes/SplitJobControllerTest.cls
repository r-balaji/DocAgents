/**
 * Tests for SplitJobController.
 *
 * Coverage of the @AuraEnabled wrappers — input validation, error rethrow as
 * AuraHandledException, JSON parse helper, and end-to-end happy path that
 * round-trips through the underlying SplitJobService.
 */
@IsTest
private class SplitJobControllerTest {

    private static final Id FAKE_CD_ID = '069000000000001AAA';
    private static final Id FAKE_LIBRARY_ID = '058000000000001AAA';

    @TestSetup
    static void createTestUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            FirstName = 'AIDoc',
            LastName = 'CtrlTestUser',
            Email = 'aidoc.ctrl@example.com.invalid',
            Username = 'aidoc.ctrl+' + System.currentTimeMillis() + '@example.com.invalid',
            Alias = 'aidocc',
            TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId = p.Id
        );
        insert u;

        PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'AIDocAccess' LIMIT 1];
        insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = ps.Id);
    }

    private static User getTestUser() {
        return [SELECT Id FROM User WHERE Username LIKE 'aidoc.ctrl+%@example.com.invalid' LIMIT 1];
    }

    @IsTest
    static void shouldStartJob_HappyPath() {
        Id jobId;
        Test.startTest();
        System.runAs(getTestUser()) {
            jobId = SplitJobController.startJob(FAKE_CD_ID, FAKE_LIBRARY_ID, null, 14, 2);
        }
        Test.stopTest();

        Split_Job__c saved = [SELECT Status__c, Chunk_Count__c FROM Split_Job__c WHERE Id = :jobId];
        Assert.areEqual('Queued', saved.Status__c);
        Assert.areEqual(2, saved.Chunk_Count__c);
    }

    @IsTest
    static void shouldRethrowAuraHandled_WhenStartJobInputsInvalid() {
        Test.startTest();
        System.runAs(getTestUser()) {
            try {
                SplitJobController.startJob(null, FAKE_LIBRARY_ID, null, 1, 1);
                Assert.fail('Expected AuraHandledException for null sourceContentDocumentId');
            } catch (AuraHandledException e) {
                // AuraHandledException scrubs the original message — we just verify the type.
                Assert.areNotEqual(null, e);
            }
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldEnqueueChunkClassification_HappyPath() {
        // Stub the ClassifyQueueable's flow invocation so we don't hit the real
        // prompt template (and so a fake file Id doesn't break the test).
        ClassifyQueueable.testStubResponse = '[]';

        Id jobId;
        Test.startTest();
        System.runAs(getTestUser()) {
            jobId = SplitJobController.startJob(FAKE_CD_ID, FAKE_LIBRARY_ID, null, 14, 1);
            SplitJobController.enqueueChunkClassification(jobId, 0, FAKE_CD_ID, 1);
        }
        Test.stopTest();

        Split_Job__c after = [SELECT Status__c FROM Split_Job__c WHERE Id = :jobId];
        // After Test.stopTest the chained queueable runs. With chunkCount=1, this
        // chunk's completion takes the job through Merging to Splitting.
        Assert.isTrue(after.Status__c == 'Detecting' || after.Status__c == 'Splitting',
            'Expected Detecting (mid-flight) or Splitting (chain ran), got ' + after.Status__c);
    }

    @IsTest
    static void shouldRethrowAuraHandled_WhenEnqueueInputsInvalid() {
        Test.startTest();
        System.runAs(getTestUser()) {
            try {
                SplitJobController.enqueueChunkClassification(null, 0, FAKE_CD_ID, 1);
                Assert.fail('Expected AuraHandledException for null jobId');
            } catch (AuraHandledException e) {
                Assert.areNotEqual(null, e);
            }
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldStartSaving_HappyPath_EmptyList() {
        Id jobId;
        Test.startTest();
        System.runAs(getTestUser()) {
            jobId = SplitJobController.startJob(FAKE_CD_ID, FAKE_LIBRARY_ID, null, 5, 1);
            // Empty list finalizes the job immediately.
            SplitJobController.startSaving(jobId, '[]', 8);
        }
        Test.stopTest();

        Split_Job__c after = [SELECT Status__c, Documents_Created__c FROM Split_Job__c WHERE Id = :jobId];
        Assert.areEqual('Complete', after.Status__c);
        Assert.areEqual(0, after.Documents_Created__c);
    }

    @IsTest
    static void shouldStartSaving_HappyPath_WithFiles() {
        Id jobId;
        Test.startTest();
        System.runAs(getTestUser()) {
            jobId = SplitJobController.startJob(FAKE_CD_ID, FAKE_LIBRARY_ID, null, 5, 1);
            String tinyB64 = EncodingUtil.base64Encode(Blob.valueOf('%PDF-1.4\n%%EOF\n'));
            String requestsJson = '[{"fileName":"a.pdf","base64Content":"' + tinyB64
                + '","documentType":"DRIVERS_LICENSE","sourceInstitution":null,"namedParty":"John","instanceLabel":null,"pages":[1]}]';
            SplitJobController.startSaving(jobId, requestsJson, 8);
        }
        Test.stopTest();

        Split_Job__c after = [SELECT Status__c, Documents_Created__c FROM Split_Job__c WHERE Id = :jobId];
        Assert.areEqual('Complete', after.Status__c);
        Assert.areEqual(1, after.Documents_Created__c);
    }

    @IsTest
    static void shouldParseSaveRequests_RoundTrip() {
        String json = '[{"fileName":"a.pdf","base64Content":"YWJj","documentType":"DRIVERS_LICENSE",'
            + '"sourceInstitution":null,"namedParty":"John","instanceLabel":null,"pages":[1,3]}]';

        Test.startTest();
        List<SplitSaveRequest> parsed = SplitJobController.parseSaveRequests(json);
        Test.stopTest();

        Assert.areEqual(1, parsed.size());
        Assert.areEqual('a.pdf', parsed[0].fileName);
        Assert.areEqual('DRIVERS_LICENSE', parsed[0].documentType);
        Assert.areEqual('John', parsed[0].namedParty);
        Assert.areEqual(2, parsed[0].pages.size(), 'Two pages round-tripped');
        Assert.areEqual(1, parsed[0].pages[0]);
        Assert.areEqual(3, parsed[0].pages[1]);
    }

    @IsTest
    static void shouldParseSaveRequests_BlankInputReturnsEmpty() {
        Test.startTest();
        Assert.areEqual(0, SplitJobController.parseSaveRequests(null).size());
        Assert.areEqual(0, SplitJobController.parseSaveRequests('').size());
        Test.stopTest();
    }

    @IsTest
    static void shouldRethrowAuraHandled_WhenUploadInputsInvalid() {
        Test.startTest();
        System.runAs(getTestUser()) {
            try {
                SplitJobController.uploadChunkPdf(null, 'YWJj', FAKE_LIBRARY_ID);
                Assert.fail('Expected AuraHandledException for null fileName');
            } catch (AuraHandledException e) {
                Assert.areNotEqual(null, e);
            }
            try {
                SplitJobController.uploadChunkPdf('a.pdf', null, FAKE_LIBRARY_ID);
                Assert.fail('Expected AuraHandledException for null base64Content');
            } catch (AuraHandledException e) {
                Assert.areNotEqual(null, e);
            }
            try {
                SplitJobController.uploadChunkPdf('a.pdf', 'YWJj', null);
                Assert.fail('Expected AuraHandledException for null libraryId');
            } catch (AuraHandledException e) {
                Assert.areNotEqual(null, e);
            }
        }
        Test.stopTest();
    }
}

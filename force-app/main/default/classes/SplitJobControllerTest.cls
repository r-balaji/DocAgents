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
    static void shouldStartHeadlessSplit_WhenLibraryProvidedForFileOutsideLibrary() {
        Id sourceContentDocumentId;
        Id jobId;

        System.runAs(getTestUser()) {
            sourceContentDocumentId = createContentDocument('headless_source_outside_library');

            Test.startTest();
            jobId = SplitJobController.startHeadlessSplit(sourceContentDocumentId, null, FAKE_LIBRARY_ID, null);
            Test.stopTest();
        }

        Split_Job__c saved = [
            SELECT Source_ContentDocument_Id__c, Library_Id__c, Is_Headless__c, Chunk_Count__c
            FROM Split_Job__c
            WHERE Id = :jobId
        ];
        Assert.areEqual(String.valueOf(sourceContentDocumentId), saved.Source_ContentDocument_Id__c,
            'Headless job should keep the selected source file');
        Assert.areEqual(String.valueOf(FAKE_LIBRARY_ID), saved.Library_Id__c,
            'Headless job should use the library passed by the LWC/controller');
        Assert.isTrue(saved.Is_Headless__c, 'Controller should create a headless split job');
        Assert.areEqual(1, saved.Chunk_Count__c, 'Small test files use the single-call placeholder chunk');
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
    static void shouldEnqueueChunkClassifications_HappyPath() {
        AIDocSplitClassifierService.testStubResponse =
            '[{"document_type":"BANK_STATEMENT","source_institution":"Chase","named_party":"John","instance_label":"Chase","pages":[1]}]';

        Id jobId;
        Test.startTest();
        System.runAs(getTestUser()) {
            jobId = SplitJobController.startJob(FAKE_CD_ID, FAKE_LIBRARY_ID, null, 14, 2);
            String chunksJson = '['
                + '{"chunkIndex":0,"chunkContentDocumentId":"' + FAKE_CD_ID + '","pageOffset":1},'
                + '{"chunkIndex":1,"chunkContentDocumentId":"' + FAKE_CD_ID + '","pageOffset":4}'
                + ']';
            SplitJobController.enqueueChunkClassifications(jobId, chunksJson);
        }
        Test.stopTest();

        Split_Job__c after = [
            SELECT Status__c, Chunks_Completed__c, Merged_Segments_JSON__c
            FROM Split_Job__c
            WHERE Id = :jobId
        ];
        Assert.areEqual(2, after.Chunks_Completed__c, 'both chunks should be classified by one batch');
        Assert.areEqual('Splitting', after.Status__c, 'last chunk should trigger merge');
        Assert.isTrue(String.isNotBlank(after.Merged_Segments_JSON__c), 'merged split JSON should be produced');
    }

    @IsTest
    static void shouldRethrowAuraHandled_WhenEnqueueInputsInvalid() {
        Test.startTest();
        System.runAs(getTestUser()) {
            try {
                SplitJobController.enqueueChunkClassifications(null, '[]');
                Assert.fail('Expected AuraHandledException for null bulk jobId');
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
    static void shouldSaveSplitBatch_ProgressThenFinalize() {
        Id jobId;
        SplitJobController.SaveBatchResult firstResult;
        SplitJobController.SaveBatchResult finalResult;
        String typeBreakdownJson = '[{"type":"DRIVERS_LICENSE","count":1}]';

        Test.startTest();
        System.runAs(getTestUser()) {
            jobId = SplitJobController.startJob(FAKE_CD_ID, FAKE_LIBRARY_ID, null, 5, 1);
            String tinyB64 = EncodingUtil.base64Encode(Blob.valueOf('%PDF-1.4\n%%EOF\n'));
            String requestsJson = '[{"fileName":"a.pdf","base64Content":"' + tinyB64
                + '","documentType":"DRIVERS_LICENSE","sourceInstitution":null,"namedParty":"John","instanceLabel":null,"pages":[1]}]';

            firstResult = SplitJobController.saveSplitBatch(jobId, requestsJson, 0, typeBreakdownJson, false);
            finalResult = SplitJobController.saveSplitBatch(jobId, '[]', firstResult.documentsSaved, typeBreakdownJson, true);
        }
        Test.stopTest();

        Assert.areEqual(1, firstResult.documentsSaved, 'First browser batch should save one file');
        Assert.areEqual(false, firstResult.isComplete, 'First browser batch should not finalize');
        Assert.areEqual(1, finalResult.documentsSaved, 'Final empty batch should preserve running count');
        Assert.areEqual(true, finalResult.isComplete, 'Final browser batch should finalize');

        Split_Job__c after = [
            SELECT Status__c, Documents_Created__c, Type_Breakdown_JSON__c
            FROM Split_Job__c
            WHERE Id = :jobId
        ];
        Assert.areEqual('Complete', after.Status__c);
        Assert.areEqual(1, after.Documents_Created__c);
        Assert.areEqual(typeBreakdownJson, after.Type_Breakdown_JSON__c);
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
}

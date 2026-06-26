/**
 * Tests for SplitSaveQueueable + the SplitJobService entry points that drive it.
 *
 * The actual ContentVersion DML is stubbed via SplitSaveQueueable.skipContentVersionDml
 * so tests don't need a real ContentWorkspace (which test orgs can't reliably create).
 * Orchestration — chaining, type-tally, status transitions, finalization — is what these
 * tests verify. End-to-end file save is covered by the LWC smoke test in Phase 6/7.
 */
@IsTest
private class SplitSaveQueueableTest {

    private static final Id FAKE_CD_ID = '069000000000001AAA';
    private static final Id FAKE_LIBRARY_ID = '058000000000001AAA';

    @TestSetup
    static void createTestUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            FirstName = 'AIDoc',
            LastName = 'SaveTestUser',
            Email = 'aidoc.savetest@example.com.invalid',
            Username = 'aidoc.savetest+' + System.currentTimeMillis() + '@example.com.invalid',
            Alias = 'aidocs',
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
        return [SELECT Id FROM User WHERE Username LIKE 'aidoc.savetest+%@example.com.invalid' LIMIT 1];
    }

    @IsTest
    static void shouldFinalizeImmediately_WhenStartSavingWithEmptyList() {
        Id jobId;
        Test.startTest();
        System.runAs(getTestUser()) {
            jobId = SplitJobService.startJob(FAKE_CD_ID, FAKE_LIBRARY_ID, 5, 1);
            SplitJobService.startSaving(jobId, new List<SplitSaveRequest>(), 8);
        }
        Test.stopTest();

        Split_Job__c after = [SELECT Status__c, Documents_Created__c, Type_Breakdown_JSON__c
                              FROM Split_Job__c WHERE Id = :jobId];
        Assert.areEqual('Complete', after.Status__c, 'Empty save list should finalize immediately');
        Assert.areEqual(0, after.Documents_Created__c);
        Assert.areEqual('[]', after.Type_Breakdown_JSON__c);
    }

    @IsTest
    static void shouldThrow_WhenStartSavingInputsInvalid() {
        Test.startTest();
        System.runAs(getTestUser()) {
            try {
                SplitJobService.startSaving(null, new List<SplitSaveRequest>(), 8);
                Assert.fail('Expected SplitJobException for null jobId');
            } catch (SplitJobException e) {
                Assert.isTrue(e.getMessage().contains('jobId'));
            }
            try {
                SplitJobService.startSaving('a00000000000000', null, 8);
                Assert.fail('Expected SplitJobException for null files');
            } catch (SplitJobException e) {
                Assert.isTrue(e.getMessage().contains('files'));
            }
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldSaveSingleBatch_WhenFileCountUnderBatchSize() {
        Id jobId;

        Test.startTest();
        System.runAs(getTestUser()) {
            jobId = SplitJobService.startJob(FAKE_CD_ID, FAKE_LIBRARY_ID, 5, 1);

            List<SplitSaveRequest> files = new List<SplitSaveRequest>{
                buildRequest('DriversLicense_John.pdf', 'DRIVERS_LICENSE', null, 'John', 1, 1),
                buildRequest('BankStatement_Chase_John.pdf', 'BANK_STATEMENT', 'Chase', 'John', 2, 4),
                buildRequest('W2_John.pdf', 'W2', null, 'John', 5, 5)
            };
            SplitJobService.startSaving(jobId, files, 8);   // 3 files, batch size 8 -> one batch
        }
        Test.stopTest();

        Split_Job__c after = [SELECT Status__c, Documents_Created__c, Type_Breakdown_JSON__c
                              FROM Split_Job__c WHERE Id = :jobId];
        Assert.areEqual('Complete', after.Status__c, 'Single batch should finalize on completion');
        Assert.areEqual(3, after.Documents_Created__c, 'All 3 files saved');
        Assert.isTrue(after.Type_Breakdown_JSON__c.contains('DRIVERS_LICENSE'), 'Type breakdown captured');
        Assert.isTrue(after.Type_Breakdown_JSON__c.contains('BANK_STATEMENT'));
        Assert.isTrue(after.Type_Breakdown_JSON__c.contains('W2'));
    }

    @IsTest
    static void shouldChainAcrossBatches_WhenFileCountExceedsBatchSize() {
        Id jobId;

        Test.startTest();
        System.runAs(getTestUser()) {
            jobId = SplitJobService.startJob(FAKE_CD_ID, FAKE_LIBRARY_ID, 10, 1);

            List<SplitSaveRequest> files = new List<SplitSaveRequest>();
            for (Integer i = 0; i < 5; i++) {
                files.add(buildRequest('Other_' + i + '.pdf', 'OTHER', null, null, i + 1, i + 1));
            }
            SplitJobService.startSaving(jobId, files, 2);   // 5 files, batch=2 -> 3 batches
        }
        Test.stopTest();

        // Test transactions execute only the first chained Queueable, so the full chain
        // isn't observed here. Verify the first batch landed and the chain was kicked off.
        Split_Job__c after = [SELECT Status__c, Documents_Created__c, Error_Detail__c
                              FROM Split_Job__c WHERE Id = :jobId];
        Assert.isTrue(after.Status__c == 'Saving' || after.Status__c == 'Complete',
            'Job should be Saving (mid-chain) or Complete (somehow ran all in one), got '
            + after.Status__c + '. Error_Detail: ' + after.Error_Detail__c);
        Assert.isTrue(after.Documents_Created__c >= 2,
            'First batch (2 files) at minimum, got ' + after.Documents_Created__c);
    }

    @IsTest
    static void shouldBuildFileName_WithAllPartsPresent() {
        Assert.areEqual('BankStatement_Bank_of_America_John_Smith.pdf',
            SplitSaveRequest.buildFileName('BANK_STATEMENT', 'Bank of America', 'John Smith', 1));
        Assert.areEqual('DriversLicense_Jane_Doe.pdf',
            SplitSaveRequest.buildFileName('DRIVERS_LICENSE', null, 'Jane Doe', 1));
        Assert.areEqual('Other_2.pdf',
            SplitSaveRequest.buildFileName('OTHER', null, null, 2));
        Assert.areEqual('Other_1.pdf',
            SplitSaveRequest.buildFileName('OTHER', null, null, 1),
            'OTHER always carries a numeric suffix, even for the first one');
        Assert.areEqual('Other_3.pdf',
            SplitSaveRequest.buildFileName('OTHER', null, 'Lakeside Auto Group', 3),
            'OTHER ignores party name (AI extraction is noise for unrecognized pages)');
        Assert.areEqual('PersonalTaxReturn1040.pdf',
            SplitSaveRequest.buildFileName('PERSONAL_TAX_RETURN_1040', null, null, 1));
    }

    @IsTest
    static void shouldTallyTypes_AcrossBatch() {
        Map<String, Integer> counts = new Map<String, Integer>();
        List<SplitSaveRequest> batch = new List<SplitSaveRequest>{
            buildRequest('a.pdf', 'BANK_STATEMENT', null, null, 1, 1),
            buildRequest('b.pdf', 'BANK_STATEMENT', null, null, 2, 2),
            buildRequest('c.pdf', 'W2', null, null, 3, 3)
        };

        Test.startTest();
        SplitSaveQueueable.tallyTypes(batch, counts);
        Test.stopTest();

        Assert.areEqual(2, counts.get('BANK_STATEMENT'));
        Assert.areEqual(1, counts.get('W2'));
    }

    @IsTest
    static void shouldBuildSortedTypeBreakdownJson() {
        Map<String, Integer> counts = new Map<String, Integer>{
            'W2' => 1,
            'BANK_STATEMENT' => 2
        };

        Test.startTest();
        String json = SplitSaveQueueable.buildTypeBreakdownJson(counts);
        Test.stopTest();

        Assert.isTrue(json.indexOf('BANK_STATEMENT') < json.indexOf('W2'),
            'BANK_STATEMENT should come before W2 in sorted output');
        Assert.isTrue(json.contains('"count":2'));
    }

    @IsTest
    static void shouldStripExtension_WhenBuildingTitle() {
        Assert.areEqual('foo', SplitSaveQueueable.stripExtension('foo.pdf'));
        Assert.areEqual('foo.bar', SplitSaveQueueable.stripExtension('foo.bar.pdf'));
        Assert.areEqual('noext', SplitSaveQueueable.stripExtension('noext'));
        Assert.areEqual('Document', SplitSaveQueueable.stripExtension(null));
    }

    // --- Helper -------------------------------------------------------------

    private static SplitSaveRequest buildRequest(String fileName, String type, String source, String party, Integer startP, Integer endP) {
        Blob tinyPdfBlob = Blob.valueOf('%PDF-1.4\n%%EOF\n');
        SplitSaveRequest r = new SplitSaveRequest();
        r.fileName = fileName;
        r.base64Content = EncodingUtil.base64Encode(tinyPdfBlob);
        r.documentType = type;
        r.sourceInstitution = source;
        r.namedParty = party;
        r.startPage = startP;
        r.endPage = endP;
        return r;
    }
}

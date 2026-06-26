/**
 * Tests for ClassifyQueueable.
 *
 * Runs as a dedicated Standard User with the AIDocAccess permset so USER_MODE DML
 * inside the Queueable is FLS-enforced the same way it will be in production.
 * The actual prompt invocation is stubbed via ClassifyQueueable.testStubResponse.
 */
@IsTest
private class ClassifyQueueableTest {

    private static final Id FAKE_SOURCE_CD = '069000000000001AAA';
    private static final Id FAKE_LIBRARY = '058000000000001AAA';
    private static final Id FAKE_CHUNK_CD = '069000000000002AAA';

    @TestSetup
    static void createTestUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            FirstName = 'AIDoc',
            LastName = 'TestUser',
            Email = 'aidoc.testuser@example.com.invalid',
            Username = 'aidoc.cqtest+' + System.currentTimeMillis() + '@example.com.invalid',
            Alias = 'aidocq',
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
        return [SELECT Id FROM User WHERE Username LIKE 'aidoc.cqtest+%@example.com.invalid' LIMIT 1];
    }

    @IsTest
    static void shouldThrow_WhenConstructorInputsInvalid() {
        Test.startTest();
        try {
            new ClassifyQueueable(null, 0, FAKE_CHUNK_CD, 1);
            Assert.fail('Expected SplitJobException for null jobId');
        } catch (SplitJobException e) {
            Assert.isTrue(e.getMessage().contains('jobId'));
        }
        try {
            new ClassifyQueueable(FAKE_SOURCE_CD, -1, FAKE_CHUNK_CD, 1);
            Assert.fail('Expected SplitJobException for negative chunkIndex');
        } catch (SplitJobException e) {
            Assert.isTrue(e.getMessage().contains('chunkIndex'));
        }
        try {
            new ClassifyQueueable(FAKE_SOURCE_CD, 0, null, 1);
            Assert.fail('Expected SplitJobException for null chunkContentDocumentId');
        } catch (SplitJobException e) {
            Assert.isTrue(e.getMessage().contains('chunkContentDocumentId'));
        }
        try {
            new ClassifyQueueable(FAKE_SOURCE_CD, 0, FAKE_CHUNK_CD, 0);
            Assert.fail('Expected SplitJobException for non-positive pageOffset');
        } catch (SplitJobException e) {
            Assert.isTrue(e.getMessage().contains('pageOffset'));
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldParseAndShift_WhenPromptReturnsValidJson() {
        ClassifyQueueable.testStubResponse =
            '[{"document_type":"DRIVERS_LICENSE","source_institution":null,"named_party":"John Smith","start_page":1,"end_page":1},'
            + '{"document_type":"BANK_STATEMENT","source_institution":"Chase","named_party":"John Smith","start_page":2,"end_page":3}]';

        Id jobId;
        Test.startTest();
        System.runAs(getTestUser()) {
            jobId = SplitJobService.startJob(FAKE_SOURCE_CD, FAKE_LIBRARY, 10, 2);
            System.enqueueJob(new ClassifyQueueable(jobId, 0, FAKE_CHUNK_CD, 5));
        }
        Test.stopTest();

        Split_Job__c after = [SELECT Raw_Segments_JSON__c, Chunks_Completed__c FROM Split_Job__c WHERE Id = :jobId];
        Assert.isTrue(String.isNotBlank(after.Raw_Segments_JSON__c), 'Accumulator populated');
        Assert.areEqual(1, after.Chunks_Completed__c, 'Counter incremented');

        List<Object> accumulator = (List<Object>) JSON.deserializeUntyped(after.Raw_Segments_JSON__c);
        Assert.areEqual(2, accumulator.size(), 'Two segments in accumulator');

        Map<String, Object> first = (Map<String, Object>) accumulator[0];
        Assert.areEqual('DRIVERS_LICENSE', (String) first.get('documentType'));
        Assert.areEqual('John Smith', (String) first.get('namedParty'));
        Assert.areEqual(5, (Integer) first.get('startPage'), 'chunk-local 1 + offset (5-1) = 5');
        Assert.areEqual(5, (Integer) first.get('endPage'), 'chunk-local 1 + offset (5-1) = 5');

        Map<String, Object> second = (Map<String, Object>) accumulator[1];
        Assert.areEqual('BANK_STATEMENT', (String) second.get('documentType'));
        Assert.areEqual('Chase', (String) second.get('sourceInstitution'));
        Assert.areEqual(6, (Integer) second.get('startPage'), 'chunk-local 2 + offset (5-1) = 6');
        Assert.areEqual(7, (Integer) second.get('endPage'), 'chunk-local 3 + offset (5-1) = 7');
    }

    @IsTest
    static void shouldAccumulateAcrossChunks_WhenMultipleEnqueued() {
        Id jobId;

        Test.startTest();
        System.runAs(getTestUser()) {
            jobId = SplitJobService.startJob(FAKE_SOURCE_CD, FAKE_LIBRARY, 6, 2);

            ClassifyQueueable.testStubResponse =
                '[{"document_type":"DRIVERS_LICENSE","source_institution":null,"named_party":"John","start_page":1,"end_page":1},'
                + '{"document_type":"W2","source_institution":null,"named_party":"John","start_page":2,"end_page":2}]';
            System.enqueueJob(new ClassifyQueueable(jobId, 0, FAKE_CHUNK_CD, 1));
        }
        Test.stopTest();

        Split_Job__c afterFirst = [SELECT Chunks_Completed__c, Status__c FROM Split_Job__c WHERE Id = :jobId];
        Assert.areEqual(1, afterFirst.Chunks_Completed__c, 'First chunk recorded');

        System.runAs(getTestUser()) {
            ClassifyQueueable.testStubResponse =
                '[{"document_type":"BANK_STATEMENT","source_institution":"Chase","named_party":"John","start_page":1,"end_page":2}]';
            new ClassifyQueueable(jobId, 1, FAKE_CHUNK_CD, 4).execute(null);
        }

        Split_Job__c afterBoth = [SELECT Raw_Segments_JSON__c, Chunks_Completed__c, Status__c, Merged_Segments_JSON__c
                                  FROM Split_Job__c WHERE Id = :jobId];
        Assert.areEqual(2, afterBoth.Chunks_Completed__c, 'Both chunks recorded');
        Assert.areEqual('Splitting', afterBoth.Status__c, 'Last chunk triggered merge and advance to Splitting');
        Assert.isTrue(String.isNotBlank(afterBoth.Merged_Segments_JSON__c), 'Merged JSON persisted');
    }

    @IsTest
    static void shouldFailJob_WhenPromptResponseIsInvalidJson() {
        ClassifyQueueable.testStubResponse = '<<not valid json at all>>';
        Id jobId;

        Test.startTest();
        System.runAs(getTestUser()) {
            jobId = SplitJobService.startJob(FAKE_SOURCE_CD, FAKE_LIBRARY, 5, 1);
            new ClassifyQueueable(jobId, 0, FAKE_CHUNK_CD, 1).execute(null);
        }
        Test.stopTest();

        Split_Job__c after = [SELECT Status__c, Error_Detail__c FROM Split_Job__c WHERE Id = :jobId];
        Assert.areEqual('Error', after.Status__c, 'Bad JSON should mark job as Error');
        Assert.isTrue(after.Error_Detail__c.contains('Classify chunk 0'), 'Stage label captured');
    }

    @IsTest
    static void shouldStripMarkdownFences_WhenModelWrapsResponse() {
        ClassifyQueueable.testStubResponse =
            '```json\n[{"document_type":"PASSPORT","source_institution":null,"named_party":"Jane","start_page":1,"end_page":1}]\n```';

        Id jobId;
        Test.startTest();
        System.runAs(getTestUser()) {
            jobId = SplitJobService.startJob(FAKE_SOURCE_CD, FAKE_LIBRARY, 5, 1);
            new ClassifyQueueable(jobId, 0, FAKE_CHUNK_CD, 1).execute(null);
        }
        Test.stopTest();

        Split_Job__c after = [SELECT Raw_Segments_JSON__c, Status__c FROM Split_Job__c WHERE Id = :jobId];
        Assert.areNotEqual('Error', after.Status__c, 'Markdown fences should be stripped, not error');
        Assert.isTrue(String.isNotBlank(after.Raw_Segments_JSON__c), 'Segments parsed and stored');
    }

    @IsTest
    static void shouldHandleEmptyResponse_WhenPromptReturnsNothing() {
        ClassifyQueueable.testStubResponse = '';
        Id jobId;

        Test.startTest();
        System.runAs(getTestUser()) {
            jobId = SplitJobService.startJob(FAKE_SOURCE_CD, FAKE_LIBRARY, 5, 1);
            new ClassifyQueueable(jobId, 0, FAKE_CHUNK_CD, 1).execute(null);
        }
        Test.stopTest();

        Split_Job__c after = [SELECT Status__c, Chunks_Completed__c FROM Split_Job__c WHERE Id = :jobId];
        Assert.areNotEqual('Error', after.Status__c, 'Empty response should not error -- chunk just contributes nothing');
        Assert.areEqual(1, after.Chunks_Completed__c, 'Counter still increments');
    }
}

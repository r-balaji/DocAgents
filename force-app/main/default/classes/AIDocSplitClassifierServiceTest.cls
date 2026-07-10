/**
 * Tests for AIDocSplitClassifierService.
 */
@IsTest
private class AIDocSplitClassifierServiceTest {
    @TestSetup
    static void createTestUser() {
        Profile profile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User user = new User(
            FirstName = 'AIDoc',
            LastName = 'ClassifierUser',
            Email = 'aidoc.classifier@example.com.invalid',
            Username = 'aidoc.classifier+' + System.currentTimeMillis() + '@example.com.invalid',
            Alias = 'aidocs',
            TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId = profile.Id
        );
        insert user;

        PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'AIDocAccess' LIMIT 1];
        insert new PermissionSetAssignment(AssigneeId = user.Id, PermissionSetId = ps.Id);
    }

    @IsTest
    static void shouldParseAndShiftWhenPromptReturnsValidJson() {
        AIDocSplitClassifierService.testStubResponse =
            '[{"document_type":"DRIVERS_LICENSE","source_institution":null,"named_party":"John Smith","instance_label":"John CA DL","pages":[1,3]},'
            + '{"document_type":"BANK_STATEMENT","source_institution":"Chase","named_party":"John Smith","instance_label":"Chase 2026-04","pages":[2]}]';

        Id jobId;
        Test.startTest();
        System.runAs(getTestUser()) {
            jobId = SplitJobService.startJob(fakeContentDocumentId(1), fakeLibraryId(), 10, 2);
            AIDocSplitClassifierService.classifyChunk(jobId, 0, fakeContentDocumentId(2), 5);
        }
        Test.stopTest();

        Split_Job__c after = [
            SELECT Raw_Segments_JSON__c, LLM_Response_Audit_JSON__c, Chunks_Completed__c
            FROM Split_Job__c
            WHERE Id = :jobId
        ];
        Assert.isTrue(String.isNotBlank(after.Raw_Segments_JSON__c), 'Accumulator populated');
        Assert.isTrue(after.LLM_Response_Audit_JSON__c.contains('"chunkIndex":0'),
            'LLM response audit should include chunk metadata');
        Assert.isTrue(after.LLM_Response_Audit_JSON__c.contains('DRIVERS_LICENSE'),
            'LLM response audit should include the pre-parse model response');
        Assert.areEqual(1, after.Chunks_Completed__c, 'Counter incremented');

        List<Object> accumulator = (List<Object>) JSON.deserializeUntyped(after.Raw_Segments_JSON__c);
        Assert.areEqual(2, accumulator.size(), 'Two segments in accumulator');

        Map<String, Object> first = (Map<String, Object>) accumulator[0];
        Assert.areEqual('DRIVERS_LICENSE', (String) first.get('documentType'));
        Assert.areEqual('John Smith', (String) first.get('namedParty'));
        Assert.areEqual('John CA DL', (String) first.get('instanceLabel'));
        List<Object> firstPages = (List<Object>) first.get('pages');
        Assert.areEqual(2, firstPages.size(), 'License has two pages [1, 3]');
        Assert.areEqual(5, (Integer) firstPages[0], 'chunk-local 1 + shift(4) = 5');
        Assert.areEqual(7, (Integer) firstPages[1], 'chunk-local 3 + shift(4) = 7');

        Map<String, Object> second = (Map<String, Object>) accumulator[1];
        Assert.areEqual('BANK_STATEMENT', (String) second.get('documentType'));
        Assert.areEqual('Chase', (String) second.get('sourceInstitution'));
        List<Object> secondPages = (List<Object>) second.get('pages');
        Assert.areEqual(1, secondPages.size());
        Assert.areEqual(6, (Integer) secondPages[0], 'chunk-local 2 + shift(4) = 6');
    }

    @IsTest
    static void shouldAccumulateAcrossChunksWhenBatchCallsServiceTwice() {
        Id jobId;

        Test.startTest();
        System.runAs(getTestUser()) {
            jobId = SplitJobService.startJob(fakeContentDocumentId(1), fakeLibraryId(), 6, 2);

            AIDocSplitClassifierService.testStubResponse =
                '[{"document_type":"DRIVERS_LICENSE","source_institution":null,"named_party":"John","instance_label":null,"pages":[1]},'
                + '{"document_type":"W2","source_institution":null,"named_party":"John","instance_label":null,"pages":[2]}]';
            AIDocSplitClassifierService.classifyChunk(jobId, 0, fakeContentDocumentId(2), 1);
        }
        Test.stopTest();

        Split_Job__c afterFirst = [SELECT Chunks_Completed__c, Status__c FROM Split_Job__c WHERE Id = :jobId];
        Assert.areEqual(1, afterFirst.Chunks_Completed__c, 'First chunk recorded');

        System.runAs(getTestUser()) {
            AIDocSplitClassifierService.testStubResponse =
                '[{"document_type":"BANK_STATEMENT","source_institution":"Chase","named_party":"John","instance_label":"Chase","pages":[1,2]}]';
            AIDocSplitClassifierService.classifyChunk(jobId, 1, fakeContentDocumentId(2), 4);
        }

        Split_Job__c afterBoth = [
            SELECT Raw_Segments_JSON__c, Chunks_Completed__c, Status__c, Merged_Segments_JSON__c
            FROM Split_Job__c
            WHERE Id = :jobId
        ];
        Assert.areEqual(2, afterBoth.Chunks_Completed__c, 'Both chunks recorded');
        Assert.areEqual('Splitting', afterBoth.Status__c, 'Last chunk triggered merge and advance to Splitting');
        Assert.isTrue(String.isNotBlank(afterBoth.Merged_Segments_JSON__c), 'Merged JSON persisted');
    }

    @IsTest
    static void shouldTreatInvalidPromptResponseAsUnclassified() {
        AIDocSplitClassifierService.testStubResponse = 'I cannot confidently classify this chunk.';
        Id jobId;

        Test.startTest();
        System.runAs(getTestUser()) {
            jobId = SplitJobService.startJob(fakeContentDocumentId(1), fakeLibraryId(), 5, 1);
            AIDocSplitClassifierService.classifyChunk(jobId, 0, fakeContentDocumentId(2), 1);
        }
        Test.stopTest();

        Split_Job__c after = [
            SELECT Status__c, Chunks_Completed__c, Merged_Segments_JSON__c, LLM_Response_Audit_JSON__c
            FROM Split_Job__c
            WHERE Id = :jobId
        ];
        Assert.areEqual('Splitting', after.Status__c, 'Invalid prompt output should not fail the job');
        Assert.areEqual(1, after.Chunks_Completed__c, 'Counter still increments');
        Assert.isTrue(after.Merged_Segments_JSON__c.contains('"documentType":"OTHER"'),
            'Unclassified pages should fall back to OTHER');
        Assert.isTrue(after.LLM_Response_Audit_JSON__c.contains('I cannot confidently classify this chunk.'),
            'Raw non-JSON LLM response should be captured for diagnosis');
    }

    @IsTest
    static void shouldStripMarkdownFencesWhenModelWrapsResponse() {
        AIDocSplitClassifierService.testStubResponse =
            '```json\n[{"document_type":"PASSPORT","source_institution":null,"named_party":"Jane","instance_label":null,"pages":[1]}]\n```';

        Id jobId;
        Test.startTest();
        System.runAs(getTestUser()) {
            jobId = SplitJobService.startJob(fakeContentDocumentId(1), fakeLibraryId(), 5, 1);
            AIDocSplitClassifierService.classifyChunk(jobId, 0, fakeContentDocumentId(2), 1);
        }
        Test.stopTest();

        Split_Job__c after = [SELECT Raw_Segments_JSON__c, Status__c FROM Split_Job__c WHERE Id = :jobId];
        Assert.areNotEqual('Error', after.Status__c, 'Markdown fences should be stripped, not error');
        Assert.isTrue(String.isNotBlank(after.Raw_Segments_JSON__c), 'Segments parsed and stored');
    }

    @IsTest
    static void shouldHandleEmptyResponseWhenPromptReturnsNothing() {
        AIDocSplitClassifierService.testStubResponse = '';
        Id jobId;

        Test.startTest();
        System.runAs(getTestUser()) {
            jobId = SplitJobService.startJob(fakeContentDocumentId(1), fakeLibraryId(), 5, 1);
            AIDocSplitClassifierService.classifyChunk(jobId, 0, fakeContentDocumentId(2), 1);
        }
        Test.stopTest();

        Split_Job__c after = [SELECT Status__c, Chunks_Completed__c FROM Split_Job__c WHERE Id = :jobId];
        Assert.areNotEqual('Error', after.Status__c, 'Empty response should not error');
        Assert.areEqual(1, after.Chunks_Completed__c, 'Counter still increments');
    }

    @IsTest
    static void shouldExtractJsonArrayWhenModelAddsProse() {
        String wrapped = 'Here is the JSON:\n'
            + '[{"document_type":"PASSPORT","source_institution":null,"named_party":"Jane","instance_label":null,"pages":[1]}]'
            + '\nThanks.';

        Test.startTest();
        String extracted = AIDocSplitClassifierService.extractJsonArray(wrapped);
        List<DocSegment> segments = AIDocSplitClassifierService.parseAndShift(wrapped, 3);
        Test.stopTest();

        Assert.isTrue(extracted.startsWith('['), 'Only the JSON array should be extracted');
        Assert.areEqual(1, segments.size(), 'Embedded JSON array should still parse');
        Assert.areEqual(3, segments[0].pages[0], 'Page offset should still apply');
    }

    private static User getTestUser() {
        return [SELECT Id FROM User WHERE Username LIKE 'aidoc.classifier+%@example.com.invalid' LIMIT 1];
    }

    private static Id fakeContentDocumentId(Integer seed) {
        String suffix = String.valueOf(UserInfo.getOrganizationId()).right(11) + String.valueOf(seed == null ? 1 : seed);
        return (Id) (ContentDocument.SObjectType
            .getDescribe(SObjectDescribeOptions.DEFERRED)
            .getKeyPrefix() + suffix);
    }

    private static Id fakeLibraryId() {
        return (Id) (ContentWorkspace.SObjectType
            .getDescribe(SObjectDescribeOptions.DEFERRED)
            .getKeyPrefix() + String.valueOf(UserInfo.getOrganizationId()).right(12));
    }
}

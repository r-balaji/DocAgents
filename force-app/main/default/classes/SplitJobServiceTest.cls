/**
 * Tests for SplitJobService.
 *
 * All tests run as a dedicated Standard User with the AIDocAccess permission set,
 * so the FLS-enforcing USER_MODE DML inside SplitJobService is exercised the same
 * way it will run in production (not as a system admin with implicit FLS bypass).
 */
@IsTest
private class SplitJobServiceTest {

    private static final Id FAKE_CD_ID = '069000000000001AAA';
    private static final Id FAKE_LIBRARY_ID = '058000000000001AAA';

    @TestSetup
    static void createTestUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            FirstName = 'AIDoc',
            LastName = 'TestUser',
            Email = 'aidoc.testuser@example.com.invalid',
            Username = 'aidoc.testuser+' + System.currentTimeMillis() + '@example.com.invalid',
            Alias = 'aidoct',
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
        return [SELECT Id FROM User WHERE Username LIKE 'aidoc.testuser+%@example.com.invalid' LIMIT 1];
    }

    @IsTest
    static void shouldCreateJob_WhenInputsValid() {
        User tu = getTestUser();
        Id jobId;

        Test.startTest();
        System.runAs(tu) {
            jobId = SplitJobService.startJob(FAKE_CD_ID, FAKE_LIBRARY_ID, 14, 2);
        }
        Test.stopTest();

        Split_Job__c saved = [SELECT Source_ContentDocument_Id__c, Library_Id__c, Status__c,
                                     Total_Pages__c, Chunk_Count__c, Chunks_Completed__c, Started_By__c
                              FROM Split_Job__c WHERE Id = :jobId];
        Assert.areEqual((String) FAKE_CD_ID, saved.Source_ContentDocument_Id__c);
        Assert.areEqual((String) FAKE_LIBRARY_ID, saved.Library_Id__c);
        Assert.areEqual('Queued', saved.Status__c);
        Assert.areEqual(14, saved.Total_Pages__c);
        Assert.areEqual(2, saved.Chunk_Count__c);
        Assert.areEqual(0, saved.Chunks_Completed__c);
        Assert.areEqual(tu.Id, saved.Started_By__c);
    }

    @IsTest
    static void shouldThrow_WhenStartJobInputsInvalid() {
        Test.startTest();
        System.runAs(getTestUser()) {
            assertStartJobThrows(null, FAKE_LIBRARY_ID, 1, 1, 'sourceContentDocumentId');
            assertStartJobThrows(FAKE_CD_ID, null, 1, 1, 'libraryId');
            assertStartJobThrows(FAKE_CD_ID, FAKE_LIBRARY_ID, 0, 1, 'totalPages');
            assertStartJobThrows(FAKE_CD_ID, FAKE_LIBRARY_ID, 1, 0, 'chunkCount');
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldIncrementCounter_WhenRecordChunkCompletion() {
        User tu = getTestUser();
        Id jobId;

        Test.startTest();
        System.runAs(tu) {
            jobId = SplitJobService.startJob(FAKE_CD_ID, FAKE_LIBRARY_ID, 14, 3);
            SplitJobService.recordChunkCompletion(jobId);
        }
        Test.stopTest();

        Split_Job__c after = [SELECT Chunks_Completed__c, Status__c FROM Split_Job__c WHERE Id = :jobId];
        Assert.areEqual(1, after.Chunks_Completed__c, 'Counter should increment from 0 to 1');
        Assert.areNotEqual('Merging', after.Status__c, 'First-of-three should not trigger merge');
    }

    @IsTest
    static void shouldTriggerMergeAndPublishMergedJson_WhenLastChunkCompletes() {
        User tu = getTestUser();
        Id jobId;

        Test.startTest();
        System.runAs(tu) {
            jobId = SplitJobService.startJob(FAKE_CD_ID, FAKE_LIBRARY_ID, 5, 2);

            // Seed the raw segments accumulator. Three raw segments covering pages 1-5.
            List<Object> rawAccumulator = new List<Object>{
                new Map<String, Object>{
                    'documentType' => 'DRIVERS_LICENSE',
                    'sourceInstitution' => null,
                    'namedParty' => 'John Smith',
                    'instanceLabel' => null,
                    'pages' => new List<Integer>{1}
                },
                new Map<String, Object>{
                    'documentType' => 'PASSPORT',
                    'sourceInstitution' => null,
                    'namedParty' => 'John Smith',
                    'instanceLabel' => null,
                    'pages' => new List<Integer>{2, 3}
                },
                new Map<String, Object>{
                    'documentType' => 'BANK_STATEMENT',
                    'sourceInstitution' => 'Chase',
                    'namedParty' => 'John Smith',
                    'instanceLabel' => 'Chase 2026-04',
                    'pages' => new List<Integer>{4, 5}
                }
            };
            Split_Job__c seed = new Split_Job__c(
                Id = jobId,
                Raw_Segments_JSON__c = JSON.serialize(rawAccumulator),
                Chunks_Completed__c = 1
            );
            update seed;

            SplitJobService.recordChunkCompletion(jobId);   // 2 of 2 -> merge runs
        }
        Test.stopTest();

        Split_Job__c after = [SELECT Status__c, Chunks_Completed__c, Merged_Segments_JSON__c
                              FROM Split_Job__c WHERE Id = :jobId];
        Assert.areEqual(2, after.Chunks_Completed__c, 'Counter should be at chunk count');
        Assert.areEqual('Splitting', after.Status__c, 'Should advance through Merging to Splitting');
        Assert.isTrue(String.isNotBlank(after.Merged_Segments_JSON__c), 'Merged JSON should be persisted');

        List<Object> mergedSegments = (List<Object>) JSON.deserializeUntyped(after.Merged_Segments_JSON__c);
        Assert.areEqual(3, mergedSegments.size(),
            '3 raw segments cover all 5 pages, expect 3 final segments with no fallback gap');
    }

    @IsTest
    static void shouldFinalizeJob_WhenLwcReportsDone() {
        Id jobId;

        Test.startTest();
        System.runAs(getTestUser()) {
            jobId = SplitJobService.startJob(FAKE_CD_ID, FAKE_LIBRARY_ID, 5, 1);
            SplitJobService.finalizeJob(jobId, 4, '[{"type":"DRIVERS_LICENSE","count":1}]');
        }
        Test.stopTest();

        Split_Job__c after = [SELECT Status__c, Documents_Created__c, Type_Breakdown_JSON__c
                              FROM Split_Job__c WHERE Id = :jobId];
        Assert.areEqual('Complete', after.Status__c);
        Assert.areEqual(4, after.Documents_Created__c);
        Assert.areEqual('[{"type":"DRIVERS_LICENSE","count":1}]', after.Type_Breakdown_JSON__c);
    }

    @IsTest
    static void shouldFailJob_WhenStageErrors() {
        Id jobId;

        Test.startTest();
        System.runAs(getTestUser()) {
            jobId = SplitJobService.startJob(FAKE_CD_ID, FAKE_LIBRARY_ID, 5, 1);
            SplitJobService.failJob(jobId, 'Detecting', 'Prompt invocation timed out.');
        }
        Test.stopTest();

        Split_Job__c after = [SELECT Status__c, Error_Detail__c FROM Split_Job__c WHERE Id = :jobId];
        Assert.areEqual('Error', after.Status__c);
        Assert.isTrue(after.Error_Detail__c.contains('Detecting'), 'Stage label captured');
        Assert.isTrue(after.Error_Detail__c.contains('Prompt invocation timed out'), 'Error message captured');
    }

    @IsTest
    static void shouldDeserializeRawSegments_RoundTrip() {
        // Pure logic, no DML, no runAs needed.
        List<Object> raw = new List<Object>{
            new Map<String, Object>{
                'documentType' => 'W2',
                'sourceInstitution' => null,
                'namedParty' => 'Daniela Morales',
                'instanceLabel' => null,
                'pages' => new List<Integer>{2, 4}
            }
        };
        String json = JSON.serialize(raw);

        Test.startTest();
        List<DocSegment> segments = SplitJobService.deserializeRawSegments(json);
        Test.stopTest();

        Assert.areEqual(1, segments.size());
        Assert.areEqual('W2', segments[0].documentType);
        Assert.areEqual('Daniela Morales', segments[0].namedParty);
        Assert.areEqual(2, segments[0].pages.size(), 'Page list round-trips with 2 elements');
        Assert.areEqual(2, segments[0].pages[0]);
        Assert.areEqual(4, segments[0].pages[1]);
    }

    @IsTest
    static void shouldReturnEmptyList_WhenRawSegmentsBlank() {
        Test.startTest();
        List<DocSegment> nullCase = SplitJobService.deserializeRawSegments(null);
        List<DocSegment> emptyCase = SplitJobService.deserializeRawSegments('');
        Test.stopTest();

        Assert.areEqual(0, nullCase.size());
        Assert.areEqual(0, emptyCase.size());
    }

    @IsTest
    static void shouldNoop_WhenRecordChunkCompletionGivenNullJobId() {
        Test.startTest();
        SplitJobService.recordChunkCompletion(null);   // must not throw
        Test.stopTest();
    }

    @IsTest
    static void shouldNoop_WhenFailJobGivenNullJobId() {
        Test.startTest();
        SplitJobService.failJob(null, 'AnyStage', 'AnyError');   // must not throw
        Test.stopTest();
    }

    @IsTest
    static void shouldReplaceSource_WhenSingleFullCoverageNonOtherSegment() {
        Split_Job__c job = buildJobForReplacementTest(1, 5,
            '[{"documentType":"BANK_STATEMENT","pages":[1,2,3,4,5]}]');
        Assert.isTrue(SplitJobService.shouldReplaceSource(job),
            'Single non-OTHER segment covering all pages should replace the source');
    }

    @IsTest
    static void shouldNotReplaceSource_WhenSingleSegmentIsOther() {
        Split_Job__c job = buildJobForReplacementTest(1, 5,
            '[{"documentType":"OTHER","pages":[1,2,3,4,5]}]');
        Assert.isFalse(SplitJobService.shouldReplaceSource(job),
            'OTHER means the AI was uncertain — keep the source');
    }

    @IsTest
    static void shouldNotReplaceSource_WhenMultipleSegments() {
        Split_Job__c job = buildJobForReplacementTest(2, 5,
            '[{"documentType":"BANK_STATEMENT","pages":[1,2,3]},{"documentType":"W2","pages":[4,5]}]');
        Assert.isFalse(SplitJobService.shouldReplaceSource(job),
            'Multiple documents mean the source is the only consolidated copy — keep it');
    }

    @IsTest
    static void shouldNotReplaceSource_WhenSegmentDoesNotCoverAllPages() {
        Split_Job__c job = buildJobForReplacementTest(1, 5,
            '[{"documentType":"BANK_STATEMENT","pages":[1,2,3]}]');
        Assert.isFalse(SplitJobService.shouldReplaceSource(job),
            'Partial coverage means the source has pages the output does not — keep it');
    }

    @IsTest
    static void shouldNotReplaceSource_WhenMergedJsonBlank() {
        Split_Job__c job = buildJobForReplacementTest(1, 5, null);
        Assert.isFalse(SplitJobService.shouldReplaceSource(job),
            'No merged segments to evaluate — keep the source');
    }

    // --- Helper -------------------------------------------------------------

    private static Split_Job__c buildJobForReplacementTest(Integer docsCreated, Integer totalPages, String mergedJson) {
        return new Split_Job__c(
            Source_ContentDocument_Id__c = (String) FAKE_CD_ID,
            Total_Pages__c = totalPages,
            Documents_Created__c = docsCreated,
            Merged_Segments_JSON__c = mergedJson
        );
    }

    private static void assertStartJobThrows(Id sourceCdId, Id libraryId, Integer total, Integer chunks, String expectedFieldInMessage) {
        try {
            SplitJobService.startJob(sourceCdId, libraryId, total, chunks);
            Assert.fail('Expected SplitJobException for invalid input: ' + expectedFieldInMessage);
        } catch (SplitJobException e) {
            Assert.isTrue(e.getMessage().toLowerCase().contains(expectedFieldInMessage.toLowerCase()),
                'Exception message should reference ' + expectedFieldInMessage + ', got: ' + e.getMessage());
        }
    }
}

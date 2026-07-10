/**
 * Tests for PdfServiceChunkClassifyBatch.
 */
@IsTest
private class PdfServiceChunkClassifyBatchTest {
    @TestSetup
    static void createUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            FirstName = 'AIDoc',
            LastName = 'ChunkBatch',
            Email = 'aidoc.chunkbatch@example.com.invalid',
            Username = 'aidoc.chunkbatch+' + System.currentTimeMillis() + '@example.com.invalid',
            Alias = 'aidocb',
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

    @IsTest
    static void shouldThrowWhenConstructedWithoutChunks() {
        Test.startTest();
        try {
            new PdfServiceChunkClassifyBatch(fakeSplitJobId(), new List<PdfServiceChunkClassifyBatch.ChunkWork>());
            Assert.fail('Expected SplitJobException for missing chunks');
        } catch (SplitJobException e) {
            Assert.isTrue(e.getMessage().contains('chunks'), 'message should identify missing chunks');
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldClassifyChunksAcrossBatch() {
        AIDocSplitClassifierService.testStubResponse =
            '[{"document_type":"BANK_STATEMENT","source_institution":"Chase","named_party":"John Smith","instance_label":"Chase","pages":[1]}]';
        Id sourceContentDocumentId = createContentDocument('source_bundle');
        Id firstChunkId = createContentDocument('bundle_chunk_0');
        Id secondChunkId = createContentDocument('bundle_chunk_1');
        Id jobId;

        System.runAs(getUser()) {
            jobId = SplitJobService.startJob(sourceContentDocumentId, fakeLibraryId(), 6, 2);

            Test.startTest();
            Database.executeBatch(
                new PdfServiceChunkClassifyBatch(
                    jobId,
                    new List<PdfServiceChunkClassifyBatch.ChunkWork>{
                        new PdfServiceChunkClassifyBatch.ChunkWork(0, firstChunkId, 1),
                        new PdfServiceChunkClassifyBatch.ChunkWork(1, secondChunkId, 4)
                    }
                ),
                2
            );
            Test.stopTest();
        }

        Split_Job__c after = [
            SELECT Status__c, Chunks_Completed__c, Raw_Segments_JSON__c, Merged_Segments_JSON__c
            FROM Split_Job__c
            WHERE Id = :jobId
        ];
        Assert.areEqual(2, after.Chunks_Completed__c, 'both chunks should be classified');
        Assert.areEqual('Splitting', after.Status__c, 'last chunk should trigger merge');
        Assert.isTrue(String.isNotBlank(after.Raw_Segments_JSON__c), 'raw chunk findings should be accumulated');
        Assert.isTrue(String.isNotBlank(after.Merged_Segments_JSON__c), 'merged split JSON should be produced');
    }

    @IsTest
    static void shouldConvertServiceChunkRecordsToWorkItems() {
        PdfServiceClient.ChunkRecord first = new PdfServiceClient.ChunkRecord();
        first.chunkIndex = 3;
        first.contentDocumentId = String.valueOf(createContentDocument('service_chunk'));
        first.pageOffset = 9;
        PdfServiceClient.ChunkRecord missingDoc = new PdfServiceClient.ChunkRecord();
        missingDoc.chunkIndex = 4;

        Test.startTest();
        List<PdfServiceChunkClassifyBatch.ChunkWork> work =
            PdfServiceChunkClassifyBatch.fromChunkRecords(new List<PdfServiceClient.ChunkRecord>{
                first,
                missingDoc
            });
        Test.stopTest();

        Assert.areEqual(1, work.size(), 'records without ContentDocument ids should be skipped');
        Assert.areEqual(3, work[0].chunkIndex, 'chunk index should be preserved');
        Assert.areEqual(9, work[0].pageOffset, 'page offset should be preserved');
    }

    private static User getUser() {
        return [SELECT Id FROM User WHERE Username LIKE 'aidoc.chunkbatch+%@example.com.invalid' LIMIT 1];
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

    private static Id fakeSplitJobId() {
        return (Id) (Split_Job__c.SObjectType
            .getDescribe(SObjectDescribeOptions.DEFERRED)
            .getKeyPrefix() + String.valueOf(UserInfo.getOrganizationId()).right(12));
    }
}

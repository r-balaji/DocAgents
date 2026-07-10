/**
 * Tests LLM-assisted category placement for document intake split outputs.
 */
@IsTest
private class AIDocIntakeCategoryMappingServiceTest {
    @IsTest
    static void shouldPlaceOutputInMappedCategoryWhenPromptReturnsExistingLeaf() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        List<clcommon__Document_Category__c> leaves = AIDocTestFactory.createCategories(app.Id, 1, true);
        leaves[0].clcommon__Category_Name__c = 'Articles of Incorporation';
        update leaves[0];
        Id sourceContentDocumentId = createContentDocument('portal_bundle');
        Id outputContentDocumentId = createContentDocument('ArticlesOfIncorporation_Vance_Electric_Inc');
        Id splitJobId = createSplitJob(sourceContentDocumentId);
        linkFileToSplitJob(splitJobId, outputContentDocumentId);
        Id intakeJobId = createIntakeJob(app.Id);
        createIntakeFile(intakeJobId, sourceContentDocumentId, splitJobId);
        AIDocIntakeCategoryMappingService.testStubMappingResponse = JSON.serialize(new Map<String, Object>{
            'mappings' => new List<Object>{
                new Map<String, Object>{
                    'contentDocumentId' => String.valueOf(outputContentDocumentId),
                    'documentCategoryId' => String.valueOf(leaves[0].Id),
                    'confidence' => 0.93,
                    'reason' => 'File name matches articles category.'
                }
            }
        });

        Test.startTest();
        System.enqueueJob(new AIDocIntakeCategoryMappingQueueable(splitJobId));
        Test.stopTest();

        Document_Intake_Job__c job = [
            SELECT Status__c, Completed_Files__c
            FROM Document_Intake_Job__c
            WHERE Id = :intakeJobId
        ];
        Document_Intake_File__c fileItem = [
            SELECT Status__c, Document_Category__c, Mapping_Confidence__c, Split_Result_JSON__c
            FROM Document_Intake_File__c
            WHERE Intake_Job__c = :intakeJobId
            LIMIT 1
        ];
        Assert.areEqual(AIDocIntakeService.JOB_STATUS_PROCESSING, job.Status__c,
            'job should keep processing until AI review completes');
        Assert.areEqual(0, job.Completed_Files__c, 'review work is not complete yet');
        Assert.areEqual(AIDocIntakeService.FILE_STATUS_REVIEWING, fileItem.Status__c,
            'source intake file should wait for AI review');
        Assert.areEqual(leaves[0].Id, fileItem.Document_Category__c,
            'single-output intake should record the mapped category');
        Assert.areEqual(93, fileItem.Mapping_Confidence__c,
            'confidence should be stored as a percent');
        Assert.isTrue(fileItem.Split_Result_JSON__c.contains(String.valueOf(outputContentDocumentId)),
            'mapping audit JSON should include the split output file');
        String outputContentDocumentIdText = String.valueOf(outputContentDocumentId);
        Assert.areEqual(1, [
            SELECT COUNT()
            FROM clcommon__Category_Attachment_Association__c
            WHERE clcommon__Document_Category__c = :leaves[0].Id
            AND clcommon__Content_Document_Id__c = :outputContentDocumentIdText
            AND clcommon__Status__c = 'Submitted'
        ], 'split output file should be attached to the mapped category');
    }

    @IsTest
    static void shouldPlaceInvalidPromptMappingInFallbackCategory() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        Id sourceContentDocumentId = createContentDocument('portal_bundle');
        Id outputContentDocumentId = createContentDocument('Other');
        Id splitJobId = createSplitJob(sourceContentDocumentId);
        linkFileToSplitJob(splitJobId, outputContentDocumentId);
        Id intakeJobId = createIntakeJob(app.Id);
        createIntakeFile(intakeJobId, sourceContentDocumentId, splitJobId);
        AIDocIntakeCategoryMappingService.testStubMappingResponse = JSON.serialize(new Map<String, Object>{
            'mappings' => new List<Object>{
                new Map<String, Object>{
                    'contentDocumentId' => String.valueOf(outputContentDocumentId),
                    'documentCategoryId' => null,
                    'confidence' => 0,
                    'reason' => 'No category fit.'
                }
            }
        });

        Test.startTest();
        AIDocIntakeCategoryMappingService.mapSplitOutputs(splitJobId);
        Test.stopTest();

        Document_Intake_File__c fileItem = [
            SELECT Status__c, Document_Category__c, Mapping_Confidence__c
            FROM Document_Intake_File__c
            WHERE Intake_Job__c = :intakeJobId
            LIMIT 1
        ];
        clcommon__Document_Category__c fallback = [
            SELECT Id, clcommon__Category_Name__c, clcommon__Parent_Document_Category__r.clcommon__Category_Name__c
            FROM clcommon__Document_Category__c
            WHERE Id = :fileItem.Document_Category__c
        ];
        Assert.areEqual(AIDocIntakeService.FILE_STATUS_REVIEWING, fileItem.Status__c,
            'fallback output placement should still feed the review step');
        Assert.areEqual('Others', fallback.clcommon__Category_Name__c,
            'invalid mappings should fall back to Others');
        Assert.areEqual('Uncategorized', fallback.clcommon__Parent_Document_Category__r.clcommon__Category_Name__c,
            'Others should live below Uncategorized');
        Assert.areEqual(0, fileItem.Mapping_Confidence__c,
            'fallback confidence should be zero');
    }

    @IsTest
    static void shouldRejectApplicationCategoryAsFallbackForPartyOwnedFiles() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        Id applicationLeafId = createApplicationSubmissionLeaf(app.Id);
        Id sourceContentDocumentId = createContentDocument('portal_bundle');
        Id outputContentDocumentId = createContentDocument('PayStub_Jimmy_Neutron');
        Id splitJobId = createSplitJob(sourceContentDocumentId);
        linkFileToSplitJob(splitJobId, outputContentDocumentId);
        Id intakeJobId = createIntakeJob(app.Id);
        createIntakeFile(intakeJobId, sourceContentDocumentId, splitJobId);
        AIDocIntakeCategoryMappingService.testStubMappingResponse = JSON.serialize(new Map<String, Object>{
            'mappings' => new List<Object>{
                new Map<String, Object>{
                    'contentDocumentId' => String.valueOf(outputContentDocumentId),
                    'targetCategoryIds' => new List<Object>{ String.valueOf(applicationLeafId) },
                    'routingClass' => 'PARTY_OWNED',
                    'fileType' => 'PAY_STUB',
                    'matchedOfficialParty' => 'Jimmy Neutron',
                    'matchedParties' => new List<Object>(),
                    'confidence' => 'LOW',
                    'reason' => 'Pay stub has no leaf; routed to fallback Application Submission Documents.'
                }
            }
        });

        Test.startTest();
        AIDocIntakeCategoryMappingService.mapSplitOutputs(splitJobId);
        Test.stopTest();

        Document_Intake_File__c fileItem = [
            SELECT Document_Category__c, Mapping_Confidence__c
            FROM Document_Intake_File__c
            WHERE Intake_Job__c = :intakeJobId
            LIMIT 1
        ];
        clcommon__Document_Category__c fallback = [
            SELECT Id, clcommon__Category_Name__c, clcommon__Parent_Document_Category__r.clcommon__Category_Name__c
            FROM clcommon__Document_Category__c
            WHERE Id = :fileItem.Document_Category__c
        ];
        String outputContentDocumentIdText = String.valueOf(outputContentDocumentId);

        Assert.areEqual('Others', fallback.clcommon__Category_Name__c,
            'party-owned files must not use Application Submission Documents as fallback');
        Assert.areEqual('Uncategorized', fallback.clcommon__Parent_Document_Category__r.clcommon__Category_Name__c,
            'fallback should be the configured Uncategorized > Others leaf');
        Assert.areEqual(0, fileItem.Mapping_Confidence__c,
            'rejected prompt mapping should be stored with fallback confidence');
        Assert.areEqual(0, [
            SELECT COUNT()
            FROM clcommon__Category_Attachment_Association__c
            WHERE clcommon__Document_Category__c = :applicationLeafId
            AND clcommon__Content_Document_Id__c = :outputContentDocumentIdText
        ], 'output should not be attached to the application submission leaf');
        Assert.areEqual(1, [
            SELECT COUNT()
            FROM clcommon__Category_Attachment_Association__c
            WHERE clcommon__Document_Category__c = :fallback.Id
            AND clcommon__Content_Document_Id__c = :outputContentDocumentIdText
            AND clcommon__Status__c = 'Submitted'
        ], 'output should be attached to fallback Others');
    }

    @IsTest
    static void shouldAttachOutputToMultipleCategoriesWhenPromptReturnsMultipleTargets() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        List<clcommon__Document_Category__c> leaves = AIDocTestFactory.createCategories(app.Id, 2, true);
        leaves[0].clcommon__Category_Name__c = 'Personal Tax Return - John';
        leaves[1].clcommon__Category_Name__c = 'Personal Tax Return - Mary';
        update leaves;
        Id sourceContentDocumentId = createContentDocument('portal_bundle');
        Id outputContentDocumentId = createContentDocument('PersonalTaxReturn_John_and_Mary');
        Id splitJobId = createSplitJob(sourceContentDocumentId);
        linkFileToSplitJob(splitJobId, outputContentDocumentId);
        Id intakeJobId = createIntakeJob(app.Id);
        createIntakeFile(intakeJobId, sourceContentDocumentId, splitJobId);
        AIDocIntakeCategoryMappingService.testStubMappingResponse = JSON.serialize(new Map<String, Object>{
            'mappings' => new List<Object>{
                new Map<String, Object>{
                    'fileItemId' => String.valueOf(intakeJobId),
                    'contentDocumentId' => String.valueOf(outputContentDocumentId),
                    'targetCategoryIds' => new List<Object>{
                        String.valueOf(leaves[0].Id),
                        String.valueOf(leaves[1].Id)
                    },
                    'matchedParties' => new List<Object>{ 'John', 'Mary' },
                    'confidence' => 'HIGH',
                    'reason' => 'Joint tax return maps to both party tax categories.'
                }
            }
        });

        Test.startTest();
        AIDocIntakeCategoryMappingService.mapSplitOutputs(splitJobId);
        Test.stopTest();

        Document_Intake_File__c fileItem = [
            SELECT Document_Category__c, Mapping_Confidence__c, Split_Result_JSON__c
            FROM Document_Intake_File__c
            WHERE Intake_Job__c = :intakeJobId
            LIMIT 1
        ];
        Set<Id> targetCategoryIds = new Set<Id>{ leaves[0].Id, leaves[1].Id };
        String outputContentDocumentIdText = String.valueOf(outputContentDocumentId);
        Assert.areEqual(leaves[0].Id, fileItem.Document_Category__c,
            'single source intake item should retain the first mapped category as its primary category');
        Assert.areEqual(95, fileItem.Mapping_Confidence__c,
            'string confidence should be normalized to a percent');
        Assert.isTrue(fileItem.Split_Result_JSON__c.contains('targetCategoryIds'),
            'audit JSON should preserve all mapped categories');
        Assert.areEqual(2, [
            SELECT COUNT()
            FROM clcommon__Category_Attachment_Association__c
            WHERE clcommon__Document_Category__c IN :targetCategoryIds
            AND clcommon__Content_Document_Id__c = :outputContentDocumentIdText
            AND clcommon__Status__c = 'Submitted'
        ], 'split output file should be attached to every mapped target category');
    }

    private static Id createSplitJob(Id sourceContentDocumentId) {
        Id splitJobId = SplitJobService.startJob(
            sourceContentDocumentId,
            fakeLibraryId(),
            1,
            1
        );
        update new Split_Job__c(
            Id = splitJobId,
            Status__c = 'Complete',
            Documents_Created__c = 1,
            Merged_Segments_JSON__c = '[{"documentType":"OTHER","pages":[1]}]'
        );
        return splitJobId;
    }

    private static Id createIntakeJob(Id applicationId) {
        Document_Intake_Job__c job = new Document_Intake_Job__c(
            Application__c = applicationId,
            Client_Submission_Id__c = 'test-' + System.currentTimeMillis(),
            Client_Submission_Key__c = String.valueOf(applicationId) + ':test-' + System.currentTimeMillis(),
            Payload_Hash__c = 'hash-' + System.currentTimeMillis(),
            Source__c = 'PORTAL',
            Status__c = AIDocIntakeService.JOB_STATUS_PROCESSING,
            Total_Files__c = 1,
            Completed_Files__c = 0
        );
        insert job;
        return job.Id;
    }

    private static Id createApplicationSubmissionLeaf(Id applicationId) {
        clcommon__Document_Category__c root = new clcommon__Document_Category__c(
            genesis__Application__c = applicationId,
            clcommon__Category_Name__c = 'Application Documents'
        );
        insert root;

        clcommon__Document_Category__c leaf = new clcommon__Document_Category__c(
            genesis__Application__c = applicationId,
            clcommon__Category_Name__c = 'Application Submission Documents',
            clcommon__Parent_Document_Category__c = root.Id
        );
        insert leaf;
        return leaf.Id;
    }

    private static void createIntakeFile(Id intakeJobId, Id sourceContentDocumentId, Id splitJobId) {
        insert new Document_Intake_File__c(
            Intake_Job__c = intakeJobId,
            Item_Key__c = String.valueOf(intakeJobId) + ':' + String.valueOf(sourceContentDocumentId),
            ContentDocument_Id__c = String.valueOf(sourceContentDocumentId),
            File_Name__c = 'portal_bundle.pdf',
            Status__c = AIDocIntakeService.FILE_STATUS_MAPPING,
            Split_Job__c = splitJobId
        );
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

    private static void linkFileToSplitJob(Id splitJobId, Id contentDocumentId) {
        insert new ContentDocumentLink(
            ContentDocumentId = contentDocumentId,
            LinkedEntityId = splitJobId,
            ShareType = 'V',
            Visibility = 'AllUsers'
        );
    }

    private static Id fakeLibraryId() {
        return (Id) (ContentWorkspace.SObjectType
            .getDescribe(SObjectDescribeOptions.DEFERRED)
            .getKeyPrefix() + String.valueOf(UserInfo.getOrganizationId()).right(12));
    }
}

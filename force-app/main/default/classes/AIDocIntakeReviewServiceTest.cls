/**
 * Tests headless AI review after portal/API intake mapping.
 */
@IsTest
private class AIDocIntakeReviewServiceTest {
    @IsTest
    static void shouldReviewMappedFilesAndCompleteIntakeJob() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        List<clcommon__Document_Category__c> leaves =
            AIDocTestFactory.createCategories(app.Id, 1, true);
        leaves[0].clcommon__Category_Name__c = 'Business Bank Statement';
        update leaves[0];
        ContentDocumentLink link = AIDocTestFactory.attachFile(leaves[0].Id, 'business_bank_statement');
        Id intakeJobId = createIntakeJob(app.Id);
        createReviewingFile(intakeJobId, link.ContentDocumentId);
        AIDocIntakeReviewService.testStubReviewJson =
            '{"items":[{"documentName":"AI Doc Review - Bank Statement","severity":"success","status":"ACCEPTABLE","summary":"Statement looks acceptable.","detail":"Readable statement for expected party."}]}';
        AIDocIntakeEmailService.testStubEmailText =
            'Dear Borrower,\n\nWe have everything we need and will be in touch shortly.\n\nBest regards,\nYour Loan Officer';

        Test.startTest();
        Database.executeBatch(new AIDocIntakeReviewBatch(new List<Id>{ intakeJobId }), 1);
        Test.stopTest();

        Document_Intake_Job__c job = loadJob(intakeJobId);
        Document_Intake_File__c fileItem = loadOnlyFile(intakeJobId);
        genesis__Applications__c savedApp = loadApplication(app.Id);
        clcommon__Document_Category__c category = loadCategory(leaves[0].Id);
        Assert.areEqual(AIDocIntakeService.JOB_STATUS_COMPLETE, job.Status__c,
            'review batch should complete the intake job');
        Assert.areEqual(1, job.Completed_Files__c, 'reviewed intake file should count as complete');
        Assert.areEqual(AIDocIntakeService.FILE_STATUS_COMPLETE, fileItem.Status__c,
            'reviewed intake file should be complete');
        Assert.areEqual(true, category.AI_Reviewed__c,
            'category should be marked reviewed after result storage');
        Assert.isTrue(category.AI_Review_Feedback_JSON__c.contains(String.valueOf(link.ContentDocumentId)),
            'stored feedback should be keyed by the reviewed content document id');
        Assert.isTrue(category.AI_Review_Feedback_JSON__c.contains('Business Bank Statement'),
            'stored JSON should use the category name, not the prompt template name');
        Assert.isTrue(savedApp.Email_Template__c.contains('Dear Borrower'),
            'borrower email draft should be saved after review completes');
    }

    @IsTest
    static void shouldCompleteIntakeJobWhenNoReviewRowsAreNeeded() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        Id intakeJobId = createIntakeJob(app.Id);
        createReviewingFile(intakeJobId, null);

        Test.startTest();
        Database.executeBatch(new AIDocIntakeReviewBatch(new List<Id>{ intakeJobId }), 1);
        Test.stopTest();

        Document_Intake_Job__c job = loadJob(intakeJobId);
        Document_Intake_File__c fileItem = loadOnlyFile(intakeJobId);
        Assert.areEqual(AIDocIntakeService.JOB_STATUS_COMPLETE, job.Status__c,
            'empty review work should not leave the intake job stuck');
        Assert.areEqual(AIDocIntakeService.FILE_STATUS_COMPLETE, fileItem.Status__c,
            'reviewing file item should be closed when there are no rows to review');
    }

    @IsTest
    static void shouldUseAutomaticFallbackReviewSettingForIntake() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        clcommon__Document_Category__c parentCategory = new clcommon__Document_Category__c(
            clcommon__Category_Name__c = 'Uncategorized',
            genesis__Application__c = app.Id
        );
        insert parentCategory;
        clcommon__Document_Category__c fallbackCategory = new clcommon__Document_Category__c(
            clcommon__Category_Name__c = 'Others',
            genesis__Application__c = app.Id,
            clcommon__Parent_Document_Category__c = parentCategory.Id
        );
        insert fallbackCategory;
        ContentDocumentLink link = AIDocTestFactory.attachFile(fallbackCategory.Id, 'other_document');
        Id intakeJobId = createIntakeJob(app.Id);
        createReviewingFile(intakeJobId, link.ContentDocumentId);

        Test.startTest();
        AIDocIntakeReviewService.testAutoReviewFallbackCategory = false;
        List<String> excludedRows = AIDocIntakeReviewService.buildReviewRows(
            new Set<Id>{ intakeJobId }
        );
        AIDocIntakeReviewService.testAutoReviewFallbackCategory = true;
        List<String> includedRows = AIDocIntakeReviewService.buildReviewRows(
            new Set<Id>{ intakeJobId }
        );
        Test.stopTest();

        Assert.areEqual(0, excludedRows.size(),
            'automatic review should skip fallback files when metadata disables it');
        Assert.areEqual(1, includedRows.size(),
            'automatic review should include fallback files when metadata enables it');
    }

    @IsTest
    static void shouldIgnoreEmptyReviewRequests() {
        Test.startTest();
        AIDocIntakeReviewService.enqueueReview(null);
        AIDocIntakeReviewService.enqueueReview(new Set<Id>());
        List<String> rows = AIDocIntakeReviewService.buildReviewRows(null);
        AIDocIntakeReviewService.reviewEncodedRows(null);
        AIDocIntakeReviewService.reviewEncodedRows(new List<String>());
        AIDocIntakeEmailService.generateAndSaveForIntakeJobs(null);
        AIDocIntakeEmailService.generateAndSaveForIntakeJobs(new Set<Id>());
        Test.stopTest();

        Assert.areEqual(0, rows.size(), 'empty intake job set should produce no review rows');
    }

    @IsTest
    static void shouldThrowWhenReviewResultCannotBeStored() {
        String badRow = JSON.serialize(new Map<String, String>{
            'fileContentDocumentId' => fakeContentDocumentId(),
            'categoryName' => 'Missing Category',
            'partyName' => '',
            'partyType' => '',
            'documentCategoryId' => fakeDocumentCategoryId()
        });

        Boolean threw = false;
        Test.startTest();
        try {
            AIDocIntakeReviewService.reviewEncodedRows(new List<String>{ badRow });
        } catch (SplitJobException e) {
            threw = true;
        }
        Test.stopTest();

        Assert.areEqual(true, threw, 'invalid category id should surface a storage failure');
    }

    @IsTest
    static void shouldMarkIntakeFailedWhenBatchExecuteFails() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        Id intakeJobId = createIntakeJob(app.Id);
        createReviewingFile(intakeJobId, fakeContentDocumentId());
        String badRow = JSON.serialize(new Map<String, String>{
            'fileContentDocumentId' => fakeContentDocumentId(),
            'categoryName' => 'Missing Category',
            'partyName' => '',
            'partyType' => '',
            'documentCategoryId' => fakeDocumentCategoryId()
        });
        AIDocIntakeReviewBatch batch = new AIDocIntakeReviewBatch(new List<Id>{ intakeJobId });

        Test.startTest();
        batch.execute(null, new List<String>{ badRow });
        batch.finish(null);
        Test.stopTest();

        Document_Intake_Job__c job = loadJob(intakeJobId);
        Document_Intake_File__c fileItem = loadOnlyFile(intakeJobId);
        Assert.areEqual(AIDocIntakeService.JOB_STATUS_FAILED, job.Status__c,
            'batch failure should fail the intake job');
        Assert.areEqual(AIDocIntakeService.FILE_STATUS_FAILED, fileItem.Status__c,
            'batch failure should fail reviewing file items');
    }

    @IsTest
    static void shouldMarkIntakeFailedWhenBorrowerEmailDraftFails() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        Id intakeJobId = createIntakeJob(app.Id);
        createReviewingFile(intakeJobId, null);
        AIDocIntakeEmailService.testForceEmailFailure = true;

        Test.startTest();
        Database.executeBatch(new AIDocIntakeReviewBatch(new List<Id>{ intakeJobId }), 1);
        Test.stopTest();

        Document_Intake_Job__c job = loadJob(intakeJobId);
        Document_Intake_File__c fileItem = loadOnlyFile(intakeJobId);
        Assert.areEqual(AIDocIntakeService.JOB_STATUS_FAILED, job.Status__c,
            'email draft failure should fail the end-to-end intake job');
        Assert.areEqual(AIDocIntakeService.FILE_STATUS_FAILED, fileItem.Status__c,
            'reviewing file item should fail when email drafting fails');
    }

    @IsTest
    static void shouldRejectBatchWithoutIntakeJobs() {
        Boolean threw = false;
        try {
            new AIDocIntakeReviewBatch(new List<Id>());
        } catch (SplitJobException e) {
            threw = true;
        }

        Assert.areEqual(true, threw, 'batch should require at least one intake job id');
    }

    private static Id createIntakeJob(Id applicationId) {
        String unique = String.valueOf(System.currentTimeMillis());
        Document_Intake_Job__c job = new Document_Intake_Job__c(
            Application__c = applicationId,
            Client_Submission_Id__c = 'review-' + unique,
            Client_Submission_Key__c = String.valueOf(applicationId) + ':review-' + unique,
            Payload_Hash__c = 'hash-' + unique,
            Source__c = 'PORTAL',
            Status__c = AIDocIntakeService.JOB_STATUS_PROCESSING,
            Total_Files__c = 1,
            Completed_Files__c = 0
        );
        insert job;
        return job.Id;
    }

    private static void createReviewingFile(Id intakeJobId, Id contentDocumentId) {
        String contentDocumentIdText = contentDocumentId == null
            ? fakeContentDocumentId()
            : String.valueOf(contentDocumentId);
        insert new Document_Intake_File__c(
            Intake_Job__c = intakeJobId,
            Item_Key__c = String.valueOf(intakeJobId) + ':' + contentDocumentIdText,
            ContentDocument_Id__c = contentDocumentIdText,
            File_Name__c = 'business_bank_statement.pdf',
            Status__c = AIDocIntakeService.FILE_STATUS_REVIEWING
        );
    }

    private static Document_Intake_Job__c loadJob(Id intakeJobId) {
        return [
            SELECT Status__c, Completed_Files__c
            FROM Document_Intake_Job__c
            WHERE Id = :intakeJobId
        ];
    }

    private static Document_Intake_File__c loadOnlyFile(Id intakeJobId) {
        return [
            SELECT Status__c
            FROM Document_Intake_File__c
            WHERE Intake_Job__c = :intakeJobId
            LIMIT 1
        ];
    }

    private static clcommon__Document_Category__c loadCategory(Id categoryId) {
        return [
            SELECT AI_Reviewed__c, AI_Review_Feedback_JSON__c
            FROM clcommon__Document_Category__c
            WHERE Id = :categoryId
        ];
    }

    private static genesis__Applications__c loadApplication(Id applicationId) {
        return [
            SELECT Email_Template__c
            FROM genesis__Applications__c
            WHERE Id = :applicationId
        ];
    }

    private static String fakeContentDocumentId() {
        return ContentDocument.SObjectType
            .getDescribe(SObjectDescribeOptions.DEFERRED)
            .getKeyPrefix() + String.valueOf(UserInfo.getOrganizationId()).right(12);
    }

    private static String fakeDocumentCategoryId() {
        return clcommon__Document_Category__c.SObjectType
            .getDescribe(SObjectDescribeOptions.DEFERRED)
            .getKeyPrefix() + String.valueOf(UserInfo.getOrganizationId()).right(12);
    }
}

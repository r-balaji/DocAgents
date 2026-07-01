/**
 * Tests for AIDocReviewResultStore.
 */
@IsTest
private class AIDocReviewResultStoreTest {
    private static final String CLASSIFICATION_JSON =
        '{"items":[{"documentName":"Passport","category":"Passport","status":"OK"}]}';
    private static final String SANITY_JSON =
        '{"items":[{"documentName":"Passport","partyName":"Bill Vance","partyType":"GUARANTOR","severity":"success","status":"ACCEPTABLE","summary":"Passport is current."}]}';

    @IsTest
    static void shouldStoreFeedbackByContentDocumentId_WhenReviewCompletes() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        List<clcommon__Document_Category__c> leaves =
            AIDocTestFactory.createCategories(app.Id, 1, true);
        ContentDocumentLink link = AIDocTestFactory.attachFile(leaves[0].Id, 'passport');

        AIDocReviewResultStore.Request req = buildRequest(leaves[0].Id, link.ContentDocumentId);

        Test.startTest();
        List<AIDocReviewResultStore.Response> out =
            AIDocReviewResultStore.execute(new List<AIDocReviewResultStore.Request>{ req });
        Test.stopTest();

        Assert.areEqual(true, out[0].isSuccess, 'save should succeed');
        Assert.areEqual(true, out[0].isReviewed, 'single current file should make category reviewed');

        clcommon__Document_Category__c category = loadCategory(leaves[0].Id);
        Assert.areEqual(true, category.AI_Reviewed__c, 'category flag should be checked');
        Map<String, Object> stored = parseFeedback(category.AI_Review_Feedback_JSON__c);
        Assert.isTrue(stored.containsKey(String.valueOf(link.ContentDocumentId)), 'feedback should be keyed by content id');
    }

    @IsTest
    static void shouldKeepExistingFeedbackAndMarkIncomplete_WhenNewFileAdded() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        List<clcommon__Document_Category__c> leaves =
            AIDocTestFactory.createCategories(app.Id, 1, true);
        ContentDocumentLink firstLink = AIDocTestFactory.attachFile(leaves[0].Id, 'passport');
        saveReview(leaves[0].Id, firstLink.ContentDocumentId);

        Test.startTest();
        ContentDocumentLink secondLink = AIDocTestFactory.attachFile(leaves[0].Id, 'passport_second');
        Test.stopTest();

        clcommon__Document_Category__c category = loadCategory(leaves[0].Id);
        Assert.areEqual(false, category.AI_Reviewed__c, 'new file should mark category incomplete');
        Map<String, Object> stored = parseFeedback(category.AI_Review_Feedback_JSON__c);
        Assert.isTrue(stored.containsKey(String.valueOf(firstLink.ContentDocumentId)), 'existing verdict should remain');
        Assert.isFalse(stored.containsKey(String.valueOf(secondLink.ContentDocumentId)), 'new file should not have a verdict yet');
    }

    @IsTest
    static void shouldMarkReviewed_WhenSecondFileResultIsMerged() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        List<clcommon__Document_Category__c> leaves =
            AIDocTestFactory.createCategories(app.Id, 1, true);
        ContentDocumentLink firstLink = AIDocTestFactory.attachFile(leaves[0].Id, 'passport');
        saveReview(leaves[0].Id, firstLink.ContentDocumentId);
        ContentDocumentLink secondLink = AIDocTestFactory.attachFile(leaves[0].Id, 'passport_second');

        AIDocReviewResultStore.Request req = buildRequest(leaves[0].Id, secondLink.ContentDocumentId);

        Test.startTest();
        List<AIDocReviewResultStore.Response> out =
            AIDocReviewResultStore.execute(new List<AIDocReviewResultStore.Request>{ req });
        Test.stopTest();

        Assert.areEqual(true, out[0].isReviewed, 'both current files should now be reviewed');
        clcommon__Document_Category__c category = loadCategory(leaves[0].Id);
        Map<String, Object> stored = parseFeedback(category.AI_Review_Feedback_JSON__c);
        Assert.areEqual(true, category.AI_Reviewed__c, 'category flag should be checked again');
        Assert.isTrue(stored.containsKey(String.valueOf(firstLink.ContentDocumentId)), 'first verdict should remain');
        Assert.isTrue(stored.containsKey(String.valueOf(secondLink.ContentDocumentId)), 'second verdict should be added');
    }

    @IsTest
    static void shouldRecalculateReviewed_WhenUnreviewedFileIsDeleted() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        List<clcommon__Document_Category__c> leaves =
            AIDocTestFactory.createCategories(app.Id, 1, true);
        ContentDocumentLink reviewedLink = AIDocTestFactory.attachFile(leaves[0].Id, 'passport');
        saveReview(leaves[0].Id, reviewedLink.ContentDocumentId);
        ContentDocumentLink unreviewedLink = AIDocTestFactory.attachFile(leaves[0].Id, 'passport_second');

        Test.startTest();
        delete unreviewedLink;
        Test.stopTest();

        clcommon__Document_Category__c category = loadCategory(leaves[0].Id);
        Assert.areEqual(true, category.AI_Reviewed__c, 'remaining current file has a stored verdict');
    }

    @IsTest
    static void shouldReturnError_WhenRequiredInputsAreMissing() {
        AIDocReviewResultStore.Request req = new AIDocReviewResultStore.Request();

        Test.startTest();
        List<AIDocReviewResultStore.Response> out =
            AIDocReviewResultStore.execute(new List<AIDocReviewResultStore.Request>{ req });
        Test.stopTest();

        Assert.areEqual(false, out[0].isSuccess, 'missing category should fail');
        Assert.areEqual('MISSING_INPUT', out[0].errorType, 'error type should explain missing input');
    }

    private static AIDocReviewResultStore.Request buildRequest(Id categoryId, Id contentDocumentId) {
        AIDocReviewResultStore.Request req = new AIDocReviewResultStore.Request();
        req.documentCategoryId = categoryId;
        req.fileContentDocumentId = contentDocumentId;
        req.classificationJson = CLASSIFICATION_JSON;
        req.sanityJson = SANITY_JSON;
        return req;
    }

    private static void saveReview(Id categoryId, Id contentDocumentId) {
        AIDocReviewResultStore.execute(new List<AIDocReviewResultStore.Request>{
            buildRequest(categoryId, contentDocumentId)
        });
    }

    private static clcommon__Document_Category__c loadCategory(Id categoryId) {
        return [
            SELECT AI_Reviewed__c, AI_Review_Feedback_JSON__c
            FROM clcommon__Document_Category__c
            WHERE Id = :categoryId
        ];
    }

    private static Map<String, Object> parseFeedback(String rawJson) {
        return (Map<String, Object>) JSON.deserializeUntyped(rawJson);
    }
}

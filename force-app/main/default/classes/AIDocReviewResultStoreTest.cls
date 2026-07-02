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
    static void shouldStoreCategoryNameInReviewJson_WhenPromptReturnsPromptName() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        List<clcommon__Document_Category__c> leaves =
            AIDocTestFactory.createCategories(app.Id, 1, true);
        ContentDocumentLink link = AIDocTestFactory.attachFile(leaves[0].Id, 'passport');
        AIDocReviewResultStore.Request req = buildRequest(leaves[0].Id, link.ContentDocumentId);
        req.classificationJson =
            '{"items":[{"documentName":"AI Doc Review - Identity","category":"Passport","status":"ACCEPTABLE"}]}';
        req.sanityJson =
            '{"items":[{"documentName":"AI Doc Review - Identity","status":"ACCEPTABLE","summary":"Looks okay."}]}';

        Test.startTest();
        AIDocReviewResultStore.execute(new List<AIDocReviewResultStore.Request>{ req });
        Test.stopTest();

        clcommon__Document_Category__c category = loadCategory(leaves[0].Id);
        Map<String, Object> stored = parseFeedback(category.AI_Review_Feedback_JSON__c);
        Map<String, Object> review = (Map<String, Object>) stored.get(String.valueOf(link.ContentDocumentId));
        Assert.areEqual(leaves[0].clcommon__Category_Name__c, firstDocumentName((String) review.get('classificationJson')),
            'stored classification should use the category name');
        Assert.areEqual(leaves[0].clcommon__Category_Name__c, firstDocumentName((String) review.get('sanityJson')),
            'stored sanity should use the category name');
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
    static void shouldRecalculateReviewed_WhenUnreviewedFileAssociationIsDeleted() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        List<clcommon__Document_Category__c> leaves =
            AIDocTestFactory.createCategories(app.Id, 1, true);
        ContentDocumentLink reviewedLink = AIDocTestFactory.attachFile(leaves[0].Id, 'passport');
        saveReview(leaves[0].Id, reviewedLink.ContentDocumentId);
        ContentDocumentLink unreviewedLink = AIDocTestFactory.attachFile(leaves[0].Id, 'passport_second');
        clcommon__Category_Attachment_Association__c unreviewedAssociation =
            loadAssociation(leaves[0].Id, unreviewedLink.ContentDocumentId);

        Test.startTest();
        delete unreviewedAssociation;
        Test.stopTest();

        clcommon__Document_Category__c category = loadCategory(leaves[0].Id);
        Assert.areEqual(true, category.AI_Reviewed__c, 'remaining current file has a stored verdict');
    }

    @IsTest
    static void shouldRemoveStoredFeedback_WhenReviewedFileAssociationIsDeleted() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        List<clcommon__Document_Category__c> leaves =
            AIDocTestFactory.createCategories(app.Id, 1, true);
        ContentDocumentLink firstLink = AIDocTestFactory.attachFile(leaves[0].Id, 'passport');
        ContentDocumentLink secondLink = AIDocTestFactory.attachFile(leaves[0].Id, 'passport_second');
        saveReview(leaves[0].Id, firstLink.ContentDocumentId);
        saveReview(leaves[0].Id, secondLink.ContentDocumentId);
        clcommon__Category_Attachment_Association__c firstAssociation =
            loadAssociation(leaves[0].Id, firstLink.ContentDocumentId);

        Test.startTest();
        delete firstAssociation;
        Test.stopTest();

        clcommon__Document_Category__c category = loadCategory(leaves[0].Id);
        Map<String, Object> stored = parseFeedback(category.AI_Review_Feedback_JSON__c);
        List<ContentDocumentLink> rawLinks = [SELECT Id FROM ContentDocumentLink WHERE Id = :firstLink.Id];
        Assert.areEqual(true, category.AI_Reviewed__c, 'remaining reviewed file should keep category reviewed');
        Assert.areEqual(1, rawLinks.size(), 'raw file link can remain after product association is deleted');
        Assert.isFalse(stored.containsKey(String.valueOf(firstLink.ContentDocumentId)), 'deleted file verdict should be removed');
        Assert.isTrue(stored.containsKey(String.valueOf(secondLink.ContentDocumentId)), 'remaining file verdict should stay');
    }

    @IsTest
    static void shouldRemoveStoredFeedback_WhenAssociationIsRejected() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        List<clcommon__Document_Category__c> leaves =
            AIDocTestFactory.createCategories(app.Id, 1, true);
        ContentDocumentLink link = AIDocTestFactory.attachFile(leaves[0].Id, 'passport');
        saveReview(leaves[0].Id, link.ContentDocumentId);
        clcommon__Category_Attachment_Association__c association =
            loadAssociation(leaves[0].Id, link.ContentDocumentId);

        Test.startTest();
        association.clcommon__Status__c = 'Rejected';
        update association;
        Test.stopTest();

        clcommon__Document_Category__c category = loadCategory(leaves[0].Id);
        Assert.areEqual(false, category.AI_Reviewed__c, 'no current files should leave category unreviewed');
        Assert.isTrue(String.isBlank(category.AI_Review_Feedback_JSON__c),
            'inactive file verdict should be removed from stored feedback');
    }

    @IsTest
    static void shouldIgnoreStaleAssociationAndRemoveStoredFeedback_WhenContentDocumentNoLongerExists() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        List<clcommon__Document_Category__c> leaves =
            AIDocTestFactory.createCategories(app.Id, 1, true);
        ContentDocumentLink liveLink = AIDocTestFactory.attachFile(leaves[0].Id, 'passport');
        String staleContentDocumentId = staleContentDocumentId();
        insert new clcommon__Category_Attachment_Association__c(
            clcommon__Document_Category__c = leaves[0].Id,
            clcommon__Attachment_Id__c = 'stale-link',
            clcommon__Content_Document_Id__c = staleContentDocumentId
        );
        update new clcommon__Document_Category__c(
            Id = leaves[0].Id,
            AI_Reviewed__c = false,
            AI_Review_Feedback_JSON__c = JSON.serialize(new Map<String, Object>{
                String.valueOf(liveLink.ContentDocumentId) => reviewPayload(),
                staleContentDocumentId => reviewPayload()
            })
        );

        Test.startTest();
        AIDocReviewResultStore.recalculateForDocumentCategoryIds(new Set<Id>{ leaves[0].Id });
        Test.stopTest();

        clcommon__Document_Category__c category = loadCategory(leaves[0].Id);
        Map<String, Object> stored = parseFeedback(category.AI_Review_Feedback_JSON__c);
        Assert.areEqual(true, category.AI_Reviewed__c, 'live reviewed file should make category reviewed');
        Assert.isTrue(stored.containsKey(String.valueOf(liveLink.ContentDocumentId)), 'live feedback should remain');
        Assert.isFalse(stored.containsKey(staleContentDocumentId), 'dead ContentDocument feedback should be pruned');
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

    private static Map<String, Object> reviewPayload() {
        return new Map<String, Object>{
            'classificationJson' => CLASSIFICATION_JSON,
            'sanityJson' => SANITY_JSON
        };
    }

    private static clcommon__Document_Category__c loadCategory(Id categoryId) {
        return [
            SELECT AI_Reviewed__c, AI_Review_Feedback_JSON__c
            FROM clcommon__Document_Category__c
            WHERE Id = :categoryId
        ];
    }

    private static clcommon__Category_Attachment_Association__c loadAssociation(Id categoryId, Id contentDocumentId) {
        return [
            SELECT Id, clcommon__Status__c
            FROM clcommon__Category_Attachment_Association__c
            WHERE clcommon__Document_Category__c = :categoryId
            AND clcommon__Content_Document_Id__c = :contentDocumentId
            LIMIT 1
        ];
    }

    private static Map<String, Object> parseFeedback(String rawJson) {
        return (Map<String, Object>) JSON.deserializeUntyped(rawJson);
    }

    private static String firstDocumentName(String rawJson) {
        Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(rawJson);
        List<Object> items = (List<Object>) payload.get('items');
        Map<String, Object> first = (Map<String, Object>) items[0];
        return (String) first.get('documentName');
    }

    private static String staleContentDocumentId() {
        return ContentDocument.SObjectType
            .getDescribe(SObjectDescribeOptions.DEFERRED)
            .getKeyPrefix() + String.valueOf(UserInfo.getOrganizationId()).right(12);
    }
}

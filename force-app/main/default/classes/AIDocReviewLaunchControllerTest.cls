/**
 * Tests for AIDocReviewLaunchController.
 */
@IsTest
private class AIDocReviewLaunchControllerTest {
    private static final String CLASSIFICATION_JSON =
        '{"items":[{"documentName":"Passport","category":"Passport","status":"ACCEPTABLE"}]}';
    private static final String SANITY_JSON =
        '{"items":[{"documentName":"Passport","severity":"success","status":"ACCEPTABLE","summary":"Passport is current."}]}';

    @IsTest
    static void shouldRunFlowWhenCurrentFileHasNoCachedReview() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        List<clcommon__Document_Category__c> leaves =
            AIDocTestFactory.createCategories(app.Id, 1, true);
        AIDocTestFactory.attachFile(leaves[0].Id, 'passport');

        Test.startTest();
        AIDocReviewLaunchController.LaunchState state =
            AIDocReviewLaunchController.getLaunchState(app.Id, false);
        Test.stopTest();

        Assert.areEqual(true, state.isSuccess, 'coverage should succeed');
        Assert.areEqual(false, state.canShowCachedReview, 'uncached file cannot use the cached view');
        Assert.areEqual(true, state.shouldRunFlow, 'uncached file should launch the review flow');
        Assert.areEqual(1, state.unreviewedFileCount, 'one current file still needs review');
    }

    @IsTest
    static void shouldShowCachedReviewWhenAllCurrentFilesAlreadyReviewed() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        List<clcommon__Document_Category__c> leaves =
            AIDocTestFactory.createCategories(app.Id, 2, true);
        ContentDocumentLink link = AIDocTestFactory.attachFile(leaves[0].Id, 'passport');
        storeCachedReview(leaves[0].Id, link.ContentDocumentId);

        Test.startTest();
        AIDocReviewLaunchController.LaunchState state =
            AIDocReviewLaunchController.getLaunchState(app.Id, false);
        Test.stopTest();

        Assert.areEqual(true, state.isSuccess, 'coverage should succeed');
        Assert.areEqual(true, state.canShowCachedReview, 'all current files have cached review');
        Assert.areEqual(false, state.shouldRunFlow, 'review flow should be skipped');
        Assert.areEqual(0, state.unreviewedFileCount, 'no file should be sent back to the LLM');
        Assert.areEqual(2, state.totalCount, 'coverage totals should still be returned');
        Assert.areEqual(1, state.missingCount, 'missing categories remain visible in the cached view');
        Assert.areEqual(leaves[0].clcommon__Category_Name__c, firstDocumentName(state.classificationJson),
            'cached classification should be normalized to the category name');
    }

    @IsTest
    static void shouldRunFlowForFallbackOnlyWhenUserIncludesIt() {
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
        clcommon__Document_Category__c passportCategory = new clcommon__Document_Category__c(
            clcommon__Category_Name__c = 'Passport',
            genesis__Application__c = app.Id,
            clcommon__Parent_Document_Category__c = parentCategory.Id
        );
        insert new List<clcommon__Document_Category__c>{ fallbackCategory, passportCategory };

        AIDocTestFactory.attachFile(fallbackCategory.Id, 'other_document');
        ContentDocumentLink passportLink = AIDocTestFactory.attachFile(passportCategory.Id, 'passport');
        storeCachedReview(passportCategory.Id, passportLink.ContentDocumentId);

        Test.startTest();
        AIDocReviewLaunchController.LaunchState excludedState =
            AIDocReviewLaunchController.getLaunchState(app.Id, false);
        AIDocReviewLaunchController.LaunchState includedState =
            AIDocReviewLaunchController.getLaunchState(app.Id, true);
        Test.stopTest();

        Assert.areEqual(true, excludedState.canShowCachedReview,
            'unchecked fallback category should not force another AI call');
        Assert.areEqual(false, includedState.canShowCachedReview,
            'checked fallback category should include its unreviewed file');
        Assert.areEqual(1, includedState.unreviewedFileCount,
            'only the fallback file still needs review');
    }

    @IsTest
    static void shouldClearStoredReviewWhenUserRequestsReset() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        List<clcommon__Document_Category__c> leaves =
            AIDocTestFactory.createCategories(app.Id, 2, true);
        ContentDocumentLink firstLink = AIDocTestFactory.attachFile(leaves[0].Id, 'passport');
        ContentDocumentLink secondLink = AIDocTestFactory.attachFile(leaves[1].Id, 'bank_statement');
        storeCachedReview(leaves[0].Id, firstLink.ContentDocumentId);
        storeCachedReview(leaves[1].Id, secondLink.ContentDocumentId);

        Test.startTest();
        AIDocReviewLaunchController.ClearResult result =
            AIDocReviewLaunchController.clearReview(app.Id);
        Test.stopTest();

        Assert.areEqual(true, result.success, 'clear should succeed');
        Assert.areEqual(2, result.clearedCount, 'both reviewed categories should be reset');

        Set<Id> reviewedCategoryIds = new Set<Id>{ leaves[0].Id, leaves[1].Id };
        for (clcommon__Document_Category__c category : [
            SELECT AI_Reviewed__c, AI_Review_Feedback_JSON__c
            FROM clcommon__Document_Category__c
            WHERE Id IN :reviewedCategoryIds
        ]) {
            Assert.areEqual(false, category.AI_Reviewed__c, 'AI reviewed flag should be unchecked');
            Assert.isTrue(String.isBlank(category.AI_Review_Feedback_JSON__c),
                'cached review JSON should be cleared');
        }
    }

    @IsTest
    static void shouldReturnZeroClearedWhenNoStoredReviewExists() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        AIDocTestFactory.createCategories(app.Id, 1, true);

        Test.startTest();
        AIDocReviewLaunchController.ClearResult result =
            AIDocReviewLaunchController.clearReview(app.Id);
        Test.stopTest();

        Assert.areEqual(true, result.success, 'empty reset should still succeed');
        Assert.areEqual(0, result.clearedCount, 'nothing should be updated');
    }

    private static void storeCachedReview(Id categoryId, Id contentDocumentId) {
        update new clcommon__Document_Category__c(
            Id = categoryId,
            AI_Reviewed__c = true,
            AI_Review_Feedback_JSON__c = JSON.serialize(new Map<String, Object>{
                String.valueOf(contentDocumentId) => new Map<String, Object>{
                    'classificationJson' => CLASSIFICATION_JSON,
                    'sanityJson' => SANITY_JSON
                }
            })
        );
    }

    private static String firstDocumentName(String rawJson) {
        Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(rawJson);
        List<Object> items = (List<Object>) payload.get('items');
        Map<String, Object> first = (Map<String, Object>) items[0];
        return (String) first.get('documentName');
    }
}

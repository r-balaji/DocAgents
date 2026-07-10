/**
 * Tests clearing document category file references.
 */
@IsTest
private class AIDocCategoryFileControllerTest {
    @IsTest
    static void shouldClearCategoryReferencesWithoutDeletingFiles() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        List<clcommon__Document_Category__c> categories =
            AIDocTestFactory.createCategories(app.Id, 2, true);
        ContentDocumentLink firstLink = AIDocTestFactory.attachFile(categories[0].Id, 'first_file');
        ContentDocumentLink secondLink = AIDocTestFactory.attachFile(categories[1].Id, 'second_file');
        Set<Id> categoryIds = new Set<Id>{ categories[0].Id, categories[1].Id };
        Set<Id> contentDocumentIds = new Set<Id>{ firstLink.ContentDocumentId, secondLink.ContentDocumentId };
        storeCachedReview(categories[0].Id, firstLink.ContentDocumentId);
        storeCachedReview(categories[1].Id, secondLink.ContentDocumentId);

        Test.startTest();
        AIDocCategoryFileController.CategoryFileClearResult result =
            AIDocCategoryFileController.clearCategoryFileReferences(app.Id);
        Test.stopTest();

        Assert.areEqual(true, result.success, 'clear should succeed');
        Assert.areEqual(2, result.associationsRemoved, 'two package association rows should be deleted');
        Assert.areEqual(2, result.contentLinksRemoved, 'two category file links should be deleted');
        Assert.areEqual(0, [
            SELECT COUNT()
            FROM clcommon__Category_Attachment_Association__c
            WHERE clcommon__Document_Category__c IN :categoryIds
        ], 'package category associations should be removed');
        Assert.areEqual(0, [
            SELECT COUNT()
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :categoryIds
        ], 'category ContentDocumentLinks should be removed');
        Assert.areEqual(2, [
            SELECT COUNT()
            FROM ContentDocument
            WHERE Id IN :contentDocumentIds
        ], 'underlying Salesforce Files should remain');

        for (clcommon__Document_Category__c category : [
            SELECT AI_Reviewed__c, AI_Review_Feedback_JSON__c
            FROM clcommon__Document_Category__c
            WHERE Id IN :categoryIds
        ]) {
            Assert.areEqual(false, category.AI_Reviewed__c, 'review flag should be reset');
            Assert.isTrue(String.isBlank(category.AI_Review_Feedback_JSON__c),
                'review JSON should be cleared');
        }
    }

    @IsTest
    static void shouldReturnSuccessWhenApplicationHasNoCategories() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);

        Test.startTest();
        AIDocCategoryFileController.CategoryFileClearResult result =
            AIDocCategoryFileController.clearCategoryFileReferences(app.Id);
        Test.stopTest();

        Assert.areEqual(true, result.success, 'empty clear should still succeed');
        Assert.areEqual(0, result.categoryCount, 'no categories should be counted');
        Assert.areEqual(0, result.associationsRemoved, 'nothing should be deleted');
        Assert.areEqual(0, result.contentLinksRemoved, 'no file links should be deleted');
    }

    @IsTest
    static void shouldClearReviewCacheWhenCategoriesHaveNoFiles() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        List<clcommon__Document_Category__c> categories =
            AIDocTestFactory.createCategories(app.Id, 1, true);
        update new clcommon__Document_Category__c(
            Id = categories[0].Id,
            AI_Reviewed__c = true,
            AI_Review_Feedback_JSON__c = '{"069000000000000AAA":{"sanityJson":"{}"}}'
        );

        Test.startTest();
        AIDocCategoryFileController.CategoryFileClearResult result =
            AIDocCategoryFileController.clearCategoryFileReferences(app.Id);
        Test.stopTest();

        Assert.areEqual(true, result.success, 'clear should succeed');
        Assert.areEqual(2, result.categoryCount, 'parent and child categories should be counted');
        Assert.areEqual(0, result.associationsRemoved, 'no association rows should be deleted');
        Assert.areEqual(0, result.contentLinksRemoved, 'no file links should be deleted');
        Assert.areEqual(1, result.reviewCategoriesCleared, 'review cache should be cleared');

        clcommon__Document_Category__c category = [
            SELECT AI_Reviewed__c, AI_Review_Feedback_JSON__c
            FROM clcommon__Document_Category__c
            WHERE Id = :categories[0].Id
            LIMIT 1
        ];
        Assert.areEqual(false, category.AI_Reviewed__c, 'review flag should be reset');
        Assert.isTrue(String.isBlank(category.AI_Review_Feedback_JSON__c),
            'review JSON should be cleared');
    }

    private static void storeCachedReview(Id categoryId, Id contentDocumentId) {
        update new clcommon__Document_Category__c(
            Id = categoryId,
            AI_Reviewed__c = true,
            AI_Review_Feedback_JSON__c = JSON.serialize(new Map<String, Object>{
                String.valueOf(contentDocumentId) => new Map<String, Object>{
                    'classificationJson' => '{"items":[]}',
                    'sanityJson' => '{"items":[]}'
                }
            })
        );
    }
}

/**
 * LWC controller for clearing Application document category file references.
 */
public with sharing class AIDocCategoryFileController {
    /**
     * Removes all file references from document categories on an application.
     * The Salesforce Files themselves are not deleted.
     * @param applicationId Application record Id.
     * @return Clear operation result.
     * @throws AuraHandledException when the application Id is missing or rows cannot be cleared.
     */
    @AuraEnabled
    public static CategoryFileClearResult clearCategoryFileReferences(Id applicationId) {
        validateApplicationId(applicationId);

        try {
            Set<Id> categoryIds = loadCategoryIds(applicationId);
            CategoryFileClearResult result = new CategoryFileClearResult();
            result.success = true;
            result.categoryCount = categoryIds.size();

            deleteAssociations(loadCategoryAssociations(categoryIds), result);
            deleteContentDocumentLinks(loadCategoryContentDocumentLinks(categoryIds), result);
            clearCategoryReviewCache(applicationId, result);
            result.success = result.errorCount == 0;
            return result;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to clear document category files.');
        }
    }

    private static void validateApplicationId(Id applicationId) {
        if (applicationId == null) {
            throw new AuraHandledException('Application Id is required.');
        }
    }

    private static Set<Id> loadCategoryIds(Id applicationId) {
        Set<Id> categoryIds = new Set<Id>();
        for (clcommon__Document_Category__c category : [
            SELECT Id
            FROM clcommon__Document_Category__c
            WHERE genesis__Application__c = :applicationId
            WITH USER_MODE
            LIMIT 5000
        ]) {
            categoryIds.add(category.Id);
        }
        return categoryIds;
    }

    private static List<clcommon__Category_Attachment_Association__c> loadCategoryAssociations(Set<Id> categoryIds) {
        if (categoryIds.isEmpty()) {
            return new List<clcommon__Category_Attachment_Association__c>();
        }
        return [
            SELECT Id, clcommon__Document_Category__c
            FROM clcommon__Category_Attachment_Association__c
            WHERE clcommon__Document_Category__c IN :categoryIds
            WITH USER_MODE
            LIMIT 5000
        ];
    }

    private static List<ContentDocumentLink> loadCategoryContentDocumentLinks(Set<Id> categoryIds) {
        if (categoryIds.isEmpty()) {
            return new List<ContentDocumentLink>();
        }
        return [
            SELECT Id, LinkedEntityId
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :categoryIds
            WITH USER_MODE
            LIMIT 10000
        ];
    }

    private static void deleteAssociations(
        List<clcommon__Category_Attachment_Association__c> associations,
        CategoryFileClearResult result
    ) {
        if (associations.isEmpty()) {
            return;
        }
        collectDeleteErrors(Database.delete(associations, false, AccessLevel.USER_MODE), result, true);
    }

    private static void deleteContentDocumentLinks(
        List<ContentDocumentLink> links,
        CategoryFileClearResult result
    ) {
        if (links.isEmpty()) {
            return;
        }
        collectDeleteErrors(Database.delete(links, false, AccessLevel.USER_MODE), result, false);
    }

    private static void clearCategoryReviewCache(Id applicationId, CategoryFileClearResult result) {
        List<clcommon__Document_Category__c> updates = new List<clcommon__Document_Category__c>();
        for (clcommon__Document_Category__c category : [
            SELECT Id, AI_Reviewed__c, AI_Review_Feedback_JSON__c
            FROM clcommon__Document_Category__c
            WHERE genesis__Application__c = :applicationId
            WITH USER_MODE
            LIMIT 5000
        ]) {
            if (category.AI_Reviewed__c != true && String.isBlank(category.AI_Review_Feedback_JSON__c)) {
                continue;
            }
            updates.add(new clcommon__Document_Category__c(
                Id = category.Id,
                AI_Reviewed__c = false,
                AI_Review_Feedback_JSON__c = null
            ));
        }
        if (updates.isEmpty()) {
            return;
        }

        Database.SaveResult[] saveResults = Database.update(updates, false, AccessLevel.USER_MODE);
        for (Database.SaveResult saveResult : saveResults) {
            if (saveResult.isSuccess()) {
                result.reviewCategoriesCleared++;
                continue;
            }
            result.errorCount++;
            setFirstError(result, saveResult.getErrors()[0]);
        }
    }

    private static void collectDeleteErrors(
        Database.DeleteResult[] deleteResults,
        CategoryFileClearResult result,
        Boolean associationResults
    ) {
        for (Database.DeleteResult deleteResult : deleteResults) {
            if (deleteResult.isSuccess()) {
                if (associationResults) {
                    result.associationsRemoved++;
                } else {
                    result.contentLinksRemoved++;
                }
                continue;
            }
            result.errorCount++;
            setFirstError(result, deleteResult.getErrors()[0]);
        }
    }

    private static void setFirstError(CategoryFileClearResult result, Database.Error err) {
        if (String.isBlank(result.errorMessage)) {
            result.errorMessage = err.getMessage();
            result.errorType = String.valueOf(err.getStatusCode());
        }
    }

    /**
     * Result returned after clearing category file references.
     */
    public class CategoryFileClearResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public Integer categoryCount;
        @AuraEnabled public Integer associationsRemoved;
        @AuraEnabled public Integer contentLinksRemoved;
        @AuraEnabled public Integer reviewCategoriesCleared;
        @AuraEnabled public Integer errorCount;
        @AuraEnabled public String errorMessage;
        @AuraEnabled public String errorType;

        /**
         * Initializes clear counters.
         */
        public CategoryFileClearResult() {
            this.categoryCount = 0;
            this.associationsRemoved = 0;
            this.contentLinksRemoved = 0;
            this.reviewCategoriesCleared = 0;
            this.errorCount = 0;
        }
    }
}

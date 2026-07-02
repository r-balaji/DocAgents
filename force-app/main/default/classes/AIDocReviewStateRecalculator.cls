/**
 * Recalculates cached AI review state when document-category file membership changes.
 */
public inherited sharing class AIDocReviewStateRecalculator {
    /**
     * Recalculates review flags and prunes cached feedback for the supplied categories.
     * @param documentCategoryIds Document category ids whose current files should be re-evaluated.
     */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    public static void recalculateReviewFlags(Set<Id> documentCategoryIds) {
        if (documentCategoryIds == null || documentCategoryIds.isEmpty()) {
            return;
        }

        Map<Id, clcommon__Document_Category__c> categoriesById = loadCategories(documentCategoryIds);
        Map<Id, Set<Id>> currentDocIdsByCategoryId =
            AIDocReviewFileSelector.selectCurrentContentDocumentIdsByCategorySystemMode(documentCategoryIds);
        List<clcommon__Document_Category__c> updates = buildUpdates(categoriesById, currentDocIdsByCategoryId);
        if (!updates.isEmpty()) {
            Database.update(updates, false);
        }
    }

    /**
     * Extracts document category ids from ContentDocumentLink trigger rows.
     * @param links ContentDocumentLink trigger records.
     * @return Linked document category ids.
     */
    public static Set<Id> extractDocumentCategoryIds(List<ContentDocumentLink> links) {
        Set<Id> documentCategoryIds = new Set<Id>();
        String categoryPrefix = clcommon__Document_Category__c.SObjectType
            .getDescribe(SObjectDescribeOptions.DEFERRED)
            .getKeyPrefix();
        for (ContentDocumentLink link : links) {
            if (isDocumentCategoryLink(link, categoryPrefix)) {
                documentCategoryIds.add(link.LinkedEntityId);
            }
        }
        return documentCategoryIds;
    }

    /**
     * Extracts document category ids from product category/file association trigger rows.
     * @param associations Category attachment association trigger records.
     * @return Associated document category ids.
     */
    public static Set<Id> extractDocumentCategoryIdsFromAssociations(
        List<clcommon__Category_Attachment_Association__c> associations
    ) {
        Set<Id> documentCategoryIds = new Set<Id>();
        if (associations == null) {
            return documentCategoryIds;
        }
        for (clcommon__Category_Attachment_Association__c association : associations) {
            if (association != null && association.clcommon__Document_Category__c != null) {
                documentCategoryIds.add(association.clcommon__Document_Category__c);
            }
        }
        return documentCategoryIds;
    }

    @SuppressWarnings('PMD.ApexCRUDViolation')
    private static Map<Id, clcommon__Document_Category__c> loadCategories(Set<Id> documentCategoryIds) {
        return new Map<Id, clcommon__Document_Category__c>([
            SELECT Id, AI_Reviewed__c, AI_Review_Feedback_JSON__c
            FROM clcommon__Document_Category__c
            WHERE Id IN :documentCategoryIds
        ]);
    }

    private static List<clcommon__Document_Category__c> buildUpdates(
        Map<Id, clcommon__Document_Category__c> categoriesById,
        Map<Id, Set<Id>> currentDocIdsByCategoryId
    ) {
        List<clcommon__Document_Category__c> updates = new List<clcommon__Document_Category__c>();
        for (clcommon__Document_Category__c category : categoriesById.values()) {
            clcommon__Document_Category__c updateRecord = buildUpdate(category, currentDocIdsByCategoryId.get(category.Id));
            if (updateRecord != null) {
                updates.add(updateRecord);
            }
        }
        return updates;
    }

    private static clcommon__Document_Category__c buildUpdate(
        clcommon__Document_Category__c category,
        Set<Id> currentDocIds
    ) {
        Map<String, Object> feedbackByDocId =
            AIDocReviewFeedbackUtil.parseFeedbackByDocumentId(category.AI_Review_Feedback_JSON__c);
        Map<String, Object> currentFeedbackByDocId =
            AIDocReviewFeedbackUtil.keepCurrentFeedbackEntries(feedbackByDocId, currentDocIds);
        Boolean feedbackChanged = feedbackByDocId.size() != currentFeedbackByDocId.size();
        Boolean allFilesReviewed = AIDocReviewFeedbackUtil.hasReviewForEveryFile(currentFeedbackByDocId, currentDocIds);
        if (category.AI_Reviewed__c == allFilesReviewed && !feedbackChanged) {
            return null;
        }

        clcommon__Document_Category__c updateRecord = new clcommon__Document_Category__c(
            Id = category.Id,
            AI_Reviewed__c = allFilesReviewed
        );
        if (feedbackChanged) {
            updateRecord.AI_Review_Feedback_JSON__c =
                AIDocReviewFeedbackUtil.serializeFeedback(currentFeedbackByDocId);
        }
        return updateRecord;
    }

    private static Boolean isDocumentCategoryLink(ContentDocumentLink link, String categoryPrefix) {
        return link != null
            && link.LinkedEntityId != null
            && String.valueOf(link.LinkedEntityId).startsWith(categoryPrefix);
    }
}

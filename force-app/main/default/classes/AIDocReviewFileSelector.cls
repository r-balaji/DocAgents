/**
 * Selects current AI Document Review files from product category/file association rows.
 *
 * Current membership is defined in one place so coverage counts and stored-review
 * recalculation agree when files are removed, rejected, or left behind as stale rows.
 */
public inherited sharing class AIDocReviewFileSelector {
    private static final String STATUS_SUBMITTED = 'Submitted';
    private static final String STATUS_APPROVED = 'Approved';
    private static final Set<String> CURRENT_ASSOCIATION_STATUSES = new Set<String>{
        STATUS_SUBMITTED,
        STATUS_APPROVED
    };
    private static final String CONTENT_DOCUMENT_PREFIX = ContentDocument.SObjectType
        .getDescribe(SObjectDescribeOptions.DEFERRED)
        .getKeyPrefix();

    /**
     * Selects current live ContentDocument ids grouped by document category using user-mode SOQL.
     * @param categoryIds Document category ids whose current files should be loaded.
     * @return Map keyed by document category id with current live ContentDocument ids.
     */
    public static Map<Id, Set<Id>> selectCurrentContentDocumentIdsByCategoryUserMode(Set<Id> categoryIds) {
        List<clcommon__Category_Attachment_Association__c> associations =
            selectCurrentAssociationsUserMode(categoryIds);
        Set<Id> liveContentDocumentIds = selectLiveContentDocumentIdsUserMode(associations);
        return groupLiveContentDocumentIdsByCategory(associations, liveContentDocumentIds);
    }

    /**
     * Selects current live ContentDocument ids grouped by document category using system-mode SOQL.
     * Intended for trigger recalculation, where the trigger must repair cached review state.
     * @param categoryIds Document category ids whose current files should be loaded.
     * @return Map keyed by document category id with current live ContentDocument ids.
     */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    public static Map<Id, Set<Id>> selectCurrentContentDocumentIdsByCategorySystemMode(Set<Id> categoryIds) {
        List<clcommon__Category_Attachment_Association__c> associations =
            selectCurrentAssociationsSystemMode(categoryIds);
        Set<Id> liveContentDocumentIds = selectLiveContentDocumentIdsSystemMode(associations);
        return groupLiveContentDocumentIdsByCategory(associations, liveContentDocumentIds);
    }

    private static List<clcommon__Category_Attachment_Association__c> selectCurrentAssociationsUserMode(
        Set<Id> categoryIds
    ) {
        if (categoryIds == null || categoryIds.isEmpty()) {
            return new List<clcommon__Category_Attachment_Association__c>();
        }

        return [
            SELECT clcommon__Document_Category__c, clcommon__Content_Document_Id__c
            FROM clcommon__Category_Attachment_Association__c
            WHERE clcommon__Document_Category__c IN :categoryIds
            AND clcommon__Content_Document_Id__c != null
            AND (
                clcommon__Status__c = null
                OR clcommon__Status__c IN :CURRENT_ASSOCIATION_STATUSES
            )
            WITH USER_MODE
        ];
    }

    @SuppressWarnings('PMD.ApexCRUDViolation')
    private static List<clcommon__Category_Attachment_Association__c> selectCurrentAssociationsSystemMode(
        Set<Id> categoryIds
    ) {
        if (categoryIds == null || categoryIds.isEmpty()) {
            return new List<clcommon__Category_Attachment_Association__c>();
        }

        return [
            SELECT clcommon__Document_Category__c, clcommon__Content_Document_Id__c
            FROM clcommon__Category_Attachment_Association__c
            WHERE clcommon__Document_Category__c IN :categoryIds
            AND clcommon__Content_Document_Id__c != null
            AND (
                clcommon__Status__c = null
                OR clcommon__Status__c IN :CURRENT_ASSOCIATION_STATUSES
            )
        ];
    }

    private static Set<Id> selectLiveContentDocumentIdsUserMode(
        List<clcommon__Category_Attachment_Association__c> associations
    ) {
        Set<Id> candidateDocIds = collectCandidateContentDocumentIds(associations);
        Set<Id> liveDocIds = new Set<Id>();
        if (candidateDocIds.isEmpty()) {
            return liveDocIds;
        }

        for (ContentDocument doc : [
            SELECT Id
            FROM ContentDocument
            WHERE Id IN :candidateDocIds
            WITH USER_MODE
        ]) {
            liveDocIds.add(doc.Id);
        }
        return liveDocIds;
    }

    @SuppressWarnings('PMD.ApexCRUDViolation')
    private static Set<Id> selectLiveContentDocumentIdsSystemMode(
        List<clcommon__Category_Attachment_Association__c> associations
    ) {
        Set<Id> candidateDocIds = collectCandidateContentDocumentIds(associations);
        Set<Id> liveDocIds = new Set<Id>();
        if (candidateDocIds.isEmpty()) {
            return liveDocIds;
        }

        for (ContentDocument doc : [
            SELECT Id
            FROM ContentDocument
            WHERE Id IN :candidateDocIds
        ]) {
            liveDocIds.add(doc.Id);
        }
        return liveDocIds;
    }

    private static Map<Id, Set<Id>> groupLiveContentDocumentIdsByCategory(
        List<clcommon__Category_Attachment_Association__c> associations,
        Set<Id> liveContentDocumentIds
    ) {
        Map<Id, Set<Id>> docIdsByCategoryId = new Map<Id, Set<Id>>();
        for (clcommon__Category_Attachment_Association__c association : associations) {
            Id contentDocumentId = parseContentDocumentId(association.clcommon__Content_Document_Id__c);
            if (contentDocumentId == null || !liveContentDocumentIds.contains(contentDocumentId)) {
                continue;
            }

            Id categoryId = association.clcommon__Document_Category__c;
            if (!docIdsByCategoryId.containsKey(categoryId)) {
                docIdsByCategoryId.put(categoryId, new Set<Id>());
            }
            docIdsByCategoryId.get(categoryId).add(contentDocumentId);
        }
        return docIdsByCategoryId;
    }

    private static Set<Id> collectCandidateContentDocumentIds(
        List<clcommon__Category_Attachment_Association__c> associations
    ) {
        Set<Id> candidateDocIds = new Set<Id>();
        for (clcommon__Category_Attachment_Association__c association : associations) {
            Id contentDocumentId = parseContentDocumentId(association.clcommon__Content_Document_Id__c);
            if (contentDocumentId != null) {
                candidateDocIds.add(contentDocumentId);
            }
        }
        return candidateDocIds;
    }

    private static Id parseContentDocumentId(String rawContentDocumentId) {
        if (String.isBlank(rawContentDocumentId)
            || !rawContentDocumentId.startsWith(CONTENT_DOCUMENT_PREFIX)) {
            return null;
        }
        try {
            return (Id) rawContentDocumentId;
        } catch (Exception ignored) {
            return null;
        }
    }
}

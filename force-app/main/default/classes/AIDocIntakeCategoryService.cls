/**
 * Creates fallback document categories and attaches Salesforce Files to them.
 */
@SuppressWarnings('PMD.ApexCRUDViolation,PMD.ExcessiveParameterList')
public with sharing class AIDocIntakeCategoryService {
    private static final String DEFAULT_PARENT_CATEGORY_NAME = 'Uncategorized';
    private static final String DEFAULT_CATEGORY_NAME = 'Others';
    private static final String STATUS_SUBMITTED = 'Submitted';

    /**
     * Ensures the fallback category exists for an application.
     * @param applicationId Application that owns the category.
     * @param categoryName Desired fallback category label.
     * @return Existing or newly-created clcommon__Document_Category__c Id.
     * @throws AIDocIntakeService.IntakeException when applicationId is missing.
     */
    public static Id ensureFallbackCategory(Id applicationId, String categoryName) {
        return ensureFallbackCategory(applicationId, null, categoryName);
    }

    /**
     * Ensures the configured fallback parent/child category path exists for an application.
     * @param applicationId Application that owns the categories.
     * @param parentCategoryName Desired parent category label, usually Uncategorized.
     * @param childCategoryName Desired fallback category label, usually Others.
     * @return Existing or newly-created fallback child category Id.
     * @throws AIDocIntakeService.IntakeException when applicationId is missing.
     */
    public static Id ensureFallbackCategory(
        Id applicationId,
        String parentCategoryName,
        String childCategoryName
    ) {
        if (applicationId == null) {
            throw AIDocIntakeService.error(400, 'Application Id is required.');
        }
        String normalizedChildName = normalizeCategoryName(childCategoryName, DEFAULT_CATEGORY_NAME);
        if (String.isBlank(parentCategoryName)) {
            return ensureCategory(applicationId, null, normalizedChildName, null);
        }

        String normalizedParentName = normalizeCategoryName(parentCategoryName, DEFAULT_PARENT_CATEGORY_NAME);
        Map<String, Id> definitionIdsByName = fallbackDefinitionIdsByName(
            normalizedParentName,
            normalizedChildName
        );
        Id parentCategoryId = ensureCategory(
            applicationId,
            null,
            normalizedParentName,
            definitionIdsByName.get(normalizedParentName)
        );
        return ensureCategory(
            applicationId,
            parentCategoryId,
            normalizedChildName,
            definitionIdsByName.get(normalizedChildName)
        );
    }

    private static Id ensureCategory(Id applicationId, Id parentCategoryId, String categoryName, Id documentDefinitionId) {
        List<clcommon__Document_Category__c> existing;
        if (parentCategoryId == null) {
            existing = [
                SELECT Id
                FROM clcommon__Document_Category__c
                WHERE genesis__Application__c = :applicationId
                AND clcommon__Parent_Document_Category__c = null
                AND clcommon__Category_Name__c = :categoryName
                LIMIT 1
            ];
        } else {
            existing = [
                SELECT Id
                FROM clcommon__Document_Category__c
                WHERE genesis__Application__c = :applicationId
                AND clcommon__Parent_Document_Category__c = :parentCategoryId
                AND clcommon__Category_Name__c = :categoryName
                LIMIT 1
            ];
        }
        if (!existing.isEmpty()) {
            return existing[0].Id;
        }

        clcommon__Document_Category__c category = new clcommon__Document_Category__c(
            genesis__Application__c = applicationId,
            clcommon__Category_Name__c = categoryName,
            clcommon__Parent_Document_Category__c = parentCategoryId
        );
        if (documentDefinitionId != null) {
            category.clcommon__Document_Definition__c = documentDefinitionId;
        }
        insert category;
        return category.Id;
    }

    /**
     * Attaches a file to a document category and maintains the product association row.
     * @param categoryId Document category receiving the file.
     * @param contentDocumentId ContentDocument to attach.
     */
    public static void attachDocumentToCategory(Id categoryId, Id contentDocumentId) {
        if (categoryId == null || contentDocumentId == null) {
            return;
        }

        attachDocumentsToCategories(new Map<Id, Set<Id>>{
            contentDocumentId => new Set<Id>{ categoryId }
        });
    }

    /**
     * Attaches multiple files to their mapped categories with shared queries and bulk DML.
     * @param categoryIdsByContentDocumentId Category ids grouped by ContentDocument id.
     */
    public static void attachDocumentsToCategories(
        Map<Id, Set<Id>> categoryIdsByContentDocumentId
    ) {
        Map<Id, Set<Id>> normalizedMappings = normalizeMappings(categoryIdsByContentDocumentId);
        if (normalizedMappings.isEmpty()) {
            return;
        }

        Set<Id> contentDocumentIds = normalizedMappings.keySet();
        Set<Id> categoryIds = collectCategoryIds(normalizedMappings);
        Map<Id, ContentVersion> latestVersionsByDocumentId = latestContentVersions(contentDocumentIds);
        Map<String, Id> linkIdsByPair = existingContentDocumentLinkIds(categoryIds, contentDocumentIds);
        insertMissingContentDocumentLinks(
            normalizedMappings,
            latestVersionsByDocumentId,
            linkIdsByPair
        );
        saveCategoryAssociations(
            normalizedMappings,
            latestVersionsByDocumentId,
            linkIdsByPair,
            categoryIds,
            contentDocumentIds
        );
    }

    private static String normalizeCategoryName(String categoryName, String defaultName) {
        String normalized = String.isBlank(categoryName) ? defaultName : categoryName.trim();
        return normalized.left(255);
    }

    private static Map<String, Id> fallbackDefinitionIdsByName(String parentName, String childName) {
        Map<String, Id> definitionIdsByName = new Map<String, Id>();
        Set<String> names = new Set<String>{ parentName, childName };
        for (clcommon__Document_Definition__c definition : [
            SELECT Id, Name, clcommon__Parent_Document_Definition__c
            FROM clcommon__Document_Definition__c
            WHERE Name IN :names
            ORDER BY CreatedDate ASC
            LIMIT 20
        ]) {
            if (!definitionIdsByName.containsKey(definition.Name)) {
                definitionIdsByName.put(definition.Name, definition.Id);
            }
        }
        return definitionIdsByName;
    }

    private static Map<Id, Set<Id>> normalizeMappings(
        Map<Id, Set<Id>> categoryIdsByContentDocumentId
    ) {
        Map<Id, Set<Id>> normalized = new Map<Id, Set<Id>>();
        if (categoryIdsByContentDocumentId == null || categoryIdsByContentDocumentId.isEmpty()) {
            return normalized;
        }
        for (Id contentDocumentId : categoryIdsByContentDocumentId.keySet()) {
            Set<Id> requestedCategoryIds = categoryIdsByContentDocumentId.get(contentDocumentId);
            if (contentDocumentId == null || requestedCategoryIds == null || requestedCategoryIds.isEmpty()) {
                continue;
            }
            Set<Id> categoryIds = new Set<Id>();
            for (Id categoryId : requestedCategoryIds) {
                if (categoryId != null) {
                    categoryIds.add(categoryId);
                }
            }
            if (!categoryIds.isEmpty()) {
                normalized.put(contentDocumentId, categoryIds);
            }
        }
        return normalized;
    }

    private static Set<Id> collectCategoryIds(Map<Id, Set<Id>> mappings) {
        Set<Id> categoryIds = new Set<Id>();
        for (Set<Id> mappedCategoryIds : mappings.values()) {
            categoryIds.addAll(mappedCategoryIds);
        }
        return categoryIds;
    }

    private static Map<Id, ContentVersion> latestContentVersions(Set<Id> contentDocumentIds) {
        Map<Id, ContentVersion> versionsByDocumentId = new Map<Id, ContentVersion>();
        for (ContentVersion version : [
            SELECT Id, ContentDocumentId, Title, FileExtension
            FROM ContentVersion
            WHERE ContentDocumentId IN :contentDocumentIds
            AND IsLatest = true
        ]) {
            versionsByDocumentId.put(version.ContentDocumentId, version);
        }
        return versionsByDocumentId;
    }

    private static Map<String, Id> existingContentDocumentLinkIds(
        Set<Id> categoryIds,
        Set<Id> contentDocumentIds
    ) {
        Map<String, Id> linkIdsByPair = new Map<String, Id>();
        for (ContentDocumentLink link : [
            SELECT Id, LinkedEntityId, ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :categoryIds
            AND ContentDocumentId IN :contentDocumentIds
        ]) {
            linkIdsByPair.put(pairKey(link.LinkedEntityId, link.ContentDocumentId), link.Id);
        }
        return linkIdsByPair;
    }

    private static void insertMissingContentDocumentLinks(
        Map<Id, Set<Id>> mappings,
        Map<Id, ContentVersion> latestVersionsByDocumentId,
        Map<String, Id> linkIdsByPair
    ) {
        List<ContentDocumentLink> linksToInsert = new List<ContentDocumentLink>();
        List<String> keysToInsert = new List<String>();
        for (Id contentDocumentId : mappings.keySet()) {
            if (!latestVersionsByDocumentId.containsKey(contentDocumentId)) {
                continue;
            }
            for (Id categoryId : mappings.get(contentDocumentId)) {
                String key = pairKey(categoryId, contentDocumentId);
                if (linkIdsByPair.containsKey(key)) {
                    continue;
                }
                linksToInsert.add(new ContentDocumentLink(
                    LinkedEntityId = categoryId,
                    ContentDocumentId = contentDocumentId,
                    ShareType = 'V',
                    Visibility = 'AllUsers'
                ));
                keysToInsert.add(key);
            }
        }
        if (linksToInsert.isEmpty()) {
            return;
        }

        Database.insert(linksToInsert, AccessLevel.USER_MODE);
        for (Integer i = 0; i < linksToInsert.size(); i++) {
            linkIdsByPair.put(keysToInsert[i], linksToInsert[i].Id);
        }
    }

    private static void saveCategoryAssociations(
        Map<Id, Set<Id>> mappings,
        Map<Id, ContentVersion> latestVersionsByDocumentId,
        Map<String, Id> linkIdsByPair,
        Set<Id> categoryIds,
        Set<Id> contentDocumentIds
    ) {
        Set<String> contentDocumentIdTexts = new Set<String>();
        for (Id contentDocumentId : contentDocumentIds) {
            contentDocumentIdTexts.add(String.valueOf(contentDocumentId));
        }

        Map<String, clcommon__Category_Attachment_Association__c> associationsByPair =
            new Map<String, clcommon__Category_Attachment_Association__c>();
        for (clcommon__Category_Attachment_Association__c association : [
            SELECT Id, Name, clcommon__Status__c, clcommon__Document_Category__c,
                   clcommon__Content_Document_Id__c
            FROM clcommon__Category_Attachment_Association__c
            WHERE clcommon__Document_Category__c IN :categoryIds
            AND clcommon__Content_Document_Id__c IN :contentDocumentIdTexts
        ]) {
            String key = pairKey(
                association.clcommon__Document_Category__c,
                (Id) association.clcommon__Content_Document_Id__c
            );
            if (!associationsByPair.containsKey(key)) {
                associationsByPair.put(key, association);
            }
        }

        List<clcommon__Category_Attachment_Association__c> associationsToInsert =
            new List<clcommon__Category_Attachment_Association__c>();
        List<clcommon__Category_Attachment_Association__c> associationsToUpdate =
            new List<clcommon__Category_Attachment_Association__c>();
        for (Id contentDocumentId : mappings.keySet()) {
            ContentVersion version = latestVersionsByDocumentId.get(contentDocumentId);
            if (version == null) {
                continue;
            }
            String contentDocumentIdText = String.valueOf(contentDocumentId);
            String associationName = AIDocFileNameUtil.associationNameFor(
                AIDocFileNameUtil.fileNameFor(version.Title, version.FileExtension)
            );
            for (Id categoryId : mappings.get(contentDocumentId)) {
                String key = pairKey(categoryId, contentDocumentId);
                clcommon__Category_Attachment_Association__c existing = associationsByPair.get(key);
                if (existing != null) {
                    if (existing.clcommon__Status__c != STATUS_SUBMITTED || existing.Name != associationName) {
                        existing.clcommon__Status__c = STATUS_SUBMITTED;
                        existing.Name = associationName;
                        associationsToUpdate.add(existing);
                    }
                    continue;
                }

                Id contentDocumentLinkId = linkIdsByPair.get(key);
                if (contentDocumentLinkId == null) {
                    continue;
                }
                associationsToInsert.add(new clcommon__Category_Attachment_Association__c(
                    Name = associationName,
                    clcommon__Document_Category__c = categoryId,
                    clcommon__Attachment_Id__c = contentDocumentLinkId,
                    clcommon__Content_Document_Id__c = contentDocumentIdText,
                    clcommon__Content_Version_Id__c = String.valueOf(version.Id),
                    clcommon__Status__c = STATUS_SUBMITTED
                ));
            }
        }

        if (!associationsToUpdate.isEmpty()) {
            Database.update(associationsToUpdate, AccessLevel.USER_MODE);
        }
        if (!associationsToInsert.isEmpty()) {
            Database.insert(associationsToInsert, AccessLevel.USER_MODE);
        }
    }

    private static String pairKey(Id categoryId, Id contentDocumentId) {
        return String.valueOf(categoryId) + ':' + String.valueOf(contentDocumentId);
    }

}

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
        ContentVersion latestVersion = latestContentVersion(contentDocumentId);
        if (latestVersion == null) {
            return;
        }

        Id contentDocumentLinkId = ensureContentDocumentLink(categoryId, contentDocumentId);
        ensureCategoryAssociation(
            categoryId,
            contentDocumentId,
            latestVersion.Id,
            contentDocumentLinkId,
            AIDocFileNameUtil.fileNameFor(latestVersion.Title, latestVersion.FileExtension)
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

    private static ContentVersion latestContentVersion(Id contentDocumentId) {
        List<ContentVersion> versions = [
            SELECT Id, Title, FileExtension
            FROM ContentVersion
            WHERE ContentDocumentId = :contentDocumentId
            AND IsLatest = true
            LIMIT 1
        ];
        return versions.isEmpty() ? null : versions[0];
    }

    private static Id ensureContentDocumentLink(Id categoryId, Id contentDocumentId) {
        List<ContentDocumentLink> existing = [
            SELECT Id
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :categoryId
            AND ContentDocumentId = :contentDocumentId
            LIMIT 1
        ];
        if (!existing.isEmpty()) {
            return existing[0].Id;
        }

        ContentDocumentLink link = new ContentDocumentLink(
            LinkedEntityId = categoryId,
            ContentDocumentId = contentDocumentId,
            ShareType = 'V',
            Visibility = 'AllUsers'
        );
        insert link;
        return link.Id;
    }

    private static void ensureCategoryAssociation(
        Id categoryId,
        Id contentDocumentId,
        Id contentVersionId,
        Id contentDocumentLinkId,
        String fileName
    ) {
        String contentDocumentIdText = String.valueOf(contentDocumentId);
        List<clcommon__Category_Attachment_Association__c> existing = [
            SELECT Id, Name, clcommon__Status__c
            FROM clcommon__Category_Attachment_Association__c
            WHERE clcommon__Document_Category__c = :categoryId
            AND clcommon__Content_Document_Id__c = :contentDocumentIdText
            LIMIT 1
        ];
        String associationName = AIDocFileNameUtil.associationNameFor(fileName);
        if (!existing.isEmpty()) {
            clcommon__Category_Attachment_Association__c association = existing[0];
            if (association.clcommon__Status__c != STATUS_SUBMITTED || association.Name != associationName) {
                association.clcommon__Status__c = STATUS_SUBMITTED;
                association.Name = associationName;
                update association;
            }
            return;
        }

        insert new clcommon__Category_Attachment_Association__c(
            Name = associationName,
            clcommon__Document_Category__c = categoryId,
            clcommon__Attachment_Id__c = contentDocumentLinkId,
            clcommon__Content_Document_Id__c = contentDocumentIdText,
            clcommon__Content_Version_Id__c = String.valueOf(contentVersionId),
            clcommon__Status__c = STATUS_SUBMITTED
        );
    }

}

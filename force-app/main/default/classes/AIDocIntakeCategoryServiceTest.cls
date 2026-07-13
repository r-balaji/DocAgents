/**
 * Tests fallback category creation and file association for document intake.
 */
@IsTest
private class AIDocIntakeCategoryServiceTest {
    @IsTest
    static void shouldReuseFallbackCategoryWhenItAlreadyExists() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);

        Id firstId = AIDocIntakeCategoryService.ensureFallbackCategory(app.Id, 'Uncategorized', 'Others');
        Id secondId = AIDocIntakeCategoryService.ensureFallbackCategory(app.Id, 'Uncategorized', 'Others');

        Assert.areEqual(firstId, secondId, 'fallback category creation should be idempotent');
        Assert.areEqual(1, [
            SELECT COUNT()
            FROM clcommon__Document_Category__c
            WHERE genesis__Application__c = :app.Id
            AND clcommon__Category_Name__c = 'Others'
        ], 'only one Others category should exist for the application');
        Assert.areEqual(1, [
            SELECT COUNT()
            FROM clcommon__Document_Category__c
            WHERE genesis__Application__c = :app.Id
            AND clcommon__Category_Name__c = 'Uncategorized'
            AND clcommon__Parent_Document_Category__c = null
        ], 'one Uncategorized parent category should exist for the application');
    }

    @IsTest
    static void shouldAttachDocumentToFallbackCategoryOnce() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        Id categoryId = AIDocIntakeCategoryService.ensureFallbackCategory(app.Id, 'Uncategorized', null);
        Id contentDocumentId = createContentDocument('fallback_file');
        String contentDocumentIdText = String.valueOf(contentDocumentId);

        AIDocIntakeCategoryService.attachDocumentToCategory(categoryId, contentDocumentId);
        AIDocIntakeCategoryService.attachDocumentToCategory(categoryId, contentDocumentId);

        Assert.areEqual(1, [
            SELECT COUNT()
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :categoryId
            AND ContentDocumentId = :contentDocumentId
        ], 'file should be linked to the fallback category once');
        List<clcommon__Category_Attachment_Association__c> associations = [
            SELECT Name
            FROM clcommon__Category_Attachment_Association__c
            WHERE clcommon__Document_Category__c = :categoryId
            AND clcommon__Content_Document_Id__c = :contentDocumentIdText
            AND clcommon__Status__c = 'Submitted'
        ];
        Assert.areEqual(1, associations.size(), 'product category association should be current and unique');
        Assert.areEqual('fallback_file.pdf', associations[0].Name,
            'product category association should display the file name');
    }

    @IsTest
    static void shouldAttachMultipleDocumentsWithBulkPlacement() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        List<clcommon__Document_Category__c> categories =
            AIDocTestFactory.createCategories(app.Id, 2, true);
        List<Id> contentDocumentIds = createContentDocuments(12);
        Map<Id, Set<Id>> categoryIdsByContentDocumentId = new Map<Id, Set<Id>>();
        for (Integer i = 0; i < contentDocumentIds.size(); i++) {
            categoryIdsByContentDocumentId.put(
                contentDocumentIds[i],
                new Set<Id>{ categories[Math.mod(i, categories.size())].Id }
            );
        }

        Test.startTest();
        AIDocIntakeCategoryService.attachDocumentsToCategories(categoryIdsByContentDocumentId);
        AIDocIntakeCategoryService.attachDocumentsToCategories(categoryIdsByContentDocumentId);
        Test.stopTest();

        Set<Id> categoryIds = new Map<Id, clcommon__Document_Category__c>(categories).keySet();
        Set<String> contentDocumentIdTexts = new Set<String>();
        for (Id contentDocumentId : contentDocumentIds) {
            contentDocumentIdTexts.add(String.valueOf(contentDocumentId));
        }
        Assert.areEqual(12, [
            SELECT COUNT()
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :categoryIds
            AND ContentDocumentId IN :contentDocumentIds
        ], 'bulk placement should create one category link per file');
        Assert.areEqual(12, [
            SELECT COUNT()
            FROM clcommon__Category_Attachment_Association__c
            WHERE clcommon__Document_Category__c IN :categoryIds
            AND clcommon__Content_Document_Id__c IN :contentDocumentIdTexts
            AND clcommon__Status__c = 'Submitted'
        ], 'bulk placement should create one current product association per file');
    }

    private static Id createContentDocument(String title) {
        ContentVersion version = new ContentVersion(
            Title = title,
            PathOnClient = title + '.pdf',
            VersionData = Blob.valueOf('PDF-BYTES-' + title),
            IsMajorVersion = true
        );
        insert version;
        return [
            SELECT ContentDocumentId
            FROM ContentVersion
            WHERE Id = :version.Id
            LIMIT 1
        ].ContentDocumentId;
    }

    private static List<Id> createContentDocuments(Integer count) {
        List<ContentVersion> versions = new List<ContentVersion>();
        for (Integer i = 0; i < count; i++) {
            String title = 'bulk_file_' + i;
            versions.add(new ContentVersion(
                Title = title,
                PathOnClient = title + '.pdf',
                VersionData = Blob.valueOf('PDF-BYTES-' + title),
                IsMajorVersion = true
            ));
        }
        insert versions;

        Set<Id> versionIds = new Map<Id, ContentVersion>(versions).keySet();
        List<Id> contentDocumentIds = new List<Id>();
        for (ContentVersion version : [
            SELECT ContentDocumentId
            FROM ContentVersion
            WHERE Id IN :versionIds
            ORDER BY Title ASC
        ]) {
            contentDocumentIds.add(version.ContentDocumentId);
        }
        return contentDocumentIds;
    }
}

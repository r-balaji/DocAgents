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
}

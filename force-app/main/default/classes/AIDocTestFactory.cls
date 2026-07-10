/**
 * @description Centralized factory for AI Doc test data.
 *              Creates genesis__Applications__c, clcommon__Document_Category__c,
 *              and attaches ContentDocuments via product category associations.
 */
@isTest
public class AIDocTestFactory {

    // ─── Applications ─────────────────────────────────────────────────────

    public static genesis__Applications__c createApplication(Boolean doInsert) {
        genesis__Applications__c app = new genesis__Applications__c();
        if (doInsert) insert app;
        return app;
    }

    // ─── Document Categories ──────────────────────────────────────────────

    public static List<clcommon__Document_Category__c> createCategories(
        Id applicationId, Integer leafCount, Boolean doInsert
    ) {
        clcommon__Document_Category__c parent = new clcommon__Document_Category__c(
            clcommon__Category_Name__c = 'Group ' + System.currentTimeMillis(),
            genesis__Application__c = applicationId
        );
        insert parent;

        List<clcommon__Document_Category__c> leaves = new List<clcommon__Document_Category__c>();
        for (Integer i = 0; i < leafCount; i++) {
            leaves.add(new clcommon__Document_Category__c(
                clcommon__Category_Name__c = 'Doc ' + i + '-' + System.currentTimeMillis(),
                genesis__Application__c = applicationId,
                clcommon__Parent_Document_Category__c = parent.Id
            ));
        }
        if (doInsert && !leaves.isEmpty()) insert leaves;
        return leaves;
    }

    // ─── Files (ContentDocument via ContentVersion) ───────────────────────

    public static ContentDocumentLink attachFile(Id linkedEntityId, String title) {
        ContentVersion cv = new ContentVersion(
            Title = title,
            PathOnClient = title + '.pdf',
            VersionData = Blob.valueOf('PDF-BYTES-' + title),
            IsMajorVersion = true
        );
        insert cv;
        ContentVersion fresh = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id];

        ContentDocumentLink l = new ContentDocumentLink(
            ContentDocumentId = fresh.ContentDocumentId,
            LinkedEntityId = linkedEntityId,
            ShareType = 'V',
            Visibility = 'AllUsers'
        );
        insert l;

        insert new clcommon__Category_Attachment_Association__c(
            Name = (title + '.pdf').left(80),
            clcommon__Document_Category__c = linkedEntityId,
            clcommon__Attachment_Id__c = l.Id,
            clcommon__Content_Document_Id__c = fresh.ContentDocumentId,
            clcommon__Content_Version_Id__c = cv.Id,
            clcommon__Status__c = 'Submitted'
        );
        return l;
    }
}

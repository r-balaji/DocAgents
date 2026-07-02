/**
 * Tests current-file selection for AI Document Review.
 */
@IsTest
private class AIDocReviewFileSelectorTest {
    @IsTest
    static void shouldReturnSubmittedAndApprovedFiles_WhenRowsAreCurrent() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        List<clcommon__Document_Category__c> leaves =
            AIDocTestFactory.createCategories(app.Id, 1, true);
        ContentDocumentLink submittedLink = AIDocTestFactory.attachFile(leaves[0].Id, 'submitted_file');
        ContentDocumentLink approvedLink = AIDocTestFactory.attachFile(leaves[0].Id, 'approved_file');
        updateAssociationStatus(leaves[0].Id, approvedLink.ContentDocumentId, 'Approved');

        Test.startTest();
        Map<Id, Set<Id>> selected =
            AIDocReviewFileSelector.selectCurrentContentDocumentIdsByCategoryUserMode(new Set<Id>{ leaves[0].Id });
        Test.stopTest();

        Assert.areEqual(2, selected.get(leaves[0].Id).size(), 'submitted and approved files are current');
        Assert.isTrue(selected.get(leaves[0].Id).contains(submittedLink.ContentDocumentId),
            'submitted file should be selected');
        Assert.isTrue(selected.get(leaves[0].Id).contains(approvedLink.ContentDocumentId),
            'approved file should be selected');
    }

    @IsTest
    static void shouldIgnoreRejectedFiles_WhenProductKeepsInactiveAssociation() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        List<clcommon__Document_Category__c> leaves =
            AIDocTestFactory.createCategories(app.Id, 1, true);
        ContentDocumentLink rejectedLink = AIDocTestFactory.attachFile(leaves[0].Id, 'rejected_file');
        updateAssociationStatus(leaves[0].Id, rejectedLink.ContentDocumentId, 'Rejected');

        Test.startTest();
        Map<Id, Set<Id>> selected =
            AIDocReviewFileSelector.selectCurrentContentDocumentIdsByCategoryUserMode(new Set<Id>{ leaves[0].Id });
        Test.stopTest();

        Assert.isFalse(selected.containsKey(leaves[0].Id), 'rejected association should not count as current');
    }

    @IsTest
    static void shouldIgnoreStaleRows_WhenContentDocumentNoLongerExists() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        List<clcommon__Document_Category__c> leaves =
            AIDocTestFactory.createCategories(app.Id, 1, true);
        insert new clcommon__Category_Attachment_Association__c(
            clcommon__Document_Category__c = leaves[0].Id,
            clcommon__Attachment_Id__c = 'stale-link',
            clcommon__Content_Document_Id__c = staleContentDocumentId(),
            clcommon__Status__c = 'Submitted'
        );

        Test.startTest();
        Map<Id, Set<Id>> selected =
            AIDocReviewFileSelector.selectCurrentContentDocumentIdsByCategorySystemMode(new Set<Id>{ leaves[0].Id });
        Test.stopTest();

        Assert.isFalse(selected.containsKey(leaves[0].Id), 'missing ContentDocument should not count as current');
    }

    @IsTest
    static void shouldReturnEmpty_WhenInputsAreEmpty() {
        Test.startTest();
        Map<Id, Set<Id>> userModeSelected =
            AIDocReviewFileSelector.selectCurrentContentDocumentIdsByCategoryUserMode(new Set<Id>());
        Map<Id, Set<Id>> systemModeSelected =
            AIDocReviewFileSelector.selectCurrentContentDocumentIdsByCategorySystemMode(null);
        Test.stopTest();

        Assert.isTrue(userModeSelected.isEmpty(), 'empty user-mode input returns empty map');
        Assert.isTrue(systemModeSelected.isEmpty(), 'null system-mode input returns empty map');
    }

    private static void updateAssociationStatus(Id categoryId, Id contentDocumentId, String status) {
        clcommon__Category_Attachment_Association__c association = [
            SELECT Id, clcommon__Status__c
            FROM clcommon__Category_Attachment_Association__c
            WHERE clcommon__Document_Category__c = :categoryId
            AND clcommon__Content_Document_Id__c = :contentDocumentId
            LIMIT 1
        ];
        association.clcommon__Status__c = status;
        update association;
    }

    private static String staleContentDocumentId() {
        return ContentDocument.SObjectType
            .getDescribe(SObjectDescribeOptions.DEFERRED)
            .getKeyPrefix() + String.valueOf(UserInfo.getOrganizationId()).right(12);
    }
}

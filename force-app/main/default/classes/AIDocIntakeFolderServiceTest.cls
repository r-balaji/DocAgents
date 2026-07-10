/**
 * Tests folder path behavior for document intake.
 */
@IsTest
private class AIDocIntakeFolderServiceTest {
    @IsTest
    static void shouldCreateApplicationFolderUnderConfiguredPath() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        AIDocIntakeFolderService.testRootFolderIdOverride = fakeFolderId(900);
        AIDocIntakeFolderService.testBypassFolderDml = true;

        Id folderId = AIDocIntakeFolderService.ensureApplicationFolder(
            fakeLibraryId(),
            app.Id,
            null,
            'Portal Intake/Submissions'
        );
        Id retryFolderId = AIDocIntakeFolderService.ensureApplicationFolder(
            fakeLibraryId(),
            app.Id,
            null,
            'Portal Intake/Submissions'
        );

        Assert.areEqual(folderId, retryFolderId, 'application folder should be reused');
        Assert.areEqual(3, AIDocIntakeFolderService.testFolderIdsByKey.size(),
            'base path plus application folder should be resolved');
    }

    @IsTest
    static void shouldRejectConfiguredPathWithTooManySegments() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        AIDocIntakeFolderService.testRootFolderIdOverride = fakeFolderId(901);
        AIDocIntakeFolderService.testBypassFolderDml = true;

        try {
            AIDocIntakeFolderService.ensureApplicationFolder(
                fakeLibraryId(),
                app.Id,
                null,
                'a/b/c/d/e/f'
            );
            Assert.fail('Expected too many folder path segments to be rejected');
        } catch (AIDocIntakeService.IntakeException e) {
            Assert.isTrue(e.getMessage().contains('at most 5 segments'),
                'exception should explain the folder path limit');
        }
    }

    @IsTest
    static void shouldNoopMoveDocumentToFolderInTests() {
        AIDocIntakeFolderService.testBypassFolderDml = true;
        Id contentDocumentId = fakeContentDocumentId();
        Id originalFolderId = fakeFolderId(902);
        Id targetFolderId = fakeFolderId(903);
        AIDocIntakeFolderService.testFolderIdByDocumentId.put(contentDocumentId, originalFolderId);

        AIDocIntakeFolderService.moveDocumentToFolder(contentDocumentId, targetFolderId);
        AIDocIntakeFolderService.moveDocumentToFolder(contentDocumentId, targetFolderId);

        Assert.areEqual(targetFolderId, AIDocIntakeFolderService.testFolderIdByDocumentId.get(contentDocumentId),
            'test movement should update the tracked folder id');
        Assert.areEqual(1, AIDocIntakeFolderService.testMoveCount,
            'moving to the same folder twice should only perform one update');
    }

    @IsTest
    static void shouldRejectMissingLibraryId() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);

        try {
            AIDocIntakeFolderService.ensureApplicationFolder(null, app.Id, null, null);
            Assert.fail('Expected missing library id to be rejected');
        } catch (AIDocIntakeService.IntakeException e) {
            Assert.isTrue(e.getMessage().contains('library is not configured'),
                'exception should explain missing library configuration');
        }
    }

    @IsTest
    static void shouldRejectMissingApplicationId() {
        try {
            AIDocIntakeFolderService.ensureApplicationFolder(fakeLibraryId(), null, null, null);
            Assert.fail('Expected missing application id to be rejected');
        } catch (AIDocIntakeService.IntakeException e) {
            Assert.isTrue(e.getMessage().contains('Application Id is required'),
                'exception should explain missing application id');
        }
    }

    @IsTest
    static void shouldRejectUnknownLibraryWhenNoTestRootIsProvided() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);

        try {
            AIDocIntakeFolderService.ensureApplicationFolder(fakeLibraryId(), app.Id, null, null);
            Assert.fail('Expected unknown library to be rejected');
        } catch (AIDocIntakeService.IntakeException e) {
            Assert.isTrue(e.getMessage().contains('library was not found'),
                'exception should explain missing library');
        }
    }

    private static Id fakeLibraryId() {
        return (Id) (ContentWorkspace.SObjectType
            .getDescribe(SObjectDescribeOptions.DEFERRED)
            .getKeyPrefix() + String.valueOf(UserInfo.getOrganizationId()).right(12));
    }

    private static Id fakeFolderId(Integer index) {
        Integer safeIndex = index == null || index < 0 ? 0 : index;
        if (safeIndex > 999) {
            safeIndex = 999;
        }
        String ordinal = String.valueOf(safeIndex).leftPad(3, '0');
        return (Id) (ContentFolder.SObjectType
            .getDescribe(SObjectDescribeOptions.DEFERRED)
            .getKeyPrefix() + ordinal + String.valueOf(UserInfo.getOrganizationId()).right(9));
    }

    private static Id fakeContentDocumentId() {
        return (Id) (ContentDocument.SObjectType
            .getDescribe(SObjectDescribeOptions.DEFERRED)
            .getKeyPrefix() + String.valueOf(UserInfo.getOrganizationId()).right(12));
    }
}

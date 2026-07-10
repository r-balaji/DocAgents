/**
 * Resolves and manages Salesforce Files folders for portal document intake.
 */
@SuppressWarnings('PMD.CyclomaticComplexity,PMD.ExcessiveParameterList')
public with sharing class AIDocIntakeFolderService {
    private static final Integer MAX_FOLDER_NAME_LENGTH = 255;
    private static final Integer MAX_CONFIGURED_PATH_SEGMENTS = 5;

    @TestVisible
    private static Id testRootFolderIdOverride;

    @TestVisible
    private static Boolean testBypassFolderDml = false;

    @TestVisible
    private static Map<String, Id> testFolderIdsByKey = new Map<String, Id>();

    @TestVisible
    private static Map<Id, Id> testFolderIdByDocumentId = new Map<Id, Id>();

    @TestVisible
    private static Integer testMoveCount = 0;

    /**
     * Ensures an application-specific folder exists inside the configured library.
     * @param libraryId ContentWorkspace Id that owns the folder tree.
     * @param applicationId Application whose files are being submitted.
     * @param configuredFolderName Optional base folder name from intake metadata.
     * @param configuredFolderPath Optional slash-delimited base folder path from intake metadata.
     * @return ContentFolder Id for the application folder.
     * @throws AIDocIntakeService.IntakeException when the library or application cannot be resolved.
     */
    public static Id ensureApplicationFolder(
        Id libraryId,
        Id applicationId,
        String configuredFolderName,
        String configuredFolderPath
    ) {
        if (libraryId == null) {
            throw AIDocIntakeService.error(500, 'Document intake library is not configured.');
        }
        if (applicationId == null) {
            throw AIDocIntakeService.error(400, 'Application Id is required.');
        }

        Id rootFolderId = testRootFolderIdOverride == null
            ? loadLibrary(libraryId).RootContentFolderId
            : testRootFolderIdOverride;
        String applicationFolderName = buildApplicationFolderName(applicationId);
        List<String> pathSegments = buildConfiguredPath(configuredFolderName, configuredFolderPath);
        pathSegments.add(applicationFolderName);
        return ensureFolderPath(rootFolderId, pathSegments);
    }

    /**
     * Moves a file from the library root into a target folder.
     * @param contentDocumentId ContentDocument to move.
     * @param folderId ContentFolder destination.
     */
    public static void moveDocumentToFolder(Id contentDocumentId, Id folderId) {
        if (contentDocumentId == null || folderId == null) {
            return;
        }
        if (Test.isRunningTest() && testBypassFolderDml) {
            moveDocumentToFolderForTest(contentDocumentId, folderId);
            return;
        }

        List<ContentFolderMember> memberships = [
            SELECT Id, ParentContentFolderId
            FROM ContentFolderMember
            WHERE ChildRecordId = :contentDocumentId
            WITH USER_MODE
            LIMIT 1
        ];
        if (memberships.isEmpty()) {
            return;
        }

        ContentFolderMember member = memberships[0];
        if (member.ParentContentFolderId == folderId) {
            return;
        }
        member.ParentContentFolderId = folderId;
        Database.update(member, AccessLevel.USER_MODE);
    }

    private static void moveDocumentToFolderForTest(Id contentDocumentId, Id folderId) {
        if (!testFolderIdByDocumentId.containsKey(contentDocumentId)) {
            return;
        }
        if (testFolderIdByDocumentId.get(contentDocumentId) == folderId) {
            return;
        }
        testFolderIdByDocumentId.put(contentDocumentId, folderId);
        testMoveCount++;
    }

    private static ContentWorkspace loadLibrary(Id libraryId) {
        List<ContentWorkspace> libraries = [
            SELECT Id, RootContentFolderId
            FROM ContentWorkspace
            WHERE Id = :libraryId
            WITH USER_MODE
            LIMIT 1
        ];
        if (libraries.isEmpty()) {
            throw AIDocIntakeService.error(404, 'Configured document intake library was not found.');
        }
        if (libraries[0].RootContentFolderId == null) {
            throw AIDocIntakeService.error(500, 'Configured document intake library has no root folder.');
        }
        return libraries[0];
    }

    private static String buildApplicationFolderName(Id applicationId) {
        List<genesis__Applications__c> applications = [
            SELECT Id, Name
            FROM genesis__Applications__c
            WHERE Id = :applicationId
            WITH USER_MODE
            LIMIT 1
        ];
        if (applications.isEmpty()) {
            throw AIDocIntakeService.error(404, 'Application was not found.');
        }

        String rawName = String.isBlank(applications[0].Name)
            ? String.valueOf(applicationId)
            : applications[0].Name;
        return sanitizeFolderName(rawName);
    }

    private static List<String> buildConfiguredPath(String configuredFolderName, String configuredFolderPath) {
        String rawPath = String.isBlank(configuredFolderPath) ? configuredFolderName : configuredFolderPath;
        List<String> segments = new List<String>();
        if (String.isBlank(rawPath)) {
            return segments;
        }

        for (String rawSegment : rawPath.split('/')) {
            if (segments.size() >= MAX_CONFIGURED_PATH_SEGMENTS) {
                throw AIDocIntakeService.error(400, 'Target folder path can include at most 5 segments.');
            }
            String segment = sanitizeFolderName(rawSegment);
            if (!String.isBlank(segment)) {
                segments.add(segment);
            }
        }
        return segments;
    }

    private static Id ensureFolderPath(Id rootFolderId, List<String> pathSegments) {
        Id parentFolderId = rootFolderId;
        for (String segment : pathSegments) {
            parentFolderId = ensureChildFolder(parentFolderId, segment);
        }
        return parentFolderId;
    }

    private static Id ensureChildFolder(Id parentFolderId, String folderName) {
        List<ContentFolder> existing = selectChildFolders(parentFolderId, folderName);
        if (!existing.isEmpty()) {
            return existing[0].Id;
        }

        try {
            ContentFolder folder = new ContentFolder(
                Name = folderName,
                ParentContentFolderId = parentFolderId
            );
            return insertChildFolder(folder);
        } catch (DmlException e) {
            List<ContentFolder> retry = selectChildFolders(parentFolderId, folderName);
            if (!retry.isEmpty()) {
                return retry[0].Id;
            }
            throw AIDocIntakeService.error(500, 'Unable to create the application intake folder.');
        }
    }

    private static List<ContentFolder> selectChildFolders(Id parentFolderId, String folderName) {
        if (Test.isRunningTest() && testBypassFolderDml) {
            String key = folderKey(parentFolderId, folderName);
            if (!testFolderIdsByKey.containsKey(key)) {
                return new List<ContentFolder>();
            }
            return new List<ContentFolder>{
                new ContentFolder(Id = testFolderIdsByKey.get(key))
            };
        }

        return [
            SELECT Id
            FROM ContentFolder
            WHERE ParentContentFolderId = :parentFolderId
            AND Name = :folderName
            WITH USER_MODE
            ORDER BY CreatedDate ASC
            LIMIT 1
        ];
    }

    private static Id insertChildFolder(ContentFolder folder) {
        if (Test.isRunningTest() && testBypassFolderDml) {
            String key = folderKey(folder.ParentContentFolderId, folder.Name);
            if (!testFolderIdsByKey.containsKey(key)) {
                testFolderIdsByKey.put(key, fakeFolderId(testFolderIdsByKey.size()));
            }
            return testFolderIdsByKey.get(key);
        }

        Database.insert(folder, AccessLevel.USER_MODE);
        return folder.Id;
    }

    private static String folderKey(Id parentFolderId, String folderName) {
        return String.valueOf(parentFolderId) + '/' + folderName;
    }

    private static String sanitizeFolderName(String rawName) {
        String name = String.isBlank(rawName) ? 'Application' : rawName.trim();
        name = name.replaceAll('[\\\\/:*?"<>|]', '-');
        name = name.replaceAll('\\s+', ' ');
        if (String.isBlank(name)) {
            name = 'Application';
        }
        return name.left(MAX_FOLDER_NAME_LENGTH);
    }

    private static Id fakeFolderId(Integer index) {
        Integer safeIndex = index == null || index < 0 ? 0 : index;
        if (safeIndex > 999) {
            safeIndex = 999;
        }
        String ordinal = String.valueOf(safeIndex).leftPad(3, '0');
        String rawId = ContentFolder.SObjectType
            .getDescribe(SObjectDescribeOptions.DEFERRED)
            .getKeyPrefix() + ordinal + String.valueOf(UserInfo.getOrganizationId()).right(9);
        return (Id) rawId;
    }
}

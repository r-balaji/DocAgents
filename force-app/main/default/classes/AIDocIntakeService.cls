/**
 * Service layer for document intake submissions.
 */
@SuppressWarnings('PMD.CognitiveComplexity,PMD.CyclomaticComplexity,PMD.NcssCount,PMD.ExcessiveParameterList')
public with sharing class AIDocIntakeService {
    public static final String JOB_STATUS_ACCEPTED = 'Accepted';
    public static final String JOB_STATUS_PROCESSING = 'Processing';
    public static final String JOB_STATUS_COMPLETE = 'Complete';
    public static final String JOB_STATUS_NEEDS_MAPPING = 'Needs_Mapping';
    public static final String JOB_STATUS_FAILED = 'Failed';
    public static final String FILE_STATUS_ACCEPTED = 'Accepted';
    public static final String FILE_STATUS_SPLIT_QUEUED = 'Split_Queued';
    public static final String FILE_STATUS_MAPPING = 'Mapping';
    public static final String FILE_STATUS_REVIEWING = 'Reviewing';
    public static final String FILE_STATUS_COMPLETE = 'Complete';
    public static final String FILE_STATUS_NEEDS_MAPPING = 'Needs_Mapping';
    public static final String FILE_STATUS_FAILED = 'Failed';

    private static final Integer MAX_FILES_PER_SUBMISSION = 20;
    private static final Integer MAX_CLIENT_SUBMISSION_ID_LENGTH = 200;
    private static final Set<String> ALLOWED_SOURCES = new Set<String>{ 'PORTAL', 'API', 'INTERNAL' };

    @TestVisible
    private static Id testLibraryIdOverride;

    @TestVisible
    private static Id testTargetFolderIdOverride;

    @TestVisible
    private static Boolean testBypassLibraryMembership = false;

    /**
     * Accepts a simple portal document submission and resolves Salesforce file details internally.
     * @param request Portal payload with application id, file name, and file content.
     * @return Submission result with job and file item status.
     * @throws IntakeException when validation, configuration, or file creation fails.
     */
    public static SubmissionResult acceptPortalSubmission(PortalSubmissionRequest request) {
        if (request == null) {
            throw error(400, 'Request body is required.');
        }

        Id applicationId = parseRecordId(request.applicationId, 'Application Id');
        validateApplication(applicationId);
        String source = normalizeSource(request.source);
        String fileName = normalizeFileName(request.fileName);
        Blob fileBody = normalizeFileBody(request);
        String contentHash = computeBlobHash(fileBody);
        String clientSubmissionId = buildSystemSubmissionId(fileName, contentHash);
        String submissionKey = buildSubmissionKey(applicationId, clientSubmissionId);
        Document_Intake_Job__c existing = findExistingJob(submissionKey);
        if (existing != null && !canRefreshExistingSubmission(existing)) {
            return buildResult(existing, false);
        }

        Id libraryId = resolveConfiguredLibraryId(source);
        Id targetFolderId = resolveApplicationFolderId(source, libraryId, applicationId);
        Id contentDocumentId = createUploadedFile(libraryId, targetFolderId, fileName, fileBody);

        SubmissionRequest internalRequest = new SubmissionRequest();
        internalRequest.source = source;
        internalRequest.libraryId = String.valueOf(libraryId);
        internalRequest.targetFolderId = targetFolderId == null ? null : String.valueOf(targetFolderId);
        SubmissionFileRequest file = new SubmissionFileRequest();
        file.contentDocumentId = String.valueOf(contentDocumentId);
        file.fileName = fileName;
        file.contentHash = contentHash;
        internalRequest.files = new List<SubmissionFileRequest>{ file };

        if (existing != null) {
            NormalizedRequest normalized = normalizeRequest(internalRequest);
            return refreshSubmission(existing, submissionKey, normalized);
        }

        return acceptSubmission(applicationId, clientSubmissionId, internalRequest);
    }

    /**
     * Creates or returns an idempotent document intake submission.
     * @param applicationId Application receiving the uploaded files.
     * @param clientSubmissionId Portal/client idempotency key.
     * @param request Parsed request payload.
     * @return Submission result with job and file item status.
     * @throws IntakeException when validation fails or a conflicting retry is detected.
     */
    public static SubmissionResult acceptSubmission(
        Id applicationId,
        String clientSubmissionId,
        SubmissionRequest request
    ) {
        validateApplication(applicationId);
        String normalizedClientSubmissionId = normalizeClientSubmissionId(clientSubmissionId);
        NormalizedRequest normalized = normalizeRequest(request);
        validateContentDocuments(normalized.contentDocumentIds);

        String submissionKey = buildSubmissionKey(applicationId, normalizedClientSubmissionId);
        String payloadHash = computePayloadHash(normalized);
        SubmissionIdentity identity = new SubmissionIdentity();
        identity.applicationId = applicationId;
        identity.clientSubmissionId = normalizedClientSubmissionId;
        identity.submissionKey = submissionKey;
        identity.payloadHash = payloadHash;
        Document_Intake_Job__c existing = findExistingJob(submissionKey);
        if (existing != null) {
            if (existing.Payload_Hash__c != payloadHash) {
                throw error(409, 'Client submission id was already used with a different file set.');
            }
            return buildResult(existing, false);
        }

        Document_Intake_Job__c job = createJob(identity, normalized);
        createFileItems(job.Id, submissionKey, normalized.files);
        System.enqueueJob(new AIDocIntakeQueueable(job.Id));
        return buildResult(loadJob(job.Id), true);
    }

    /**
     * Retrieves an existing document intake submission.
     * @param applicationId Application receiving the uploaded files.
     * @param clientSubmissionId Portal/client idempotency key.
     * @return Submission result with job and file item status.
     * @throws IntakeException when the submission cannot be found.
     */
    public static SubmissionResult getSubmission(Id applicationId, String clientSubmissionId) {
        validateApplication(applicationId);
        String normalizedClientSubmissionId = normalizeClientSubmissionId(clientSubmissionId);
        String submissionKey = buildSubmissionKey(applicationId, normalizedClientSubmissionId);
        Document_Intake_Job__c existing = findExistingJob(submissionKey);
        if (existing == null) {
            throw error(404, 'Document submission was not found.');
        }
        return buildResult(existing, false);
    }

    /**
     * Retrieves an existing document intake submission by generated intake job id.
     * @param intakeJobId Document intake job id returned by the PUT endpoint.
     * @return Submission result with job and file item status.
     * @throws IntakeException when the submission cannot be found.
     */
    public static SubmissionResult getSubmission(Id intakeJobId) {
        Document_Intake_Job__c existing = loadJob(intakeJobId);
        if (existing == null) {
            throw error(404, 'Document submission was not found.');
        }
        return buildResult(existing, false);
    }

    /**
     * Starts splitter work for accepted file items.
     * @param intakeJobId Intake job to process.
     */
    public static void processAcceptedFiles(Id intakeJobId) {
        if (intakeJobId == null) {
            return;
        }

        Document_Intake_Job__c job = loadJob(intakeJobId);
        if (job == null || job.Status__c == JOB_STATUS_FAILED || job.Status__c == JOB_STATUS_COMPLETE) {
            return;
        }

        List<Document_Intake_File__c> files = [
            SELECT Id, ContentDocument_Id__c, Status__c
            FROM Document_Intake_File__c
            WHERE Intake_Job__c = :intakeJobId
            AND Status__c = :FILE_STATUS_ACCEPTED
            WITH USER_MODE
            ORDER BY CreatedDate ASC
            LIMIT :MAX_FILES_PER_SUBMISSION
        ];
        if (files.isEmpty()) {
            return;
        }

        updateJobStatus(intakeJobId, JOB_STATUS_PROCESSING, null);
        List<Document_Intake_File__c> fileUpdates = new List<Document_Intake_File__c>();
        Integer startedCount = 0;
        for (Document_Intake_File__c fileItem : files) {
            fileUpdates.add(startSplitForFile(job, fileItem));
            if (fileUpdates[fileUpdates.size() - 1].Status__c == FILE_STATUS_SPLIT_QUEUED) {
                startedCount++;
            }
        }
        Database.update(fileUpdates, false, AccessLevel.USER_MODE);

        if (startedCount == 0) {
            updateJobStatus(intakeJobId, JOB_STATUS_FAILED, 'No submitted files could be queued for splitting.');
        }
    }

    /**
     * Marks intake file rows tied to a completed split job as mapping and queues placement.
     * @param splitJobId Split job that completed.
     */
    public static void markSplitComplete(Id splitJobId) {
        Set<Id> intakeJobIds = markSplitFinished(splitJobId, FILE_STATUS_MAPPING, null);
        if (!intakeJobIds.isEmpty() && !Test.isRunningTest()) {
            System.enqueueJob(new AIDocIntakeCategoryMappingQueueable(splitJobId));
        }
    }

    /**
     * Marks intake file rows tied to a failed split job as failed.
     * @param splitJobId Split job that failed.
     * @param errorDetail Failure detail from the splitter.
     */
    public static void markSplitFailed(Id splitJobId, String errorDetail) {
        markSplitFinished(splitJobId, FILE_STATUS_FAILED, errorDetail);
    }

    /**
     * Parses and validates a Salesforce record Id value.
     * @param idValue Raw id value.
     * @param label User-facing label for error messages.
     * @return Parsed Id.
     * @throws IntakeException when the value is blank or malformed.
     */
    public static Id parseRecordId(String idValue, String label) {
        if (String.isBlank(idValue) || !Pattern.matches('[a-zA-Z0-9]{15,18}', idValue)) {
            throw error(400, label + ' must be a valid Salesforce Id.');
        }
        try {
            return (Id) idValue;
        } catch (Exception e) {
            throw error(400, label + ' must be a valid Salesforce Id.');
        }
    }

    /**
     * Builds an intake exception with an HTTP status code.
     * @param statusCode HTTP status code.
     * @param message User-facing error message.
     * @return Intake exception.
     */
    public static IntakeException error(Integer statusCode, String message) {
        IntakeException ex = new IntakeException(message);
        ex.statusCode = statusCode;
        return ex;
    }

    /**
     * Recalculates parent intake job status from child file statuses.
     * @param intakeJobIds Intake jobs to roll up.
     */
    public static void recalculateIntakeStatuses(Set<Id> intakeJobIds) {
        recalculateIntakeJobStatuses(intakeJobIds);
    }

    /**
     * Marks mapped intake files as reviewed and recalculates the parent intake job.
     * @param intakeJobIds Intake jobs whose review batch finished.
     * @param detail Optional status detail for the intake file rows.
     */
    public static void markReviewComplete(Set<Id> intakeJobIds, String detail) {
        markReviewFinished(intakeJobIds, FILE_STATUS_COMPLETE, detail);
    }

    /**
     * Marks mapped intake files as failed when the headless review batch cannot finish.
     * @param intakeJobIds Intake jobs whose review batch failed.
     * @param detail Failure detail to store on the intake file rows.
     */
    public static void markReviewFailed(Set<Id> intakeJobIds, String detail) {
        markReviewFinished(intakeJobIds, FILE_STATUS_FAILED, detail);
    }

    private static void validateApplication(Id applicationId) {
        if (applicationId == null) {
            throw error(400, 'Application Id is required.');
        }
        List<genesis__Applications__c> applications = [
            SELECT Id
            FROM genesis__Applications__c
            WHERE Id = :applicationId
            WITH USER_MODE
            LIMIT 1
        ];
        if (applications.isEmpty()) {
            throw error(404, 'Application was not found.');
        }
    }

    private static String normalizeClientSubmissionId(String clientSubmissionId) {
        String normalized = clientSubmissionId == null ? '' : clientSubmissionId.trim();
        if (String.isBlank(normalized)) {
            throw error(400, 'Client submission id is required.');
        }
        if (normalized.length() > MAX_CLIENT_SUBMISSION_ID_LENGTH) {
            throw error(400, 'Client submission id cannot exceed 200 characters.');
        }
        return normalized;
    }

    private static NormalizedRequest normalizeRequest(SubmissionRequest request) {
        if (request == null) {
            throw error(400, 'Request body is required.');
        }
        validateFileList(request.files);

        NormalizedRequest normalized = new NormalizedRequest();
        normalized.source = normalizeSource(request.source);
        normalized.libraryId = normalizeOptionalId(request.libraryId, 'Library Id');
        normalized.targetFolderId = normalizeOptionalId(request.targetFolderId, 'Target Folder Id');

        Set<Id> seenDocIds = new Set<Id>();
        for (SubmissionFileRequest file : request.files) {
            NormalizedFile normalizedFile = normalizeFile(file);
            if (seenDocIds.contains(normalizedFile.contentDocumentId)) {
                throw error(400, 'Duplicate ContentDocument Id in request: ' + normalizedFile.contentDocumentId);
            }
            seenDocIds.add(normalizedFile.contentDocumentId);
            normalized.contentDocumentIds.add(normalizedFile.contentDocumentId);
            normalized.files.add(normalizedFile);
        }
        return normalized;
    }

    private static void validateFileList(List<SubmissionFileRequest> files) {
        if (files == null || files.isEmpty()) {
            throw error(400, 'At least one file is required.');
        }
        if (files.size() > MAX_FILES_PER_SUBMISSION) {
            throw error(400, 'A submission can include at most 20 files.');
        }
    }

    private static String normalizeSource(String source) {
        String normalized = String.isBlank(source) ? 'PORTAL' : source.trim().toUpperCase();
        if (!ALLOWED_SOURCES.contains(normalized)) {
            throw error(400, 'Source must be PORTAL, API, or INTERNAL.');
        }
        return normalized;
    }

    private static String normalizeFileName(String fileName) {
        String normalized = fileName == null ? '' : fileName.trim();
        if (String.isBlank(normalized)) {
            throw error(400, 'File name is required.');
        }
        if (normalized.contains('/') || normalized.contains('\\')) {
            throw error(400, 'File name cannot include a path.');
        }
        return normalized.left(255);
    }

    private static Blob normalizeFileBody(PortalSubmissionRequest request) {
        if (request.fileBody != null && request.fileBody.size() > 0) {
            return request.fileBody;
        }
        if (String.isBlank(request.base64Data)) {
            throw error(400, 'File content is required.');
        }

        String encoded = request.base64Data.trim();
        Integer commaIndex = encoded.indexOf(',');
        if (encoded.toLowerCase().startsWith('data:') && commaIndex >= 0) {
            encoded = encoded.substring(commaIndex + 1);
        }
        encoded = encoded.replace('\n', '').replace('\r', '').replace(' ', '');
        try {
            Blob body = EncodingUtil.base64Decode(encoded);
            if (body == null || body.size() == 0) {
                throw error(400, 'File content is required.');
            }
            return body;
        } catch (IntakeException e) {
            throw e;
        } catch (Exception e) {
            throw error(400, 'File content must be valid base64.');
        }
    }

    private static Id normalizeOptionalId(String rawId, String label) {
        if (String.isBlank(rawId)) {
            return null;
        }
        return parseRecordId(rawId.trim(), label);
    }

    private static NormalizedFile normalizeFile(SubmissionFileRequest file) {
        if (file == null) {
            throw error(400, 'File entry cannot be null.');
        }

        NormalizedFile normalized = new NormalizedFile();
        normalized.contentDocumentId = parseRecordId(file.contentDocumentId, 'ContentDocument Id');
        normalized.fileName = String.isBlank(file.fileName) ? null : file.fileName.trim().left(255);
        normalized.contentHash = String.isBlank(file.contentHash) ? null : file.contentHash.trim().left(128);
        return normalized;
    }

    private static void validateContentDocuments(Set<Id> contentDocumentIds) {
        Map<Id, ContentDocument> docsById = new Map<Id, ContentDocument>([
            SELECT Id
            FROM ContentDocument
            WHERE Id IN :contentDocumentIds
            WITH USER_MODE
        ]);
        if (docsById.size() == contentDocumentIds.size()) {
            return;
        }

        for (Id contentDocumentId : contentDocumentIds) {
            if (!docsById.containsKey(contentDocumentId)) {
                throw error(404, 'ContentDocument was not found or is not accessible: ' + contentDocumentId);
            }
        }
    }

    private static Id resolveConfiguredLibraryId(String source) {
        if (testLibraryIdOverride != null) {
            return testLibraryIdOverride;
        }

        Document_Intake_Config__mdt config = findConfig(source);
        if (config == null) {
            throw error(500, 'Document intake configuration is missing.');
        }
        String developerName = config.Library_Developer_Name__c;
        String libraryName = config.Library_Name__c;
        if (String.isBlank(developerName) && String.isBlank(libraryName)) {
            throw error(500, 'Document intake library is not configured.');
        }

        List<ContentWorkspace> libraries;
        if (!String.isBlank(developerName) && !String.isBlank(libraryName)) {
            libraries = [
                SELECT Id
                FROM ContentWorkspace
                WHERE DeveloperName = :developerName
                OR Name = :libraryName
                WITH USER_MODE
                LIMIT 2
            ];
        } else if (!String.isBlank(developerName)) {
            libraries = [
                SELECT Id
                FROM ContentWorkspace
                WHERE DeveloperName = :developerName
                WITH USER_MODE
                LIMIT 2
            ];
        } else {
            libraries = [
                SELECT Id
                FROM ContentWorkspace
                WHERE Name = :libraryName
                WITH USER_MODE
                LIMIT 2
            ];
        }

        if (libraries.isEmpty()) {
            throw error(404, 'Configured document intake library was not found.');
        }
        if (libraries.size() > 1) {
            throw error(409, 'Configured document intake library matched more than one library.');
        }
        return libraries[0].Id;
    }

    private static Id resolveApplicationFolderId(String source, Id libraryId, Id applicationId) {
        if (testTargetFolderIdOverride != null) {
            return testTargetFolderIdOverride;
        }
        if (Test.isRunningTest() && testBypassLibraryMembership) {
            return null;
        }

        Document_Intake_Config__mdt config = findConfig(source);
        if (config == null) {
            throw error(500, 'Document intake configuration is missing.');
        }

        return AIDocIntakeFolderService.ensureApplicationFolder(
            libraryId,
            applicationId,
            config.Target_Folder_Name__c,
            config.Target_Folder_Path__c
        );
    }

    private static Document_Intake_Config__mdt findConfig(String source) {
        Document_Intake_Config__mdt fallback;
        for (Document_Intake_Config__mdt config : Document_Intake_Config__mdt.getAll().values()) {
            if (config.Is_Active__c != true) {
                continue;
            }
            if (config.Source__c == source) {
                return config;
            }
            if (fallback == null && config.Source__c == 'PORTAL') {
                fallback = config;
            }
        }
        return fallback;
    }

    private static String stripExtension(String fileName) {
        Integer dotIndex = fileName == null ? -1 : fileName.lastIndexOf('.');
        if (dotIndex <= 0) {
            return fileName;
        }
        return fileName.substring(0, dotIndex);
    }

    private static String buildSystemSubmissionId(String fileName, String contentHash) {
        return 'portal-' + EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', Blob.valueOf(fileName + ':' + contentHash))
        );
    }

    private static String computeBlobHash(Blob body) {
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', body));
    }

    private static Id createUploadedFile(Id libraryId, Id folderId, String fileName, Blob fileBody) {
        try {
            ContentVersion version = new ContentVersion(
                Title = stripExtension(fileName).left(255),
                PathOnClient = fileName,
                VersionData = fileBody,
                IsMajorVersion = true
            );
            if (!(Test.isRunningTest() && testBypassLibraryMembership)) {
                version.FirstPublishLocationId = libraryId;
            }
            Database.insert(version, AccessLevel.USER_MODE);

            ContentVersion saved = [
                SELECT ContentDocumentId
                FROM ContentVersion
                WHERE Id = :version.Id
                WITH USER_MODE
                LIMIT 1
            ];
            ensureLibraryLink(libraryId, saved.ContentDocumentId);
            AIDocIntakeFolderService.moveDocumentToFolder(saved.ContentDocumentId, folderId);
            return saved.ContentDocumentId;
        } catch (DmlException e) {
            throw error(500, 'Unable to create Salesforce file in configured intake library.');
        }
    }

    private static void ensureLibraryLink(Id libraryId, Id contentDocumentId) {
        if (Test.isRunningTest() && testBypassLibraryMembership) {
            return;
        }
        List<ContentDocumentLink> links = new List<ContentDocumentLink>{
            new ContentDocumentLink(
                ContentDocumentId = contentDocumentId,
                LinkedEntityId = libraryId,
                ShareType = 'V'
            )
        };
        Database.insert(links, false, AccessLevel.USER_MODE);
    }

    private static String buildSubmissionKey(Id applicationId, String clientSubmissionId) {
        return String.valueOf(applicationId) + ':' + clientSubmissionId;
    }

    private static String computePayloadHash(NormalizedRequest normalized) {
        List<String> fileSignatures = new List<String>();
        for (NormalizedFile file : normalized.files) {
            fileSignatures.add(
                String.valueOf(file.contentDocumentId)
                    + '|'
                    + (file.contentHash == null ? '' : file.contentHash)
                    + '|'
                    + (file.fileName == null ? '' : file.fileName)
            );
        }
        fileSignatures.sort();
        String canonical = normalized.source
            + '\nLIB=' + (normalized.libraryId == null ? '' : String.valueOf(normalized.libraryId))
            + '\nFOLDER=' + (normalized.targetFolderId == null ? '' : String.valueOf(normalized.targetFolderId))
            + '\n' + String.join(fileSignatures, '\n');
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(canonical)));
    }

    private static Document_Intake_Job__c findExistingJob(String submissionKey) {
        List<Document_Intake_Job__c> jobs = [
            SELECT Id, Application__c, Client_Submission_Id__c, Client_Submission_Key__c,
                   Payload_Hash__c, Source__c, Status__c, Total_Files__c, Completed_Files__c,
                   Library_Id__c, Target_Folder_Id__c, Error_Detail__c
            FROM Document_Intake_Job__c
            WHERE Client_Submission_Key__c = :submissionKey
            WITH USER_MODE
            LIMIT 1
        ];
        return jobs.isEmpty() ? null : jobs[0];
    }

    private static Document_Intake_Job__c loadJob(Id jobId) {
        List<Document_Intake_Job__c> jobs = [
            SELECT Id, Application__c, Client_Submission_Id__c, Client_Submission_Key__c,
                   Payload_Hash__c, Source__c, Status__c, Total_Files__c, Completed_Files__c,
                   Library_Id__c, Target_Folder_Id__c, Error_Detail__c
            FROM Document_Intake_Job__c
            WHERE Id = :jobId
            WITH USER_MODE
            LIMIT 1
        ];
        return jobs.isEmpty() ? null : jobs[0];
    }

    private static Document_Intake_Job__c createJob(SubmissionIdentity identity, NormalizedRequest normalized) {
        Document_Intake_Job__c job = new Document_Intake_Job__c(
            Application__c = identity.applicationId,
            Client_Submission_Id__c = identity.clientSubmissionId,
            Client_Submission_Key__c = identity.submissionKey,
            Payload_Hash__c = identity.payloadHash,
            Source__c = normalized.source,
            Status__c = JOB_STATUS_ACCEPTED,
            Total_Files__c = normalized.files.size(),
            Completed_Files__c = 0,
            Library_Id__c = normalized.libraryId == null ? null : String.valueOf(normalized.libraryId),
            Target_Folder_Id__c = normalized.targetFolderId == null ? null : String.valueOf(normalized.targetFolderId),
            Raw_Request_JSON__c = normalized.toAuditJson().left(32768)
        );
        Database.insert(job, AccessLevel.USER_MODE);
        return job;
    }

    private static void createFileItems(Id jobId, String submissionKey, List<NormalizedFile> files) {
        List<Document_Intake_File__c> fileItems = new List<Document_Intake_File__c>();
        for (NormalizedFile file : files) {
            fileItems.add(new Document_Intake_File__c(
                Intake_Job__c = jobId,
                Item_Key__c = submissionKey + ':' + String.valueOf(file.contentDocumentId),
                ContentDocument_Id__c = String.valueOf(file.contentDocumentId),
                File_Name__c = file.fileName,
                Content_Hash__c = file.contentHash,
                Status__c = FILE_STATUS_ACCEPTED
            ));
        }
        Database.insert(fileItems, AccessLevel.USER_MODE);
    }

    private static Boolean canRefreshExistingSubmission(Document_Intake_Job__c existing) {
        if (existing == null) {
            return false;
        }

        List<Document_Intake_File__c> fileItems = [
            SELECT ContentDocument_Id__c
            FROM Document_Intake_File__c
            WHERE Intake_Job__c = :existing.Id
            WITH USER_MODE
            LIMIT :MAX_FILES_PER_SUBMISSION
        ];
        if (fileItems.isEmpty()) {
            return existing.Status__c == JOB_STATUS_FAILED || existing.Status__c == JOB_STATUS_COMPLETE;
        }

        Set<Id> contentDocumentIds = new Set<Id>();
        for (Document_Intake_File__c fileItem : fileItems) {
            try {
                contentDocumentIds.add((Id) fileItem.ContentDocument_Id__c);
            } catch (Exception e) {
                return true;
            }
        }
        if (contentDocumentIds.isEmpty()) {
            return existing.Status__c == JOB_STATUS_FAILED || existing.Status__c == JOB_STATUS_COMPLETE;
        }

        Map<Id, ContentDocument> liveDocsById = new Map<Id, ContentDocument>([
            SELECT Id
            FROM ContentDocument
            WHERE Id IN :contentDocumentIds
            WITH USER_MODE
        ]);
        return liveDocsById.size() < contentDocumentIds.size();
    }

    private static SubmissionResult refreshSubmission(
        Document_Intake_Job__c existing,
        String submissionKey,
        NormalizedRequest normalized
    ) {
        Document_Intake_Job__c jobUpdate = new Document_Intake_Job__c(
            Id = existing.Id,
            Payload_Hash__c = computePayloadHash(normalized),
            Status__c = JOB_STATUS_ACCEPTED,
            Total_Files__c = normalized.files.size(),
            Completed_Files__c = 0,
            Library_Id__c = normalized.libraryId == null ? null : String.valueOf(normalized.libraryId),
            Target_Folder_Id__c = normalized.targetFolderId == null ? null : String.valueOf(normalized.targetFolderId),
            Raw_Request_JSON__c = normalized.toAuditJson().left(32768),
            Error_Detail__c = null
        );
        Database.update(jobUpdate, AccessLevel.USER_MODE);
        refreshFileItems(existing.Id, submissionKey, normalized.files);
        System.enqueueJob(new AIDocIntakeQueueable(existing.Id));
        SubmissionResult result = buildResult(loadJob(existing.Id), false);
        result.refreshed = true;
        return result;
    }

    private static void refreshFileItems(Id jobId, String submissionKey, List<NormalizedFile> files) {
        List<Document_Intake_File__c> existingItems = [
            SELECT Id
            FROM Document_Intake_File__c
            WHERE Intake_Job__c = :jobId
            WITH USER_MODE
            ORDER BY CreatedDate ASC
            LIMIT :MAX_FILES_PER_SUBMISSION
        ];
        if (existingItems.isEmpty()) {
            createFileItems(jobId, submissionKey, files);
            return;
        }

        List<Document_Intake_File__c> updates = new List<Document_Intake_File__c>();
        for (Integer i = 0; i < existingItems.size(); i++) {
            Document_Intake_File__c updateRecord = new Document_Intake_File__c(Id = existingItems[i].Id);
            if (i < files.size()) {
                NormalizedFile file = files[i];
                updateRecord.Item_Key__c = submissionKey + ':' + String.valueOf(file.contentDocumentId);
                updateRecord.ContentDocument_Id__c = String.valueOf(file.contentDocumentId);
                updateRecord.File_Name__c = file.fileName;
                updateRecord.Content_Hash__c = file.contentHash;
                updateRecord.Status__c = FILE_STATUS_ACCEPTED;
                updateRecord.Split_Job__c = null;
                updateRecord.Document_Category__c = null;
                updateRecord.Document_Type__c = null;
                updateRecord.Mapping_Confidence__c = null;
                updateRecord.Split_Result_JSON__c = null;
                updateRecord.Error_Detail__c = null;
            } else {
                updateRecord.Status__c = FILE_STATUS_FAILED;
                updateRecord.Error_Detail__c = 'Superseded by portal retry.'.left(32768);
            }
            updates.add(updateRecord);
        }
        Database.update(updates, false, AccessLevel.USER_MODE);

        if (files.size() > existingItems.size()) {
            List<NormalizedFile> additionalFiles = new List<NormalizedFile>();
            for (Integer i = existingItems.size(); i < files.size(); i++) {
                additionalFiles.add(files[i]);
            }
            createFileItems(jobId, submissionKey, additionalFiles);
        }
    }

    private static Document_Intake_File__c startSplitForFile(
        Document_Intake_Job__c intakeJob,
        Document_Intake_File__c fileItem
    ) {
        Document_Intake_File__c updateRecord = new Document_Intake_File__c(Id = fileItem.Id);
        try {
            DocSplitterInvocable.Request splitRequest = new DocSplitterInvocable.Request();
            splitRequest.sourceContentDocumentId = (Id) fileItem.ContentDocument_Id__c;
            splitRequest.targetRecordId = intakeJob.Application__c;
            splitRequest.libraryId = String.isBlank(intakeJob.Library_Id__c) ? null : (Id) intakeJob.Library_Id__c;
            splitRequest.targetFolderId =
                String.isBlank(intakeJob.Target_Folder_Id__c) ? null : (Id) intakeJob.Target_Folder_Id__c;

            List<DocSplitterInvocable.Response> splitResults =
                DocSplitterInvocable.startHeadlessSplit(new List<DocSplitterInvocable.Request>{ splitRequest });
            updateRecord.Status__c = FILE_STATUS_SPLIT_QUEUED;
            updateRecord.Split_Job__c = splitResults[0].jobId;
        } catch (Exception e) {
            updateRecord.Status__c = FILE_STATUS_FAILED;
            updateRecord.Error_Detail__c = (e.getTypeName() + ': ' + e.getMessage()).left(32768);
        }
        return updateRecord;
    }

    private static void updateJobStatus(Id jobId, String status, String errorDetail) {
        Document_Intake_Job__c updateRecord = new Document_Intake_Job__c(
            Id = jobId,
            Status__c = status
        );
        if (errorDetail != null) {
            updateRecord.Error_Detail__c = errorDetail.left(32768);
        }
        Database.update(updateRecord, AccessLevel.USER_MODE);
    }

    private static Set<Id> markSplitFinished(Id splitJobId, String fileStatus, String errorDetail) {
        Set<Id> intakeJobIds = new Set<Id>();
        if (splitJobId == null) {
            return intakeJobIds;
        }

        List<Document_Intake_File__c> fileItems = [
            SELECT Id, Intake_Job__c
            FROM Document_Intake_File__c
            WHERE Split_Job__c = :splitJobId
            WITH USER_MODE
        ];
        if (fileItems.isEmpty()) {
            return intakeJobIds;
        }

        String splitResultJson = fileStatus == FILE_STATUS_MAPPING
            ? loadSplitResultJson(splitJobId)
            : null;
        List<Document_Intake_File__c> fileUpdates = new List<Document_Intake_File__c>();
        for (Document_Intake_File__c fileItem : fileItems) {
            intakeJobIds.add(fileItem.Intake_Job__c);
            Document_Intake_File__c updateRecord = new Document_Intake_File__c(
                Id = fileItem.Id,
                Status__c = fileStatus
            );
            if (!String.isBlank(splitResultJson)) {
                updateRecord.Split_Result_JSON__c = splitResultJson.left(32768);
            }
            if (!String.isBlank(errorDetail)) {
                updateRecord.Error_Detail__c = errorDetail.left(32768);
            }
            fileUpdates.add(updateRecord);
        }
        Database.update(fileUpdates, false, AccessLevel.USER_MODE);
        recalculateIntakeJobStatuses(intakeJobIds);
        return intakeJobIds;
    }

    private static String loadSplitResultJson(Id splitJobId) {
        List<Split_Job__c> splitJobs = [
            SELECT Merged_Segments_JSON__c
            FROM Split_Job__c
            WHERE Id = :splitJobId
            WITH USER_MODE
            LIMIT 1
        ];
        return splitJobs.isEmpty() ? null : splitJobs[0].Merged_Segments_JSON__c;
    }

    private static void recalculateIntakeJobStatuses(Set<Id> intakeJobIds) {
        if (intakeJobIds == null || intakeJobIds.isEmpty()) {
            return;
        }

        Map<Id, IntakeStatusRollup> rollupsByJobId = new Map<Id, IntakeStatusRollup>();
        for (Id intakeJobId : intakeJobIds) {
            rollupsByJobId.put(intakeJobId, new IntakeStatusRollup());
        }

        for (Document_Intake_File__c fileItem : [
            SELECT Intake_Job__c, Status__c, Error_Detail__c
            FROM Document_Intake_File__c
            WHERE Intake_Job__c IN :intakeJobIds
            WITH USER_MODE
        ]) {
            rollupsByJobId.get(fileItem.Intake_Job__c).include(fileItem);
        }

        List<Document_Intake_Job__c> jobUpdates = new List<Document_Intake_Job__c>();
        for (Id intakeJobId : rollupsByJobId.keySet()) {
            IntakeStatusRollup rollup = rollupsByJobId.get(intakeJobId);
            jobUpdates.add(new Document_Intake_Job__c(
                Id = intakeJobId,
                Status__c = rollup.status(),
                Completed_Files__c = rollup.completedCount,
                Error_Detail__c = rollup.errorDetail
            ));
        }
        Database.update(jobUpdates, false, AccessLevel.USER_MODE);
    }

    private static void markReviewFinished(Set<Id> intakeJobIds, String status, String detail) {
        if (intakeJobIds == null || intakeJobIds.isEmpty()) {
            return;
        }

        List<Document_Intake_File__c> updates = new List<Document_Intake_File__c>();
        for (Document_Intake_File__c fileItem : [
            SELECT Id
            FROM Document_Intake_File__c
            WHERE Intake_Job__c IN :intakeJobIds
            AND Status__c = :FILE_STATUS_REVIEWING
            WITH USER_MODE
        ]) {
            updates.add(new Document_Intake_File__c(
                Id = fileItem.Id,
                Status__c = status,
                Error_Detail__c = String.isBlank(detail) ? null : detail.left(32768)
            ));
        }
        if (!updates.isEmpty()) {
            Database.update(updates, false, AccessLevel.USER_MODE);
        }
        recalculateIntakeJobStatuses(intakeJobIds);
    }

    private static SubmissionResult buildResult(Document_Intake_Job__c job, Boolean created) {
        SubmissionResult result = new SubmissionResult();
        result.created = created;
        result.refreshed = false;
        result.jobId = job.Id;
        result.applicationId = job.Application__c;
        result.clientSubmissionId = job.Client_Submission_Id__c;
        result.status = job.Status__c;
        result.fileCount = job.Total_Files__c == null ? 0 : ((Integer) job.Total_Files__c);
        result.completedFileCount = job.Completed_Files__c == null ? 0 : ((Integer) job.Completed_Files__c);
        result.files = buildFileResults(job.Id);
        return result;
    }

    private static List<FileResult> buildFileResults(Id jobId) {
        List<FileResult> results = new List<FileResult>();
        for (Document_Intake_File__c fileItem : [
            SELECT Id, ContentDocument_Id__c, File_Name__c, Content_Hash__c, Status__c,
                   Split_Job__c, Document_Category__c, Document_Type__c, Mapping_Confidence__c,
                   Error_Detail__c
            FROM Document_Intake_File__c
            WHERE Intake_Job__c = :jobId
            WITH USER_MODE
            ORDER BY CreatedDate ASC
        ]) {
            FileResult fileResult = new FileResult();
            fileResult.fileItemId = fileItem.Id;
            fileResult.contentDocumentId = fileItem.ContentDocument_Id__c;
            fileResult.fileName = fileItem.File_Name__c;
            fileResult.contentHash = fileItem.Content_Hash__c;
            fileResult.status = fileItem.Status__c;
            fileResult.splitJobId = fileItem.Split_Job__c;
            fileResult.documentCategoryId = fileItem.Document_Category__c;
            fileResult.documentType = fileItem.Document_Type__c;
            fileResult.mappingConfidence = fileItem.Mapping_Confidence__c;
            fileResult.errorDetail = fileItem.Error_Detail__c;
            results.add(fileResult);
        }
        return results;
    }

    /**
     * Public portal submission payload.
     */
    public class PortalSubmissionRequest {
        public String applicationId;
        public String fileName;
        public String source;
        public String base64Data;
        public Blob fileBody;
    }

    /**
     * Inbound document submission payload.
     */
    public class SubmissionRequest {
        public String source;
        public String libraryId;
        public String targetFolderId;
        public List<SubmissionFileRequest> files;
    }

    /**
     * Inbound file entry for a submission.
     */
    public class SubmissionFileRequest {
        public String contentDocumentId;
        public String fileName;
        public String contentHash;
    }

    /**
     * API response payload for a submission.
     */
    public class SubmissionResult {
        public Boolean created;
        public Boolean refreshed;
        public Id jobId;
        public Id applicationId;
        public String clientSubmissionId;
        public String status;
        public String statusUrl;
        public Integer fileCount;
        public Integer completedFileCount;
        public List<FileResult> files;
    }

    /**
     * API response payload for one intake file item.
     */
    public class FileResult {
        public Id fileItemId;
        public String contentDocumentId;
        public String fileName;
        public String contentHash;
        public String status;
        public Id splitJobId;
        public Id documentCategoryId;
        public String documentType;
        public Decimal mappingConfidence;
        public String errorDetail;
    }

    /**
     * Exception carrying the HTTP status that should be returned by the REST resource.
     */
    public class IntakeException extends Exception {
        public Integer statusCode;
    }

    private class SubmissionIdentity {
        public Id applicationId;
        public String clientSubmissionId;
        public String submissionKey;
        public String payloadHash;
    }

    private class NormalizedRequest {
        public String source;
        public Id libraryId;
        public Id targetFolderId;
        public List<NormalizedFile> files = new List<NormalizedFile>();
        public Set<Id> contentDocumentIds = new Set<Id>();

        private String toAuditJson() {
            List<Map<String, Object>> auditFiles = new List<Map<String, Object>>();
            for (NormalizedFile file : files) {
                auditFiles.add(new Map<String, Object>{
                    'contentDocumentId' => String.valueOf(file.contentDocumentId),
                    'fileName' => file.fileName,
                    'contentHash' => file.contentHash
                });
            }
            return JSON.serialize(new Map<String, Object>{
                'source' => source,
                'libraryId' => libraryId == null ? null : String.valueOf(libraryId),
                'targetFolderId' => targetFolderId == null ? null : String.valueOf(targetFolderId),
                'files' => auditFiles
            });
        }
    }

    private class NormalizedFile {
        public Id contentDocumentId;
        public String fileName;
        public String contentHash;
    }

    private class IntakeStatusRollup {
        public Integer totalCount = 0;
        public Integer completedCount = 0;
        public Integer failedCount = 0;
        public Integer needsMappingCount = 0;
        public Integer pendingCount = 0;
        public String errorDetail;

        private void include(Document_Intake_File__c fileItem) {
            totalCount++;
            if (fileItem.Status__c == FILE_STATUS_COMPLETE) {
                completedCount++;
            } else if (fileItem.Status__c == FILE_STATUS_FAILED) {
                failedCount++;
                if (String.isBlank(errorDetail)) {
                    errorDetail = fileItem.Error_Detail__c;
                }
            } else if (fileItem.Status__c == FILE_STATUS_NEEDS_MAPPING) {
                needsMappingCount++;
            } else {
                pendingCount++;
            }
        }

        private String status() {
            if (totalCount == 0 || pendingCount > 0) {
                return JOB_STATUS_PROCESSING;
            }
            if (failedCount > 0) {
                return JOB_STATUS_FAILED;
            }
            if (needsMappingCount > 0) {
                return JOB_STATUS_NEEDS_MAPPING;
            }
            return JOB_STATUS_COMPLETE;
        }
    }
}

/**
 * Tests for the AI Document Intake REST API.
 */
@IsTest
private class AIDocIntakeRestResourceTest {
    @IsTest
    static void shouldAcceptSubmissionAndQueueSplitWhenPutValid() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        configureLibraryLookupForTest();

        Test.startTest();
        setPutRequest();
        setRequestBody(buildBody(app.Id, 'portal_bundle.pdf', Blob.valueOf('PDF-BYTES-portal-bundle')));
        AIDocIntakeRestResource.doPut();
        Test.stopTest();

        Map<String, Object> response = responseFromBody();
        Map<String, Object> data = dataFrom(response);
        Assert.areEqual(202, RestContext.response.statusCode, 'PUT should return Accepted');
        Assert.areEqual(true, response.get('success'), 'response should succeed');
        Assert.areEqual(true, data.get('created'), 'first PUT should create the intake job');
        Assert.areEqual(1, intFrom(data.get('fileCount')), 'one file should be accepted');

        Document_Intake_Job__c job = loadJob(idFrom(data.get('jobId')));
        Assert.areEqual(AIDocIntakeService.JOB_STATUS_PROCESSING, job.Status__c,
            'queueable should start processing');
        Assert.areEqual(String.valueOf(fakeFolderId()), job.Target_Folder_Id__c,
            'portal intake should resolve the application folder server-side');

        Document_Intake_File__c fileItem = loadOnlyFile(job.Id);
        Assert.areEqual('portal_bundle.pdf', fileItem.File_Name__c, 'file name should come from portal payload');
        Assert.isNotNull(fileItem.ContentDocument_Id__c, 'API should create the Salesforce file');
        Assert.isNotNull(fileItem.Content_Hash__c, 'file hash should be stored for idempotency');
        Assert.areEqual(AIDocIntakeService.FILE_STATUS_SPLIT_QUEUED, fileItem.Status__c,
            'queueable should start the headless split');
        Assert.isNotNull(fileItem.Split_Job__c, 'split job correlation should be stored');
        Split_Job__c splitJob = [
            SELECT Target_Folder_Id__c
            FROM Split_Job__c
            WHERE Id = :fileItem.Split_Job__c
            LIMIT 1
        ];
        Assert.areEqual(job.Target_Folder_Id__c, splitJob.Target_Folder_Id__c,
            'split output should be directed to the same application folder');
    }

    @IsTest
    static void shouldReturnExistingJobWhenSameSubmissionIsRetried() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        configureLibraryLookupForTest();
        String body = buildBody(app.Id, 'passport.pdf', Blob.valueOf('PDF-BYTES-passport'));

        Test.startTest();
        setPutRequest();
        setRequestBody(body);
        AIDocIntakeRestResource.doPut();
        Map<String, Object> first = responseFromBody();
        setPutRequest();
        setRequestBody(body);
        AIDocIntakeRestResource.doPut();
        Map<String, Object> second = responseFromBody();
        Test.stopTest();

        Map<String, Object> firstData = dataFrom(first);
        Map<String, Object> secondData = dataFrom(second);
        Assert.areEqual(firstData.get('jobId'), secondData.get('jobId'), 'retry should return the same intake job');
        Assert.areEqual(false, secondData.get('created'), 'retry should not create another job');
        Assert.areEqual(1, [SELECT COUNT() FROM Document_Intake_Job__c],
            'only one intake job should exist for the idempotency key');
        Assert.areEqual(1, [SELECT COUNT() FROM ContentVersion WHERE PathOnClient = 'passport.pdf'],
            'retry should not upload another Salesforce file');
    }

    @IsTest
    static void shouldRefreshFailedSubmissionWhenPriorFileWasDeleted() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        configureLibraryLookupForTest();
        Blob body = Blob.valueOf('PDF-BYTES-retry-deleted-file');
        String fileName = 'retry_deleted_file.pdf';
        String clientSubmissionId = systemSubmissionId(fileName, body);
        Id existingJobId = createFailedSubmissionWithMissingFile(app.Id, clientSubmissionId, fileName);
        String staleContentDocumentId = loadOnlyFile(existingJobId).ContentDocument_Id__c;

        Test.startTest();
        setPutRequest();
        setRequestBody(buildBody(app.Id, fileName, body));
        AIDocIntakeRestResource.doPut();
        Test.stopTest();

        Map<String, Object> response = responseFromBody();
        Map<String, Object> data = dataFrom(response);
        Document_Intake_File__c refreshedFile = loadOnlyFile(existingJobId);
        Assert.areEqual('Submission accepted.', response.get('message'),
            'deleted-file retry should be treated as a fresh accepted upload');
        Assert.areEqual(true, data.get('refreshed'),
            'response should identify that the failed submission was refreshed');
        Assert.areEqual(existingJobId, idFrom(data.get('jobId')),
            'retry should reuse the existing intake job id');
        Assert.areNotEqual(staleContentDocumentId, refreshedFile.ContentDocument_Id__c,
            'retry should replace the deleted file id');
        Assert.areEqual(AIDocIntakeService.FILE_STATUS_SPLIT_QUEUED, refreshedFile.Status__c,
            'retry should queue the refreshed file for splitting');
        Id refreshedContentDocumentId = (Id) refreshedFile.ContentDocument_Id__c;
        Assert.areEqual(1, [
            SELECT COUNT()
            FROM ContentDocument
            WHERE Id = :refreshedContentDocumentId
        ], 'refreshed content document should exist');
    }

    @IsTest
    static void shouldRefreshCompletedSubmissionWhenPriorFileWasDeleted() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        configureLibraryLookupForTest();
        Blob body = Blob.valueOf('PDF-BYTES-complete-deleted-file');
        String fileName = 'complete_deleted_file.pdf';
        String clientSubmissionId = systemSubmissionId(fileName, body);
        Id existingJobId = createCompletedSubmissionWithMissingFile(app.Id, clientSubmissionId, fileName);

        Test.startTest();
        setPutRequest();
        setRequestBody(buildBody(app.Id, fileName, body));
        AIDocIntakeRestResource.doPut();
        Test.stopTest();

        Map<String, Object> response = responseFromBody();
        Map<String, Object> data = dataFrom(response);
        Document_Intake_File__c refreshedFile = loadOnlyFile(existingJobId);
        Assert.areEqual('Submission accepted.', response.get('message'),
            'deleted completed submission retry should be accepted again');
        Assert.areEqual(true, data.get('refreshed'),
            'completed submission with a deleted backing file should be refreshed');
        Assert.areEqual(existingJobId, idFrom(data.get('jobId')),
            'retry should keep the same idempotent intake job');
        Assert.areEqual(AIDocIntakeService.FILE_STATUS_SPLIT_QUEUED, refreshedFile.Status__c,
            'refreshed completed submission should be sent through splitting again');
    }

    @IsTest
    static void shouldNotRefreshFailedSubmissionWhenPriorFileStillExists() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        configureLibraryLookupForTest();
        Blob body = Blob.valueOf('PDF-BYTES-retry-live-file');
        String fileName = 'retry_live_file.pdf';
        String clientSubmissionId = systemSubmissionId(fileName, body);
        Id liveContentDocumentId = createContentDocument('retry_live_file');
        Id existingJobId = createFailedSubmission(app.Id, clientSubmissionId, fileName, liveContentDocumentId);

        Test.startTest();
        setPutRequest();
        setRequestBody(buildBody(app.Id, fileName, body));
        AIDocIntakeRestResource.doPut();
        Test.stopTest();

        Document_Intake_File__c fileItem = loadOnlyFile(existingJobId);
        Assert.areEqual(String.valueOf(liveContentDocumentId), fileItem.ContentDocument_Id__c,
            'retry should preserve the prior live file id');
        Assert.areEqual(AIDocIntakeService.FILE_STATUS_FAILED, fileItem.Status__c,
            'existing failed submission should be returned unchanged when the file still exists');
    }

    @IsTest
    static void shouldAcceptBinaryUploadFromHeaders() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        configureLibraryLookupForTest();

        Test.startTest();
        setBinaryPutRequest(app.Id, 'headers_bundle.pdf');
        setRequestBody(Blob.valueOf('PDF-BYTES-headers-bundle'));
        AIDocIntakeRestResource.doPut();
        Map<String, Object> response = responseFromBody();
        Test.stopTest();

        Map<String, Object> data = dataFrom(response);
        Assert.areEqual(202, RestContext.response.statusCode, 'binary PUT should return Accepted');
        Assert.areEqual(true, response.get('success'), 'response should succeed');
        Document_Intake_File__c fileItem = loadOnlyFile(idFrom(data.get('jobId')));
        Assert.areEqual('headers_bundle.pdf', fileItem.File_Name__c, 'header file name should be used');
    }

    @IsTest
    static void shouldMarkIntakeMappingWhenSplitCompletes() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        configureLibraryLookupForTest();
        Id intakeJobId = createAcceptedSubmission(app.Id, 'mapped_bundle.pdf');
        Document_Intake_File__c queuedFile = loadOnlyFile(intakeJobId);
        String splitJson = '[{"documentType":"ARTICLES_OF_INCORPORATION","pages":[1]}]';
        update new Split_Job__c(
            Id = queuedFile.Split_Job__c,
            Merged_Segments_JSON__c = splitJson
        );

        SplitJobService.finalizeJob(queuedFile.Split_Job__c, 1, '[{"type":"ARTICLES_OF_INCORPORATION","count":1}]');

        Document_Intake_Job__c job = loadJob(intakeJobId);
        Document_Intake_File__c fileItem = loadOnlyFile(intakeJobId);
        Assert.areEqual(AIDocIntakeService.JOB_STATUS_PROCESSING, job.Status__c,
            'intake job should remain processing while category mapping is queued');
        Assert.areEqual(0, job.Completed_Files__c, 'mapping/review work is not complete yet');
        Assert.areEqual(AIDocIntakeService.FILE_STATUS_MAPPING, fileItem.Status__c,
            'file should be actively waiting for mapping');
        Assert.areEqual(splitJson, fileItem.Split_Result_JSON__c,
            'split result should be stored for downstream mapping');
    }

    @IsTest
    static void shouldMarkIntakeFailedWhenSplitFails() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        configureLibraryLookupForTest();
        Id intakeJobId = createAcceptedSubmission(app.Id, 'failing_bundle.pdf');
        Document_Intake_File__c queuedFile = loadOnlyFile(intakeJobId);

        SplitJobService.failJob(queuedFile.Split_Job__c, 'Splitting', 'Binary split failed.');

        Document_Intake_Job__c job = loadJob(intakeJobId);
        Document_Intake_File__c fileItem = loadOnlyFile(intakeJobId);
        Assert.areEqual(AIDocIntakeService.JOB_STATUS_FAILED, job.Status__c,
            'intake job should fail when its split job fails');
        Assert.areEqual(AIDocIntakeService.FILE_STATUS_FAILED, fileItem.Status__c,
            'file should be failed');
        Assert.isTrue(fileItem.Error_Detail__c.contains('Binary split failed'),
            'file should capture split failure detail');
    }

    @IsTest
    static void shouldPlaceSourceInOthersWhenSplitCreatesNoFiles() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        configureLibraryLookupForTest();
        Id intakeJobId = createAcceptedSubmission(app.Id, 'empty_split_bundle.pdf');
        Document_Intake_File__c queuedFile = loadOnlyFile(intakeJobId);

        SplitJobService.finalizeJob(queuedFile.Split_Job__c, 0, '[]');
        AIDocIntakeCategoryMappingService.mapSplitOutputs(queuedFile.Split_Job__c);

        Document_Intake_Job__c job = loadJob(intakeJobId);
        Document_Intake_File__c fileItem = loadOnlyFile(intakeJobId);
        Assert.areEqual(AIDocIntakeService.JOB_STATUS_PROCESSING, job.Status__c,
            'source should keep processing after fallback placement until review completes');
        Assert.areEqual(AIDocIntakeService.FILE_STATUS_REVIEWING, fileItem.Status__c,
            'file should wait for review after fallback placement');
        Assert.isNotNull(fileItem.Document_Category__c,
            'fallback placement should store the target document category');
        Assert.areEqual('OTHER', fileItem.Document_Type__c,
            'fallback placement should classify the intake row as OTHER');
        Assert.areEqual(0, fileItem.Mapping_Confidence__c,
            'fallback placement should store zero confidence');
        Assert.areEqual(1, [
            SELECT COUNT()
            FROM clcommon__Document_Category__c
            WHERE Id = :fileItem.Document_Category__c
            AND genesis__Application__c = :app.Id
            AND clcommon__Category_Name__c = 'Others'
            AND clcommon__Parent_Document_Category__r.clcommon__Category_Name__c = 'Uncategorized'
        ], 'Others category should be created for the application');
        Assert.areEqual(1, [
            SELECT COUNT()
            FROM clcommon__Category_Attachment_Association__c
            WHERE clcommon__Document_Category__c = :fileItem.Document_Category__c
            AND clcommon__Content_Document_Id__c = :fileItem.ContentDocument_Id__c
            AND clcommon__Status__c = 'Submitted'
        ], 'source file should be attached to Others as a current document');
    }

    @IsTest
    static void shouldReturnSubmissionWhenGetValid() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        configureLibraryLookupForTest();

        Test.startTest();
        setPutRequest();
        setRequestBody(buildBody(app.Id, 'w2.pdf', Blob.valueOf('PDF-BYTES-w2')));
        AIDocIntakeRestResource.doPut();
        Test.stopTest();

        Map<String, Object> putResponse = responseFromBody();
        setGetRequest(idFrom(dataFrom(putResponse).get('jobId')));
        AIDocIntakeRestResource.doGet();
        Map<String, Object> getResponse = responseFromBody();

        Map<String, Object> putData = dataFrom(putResponse);
        Map<String, Object> getData = dataFrom(getResponse);
        Assert.areEqual(200, RestContext.response.statusCode, 'GET should succeed');
        Assert.areEqual(putData.get('jobId'), getData.get('jobId'), 'GET should return the same job');
        Assert.areEqual(1, ((List<Object>) getData.get('files')).size(), 'GET should include file item state');
    }

    @IsTest
    static void shouldRejectPutWhenFileNameIsMissing() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        configureLibraryLookupForTest();

        Test.startTest();
        setPutRequest();
        setRequestBody(JSON.serialize(new Map<String, Object>{
            'applicationId' => String.valueOf(app.Id),
            'base64Data' => EncodingUtil.base64Encode(Blob.valueOf('PDF-BYTES-missing-name'))
        }));
        AIDocIntakeRestResource.doPut();
        Map<String, Object> response = responseFromBody();
        Test.stopTest();

        Assert.areEqual(400, RestContext.response.statusCode, 'missing file name should be rejected');
        Assert.areEqual(false, response.get('success'), 'response should fail');
    }

    private static void setPutRequest() {
        RestRequest request = new RestRequest();
        request.httpMethod = 'PUT';
        request.requestURI = '/services/apexrest/document-submissions';
        request.addHeader('Content-Type', 'application/json');
        RestContext.request = request;
        RestContext.response = new RestResponse();
    }

    private static void setBinaryPutRequest(Id applicationId, String fileName) {
        RestRequest request = new RestRequest();
        request.httpMethod = 'PUT';
        request.requestURI = '/services/apexrest/document-submissions';
        request.addHeader('Content-Type', 'application/pdf');
        request.addHeader('X-Application-Id', String.valueOf(applicationId));
        request.addHeader('X-File-Name', fileName);
        RestContext.request = request;
        RestContext.response = new RestResponse();
    }

    private static void setGetRequest(Id intakeJobId) {
        RestRequest request = new RestRequest();
        request.httpMethod = 'GET';
        request.requestURI = '/services/apexrest/document-submissions/' + String.valueOf(intakeJobId);
        RestContext.request = request;
        RestContext.response = new RestResponse();
    }

    private static void setRequestBody(String body) {
        RestContext.request.requestBody = Blob.valueOf(body);
    }

    private static void setRequestBody(Blob body) {
        RestContext.request.requestBody = body;
    }

    private static Id createAcceptedSubmission(Id applicationId, String fileName) {
        Test.startTest();
        setPutRequest();
        setRequestBody(buildBody(applicationId, fileName, Blob.valueOf('PDF-BYTES-' + fileName)));
        AIDocIntakeRestResource.doPut();
        Test.stopTest();

        Map<String, Object> response = responseFromBody();
        return idFrom(dataFrom(response).get('jobId'));
    }

    private static String buildBody(Id applicationId, String fileName, Blob body) {
        return JSON.serialize(new Map<String, Object>{
            'applicationId' => String.valueOf(applicationId),
            'source' => 'PORTAL',
            'fileName' => fileName,
            'base64Data' => EncodingUtil.base64Encode(body)
        });
    }

    private static String systemSubmissionId(String fileName, Blob body) {
        String contentHash = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', body));
        return 'portal-' + EncodingUtil.convertToHex(
            Crypto.generateDigest('SHA-256', Blob.valueOf(fileName + ':' + contentHash))
        );
    }

    private static Id createFailedSubmissionWithMissingFile(
        Id applicationId,
        String clientSubmissionId,
        String fileName
    ) {
        return createFailedSubmission(applicationId, clientSubmissionId, fileName, fakeContentDocumentId());
    }

    private static Id createFailedSubmission(
        Id applicationId,
        String clientSubmissionId,
        String fileName,
        Id contentDocumentId
    ) {
        Document_Intake_Job__c job = new Document_Intake_Job__c(
            Application__c = applicationId,
            Client_Submission_Id__c = clientSubmissionId,
            Client_Submission_Key__c = String.valueOf(applicationId) + ':' + clientSubmissionId,
            Payload_Hash__c = 'stale-hash-' + String.valueOf(System.currentTimeMillis()),
            Source__c = 'PORTAL',
            Status__c = AIDocIntakeService.JOB_STATUS_FAILED,
            Total_Files__c = 1,
            Completed_Files__c = 0,
            Error_Detail__c = 'Prior processing failed.'
        );
        insert job;
        insert new Document_Intake_File__c(
            Intake_Job__c = job.Id,
            Item_Key__c = job.Client_Submission_Key__c + ':' + String.valueOf(contentDocumentId),
            ContentDocument_Id__c = String.valueOf(contentDocumentId),
            File_Name__c = fileName,
            Status__c = AIDocIntakeService.FILE_STATUS_FAILED,
            Error_Detail__c = 'Prior file was deleted.'
        );
        return job.Id;
    }

    private static Id createCompletedSubmissionWithMissingFile(
        Id applicationId,
        String clientSubmissionId,
        String fileName
    ) {
        Id contentDocumentId = fakeContentDocumentId();
        Document_Intake_Job__c job = new Document_Intake_Job__c(
            Application__c = applicationId,
            Client_Submission_Id__c = clientSubmissionId,
            Client_Submission_Key__c = String.valueOf(applicationId) + ':' + clientSubmissionId,
            Payload_Hash__c = 'stale-hash-' + String.valueOf(System.currentTimeMillis()),
            Source__c = 'PORTAL',
            Status__c = AIDocIntakeService.JOB_STATUS_COMPLETE,
            Total_Files__c = 1,
            Completed_Files__c = 1
        );
        insert job;
        insert new Document_Intake_File__c(
            Intake_Job__c = job.Id,
            Item_Key__c = job.Client_Submission_Key__c + ':' + String.valueOf(contentDocumentId),
            ContentDocument_Id__c = String.valueOf(contentDocumentId),
            File_Name__c = fileName,
            Status__c = AIDocIntakeService.FILE_STATUS_COMPLETE
        );
        return job.Id;
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

    private static String fakeLibraryId() {
        return ContentWorkspace.SObjectType
            .getDescribe(SObjectDescribeOptions.DEFERRED)
            .getKeyPrefix() + String.valueOf(UserInfo.getOrganizationId()).right(12);
    }

    private static Id fakeFolderId() {
        return (Id) (ContentFolder.SObjectType
            .getDescribe(SObjectDescribeOptions.DEFERRED)
            .getKeyPrefix() + String.valueOf(UserInfo.getOrganizationId()).right(12));
    }

    private static Id fakeContentDocumentId() {
        return (Id) (ContentDocument.SObjectType
            .getDescribe(SObjectDescribeOptions.DEFERRED)
            .getKeyPrefix() + String.valueOf(UserInfo.getOrganizationId()).right(12));
    }

    private static void configureLibraryLookupForTest() {
        AIDocIntakeService.testLibraryIdOverride = fakeLibraryId();
        AIDocIntakeService.testTargetFolderIdOverride = fakeFolderId();
        AIDocIntakeService.testBypassLibraryMembership = true;
    }

    private static Map<String, Object> responseFromBody() {
        return (Map<String, Object>) JSON.deserializeUntyped(RestContext.response.responseBody.toString());
    }

    private static Map<String, Object> dataFrom(Map<String, Object> response) {
        return (Map<String, Object>) response.get('data');
    }

    private static Id idFrom(Object value) {
        return (Id) String.valueOf(value);
    }

    private static Integer intFrom(Object value) {
        return value instanceof Decimal ? ((Decimal) value).intValue() : Integer.valueOf(String.valueOf(value));
    }

    private static Document_Intake_Job__c loadJob(Id jobId) {
        return [
            SELECT Id, Status__c, Completed_Files__c, Error_Detail__c, Target_Folder_Id__c
            FROM Document_Intake_Job__c
            WHERE Id = :jobId
        ];
    }

    private static Document_Intake_File__c loadOnlyFile(Id jobId) {
        return [
            SELECT Id, ContentDocument_Id__c, File_Name__c, Content_Hash__c, Status__c,
                   Split_Job__c, Split_Result_JSON__c, Document_Category__c, Document_Type__c,
                   Mapping_Confidence__c, Error_Detail__c
            FROM Document_Intake_File__c
            WHERE Intake_Job__c = :jobId
            LIMIT 1
        ];
    }
}

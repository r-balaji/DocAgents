/**
 * REST API for portal document submissions.
 *
 * PUT /services/apexrest/document-submissions
 * GET /services/apexrest/document-submissions/{intakeJobId}
 */
@RestResource(urlMapping='/document-submissions/*')
global with sharing class AIDocIntakeRestResource {
    private static final String CONTENT_TYPE_JSON = 'application/json';

    /**
     * Accepts an idempotent document submission for async splitting and review.
     */
    @HttpPut
    global static void doPut() {
        RestResponse response = currentResponse();
        addJsonHeader(response);
        try {
            validatePutPath();
            if (RestContext.request.requestBody == null
                || RestContext.request.requestBody.size() == 0) {
                writeError(response, 400, 'Request body is required.');
                return;
            }

            AIDocIntakeService.PortalSubmissionRequest payload = parsePutPayload();
            AIDocIntakeService.SubmissionResult result =
                AIDocIntakeService.acceptPortalSubmission(payload);
            result.statusUrl = buildStatusUrl(result.jobId);

            writeResponse(
                response,
                202,
                successResponse(
                    result.created == true || result.refreshed == true
                        ? 'Submission accepted.'
                        : 'Submission already accepted.',
                    result
                )
            );
        } catch (AIDocIntakeService.IntakeException e) {
            writeError(response, e.statusCode, e.getMessage());
        } catch (JSONException e) {
            writeError(response, 400, 'Malformed JSON request body.');
        } catch (Exception e) {
            writeError(response, 500, 'Unable to process document submission.');
        }
    }

    private static AIDocIntakeService.PortalSubmissionRequest parsePutPayload() {
        String contentType = headerValue('Content-Type');
        if (String.isBlank(contentType) || contentType.toLowerCase().startsWith(CONTENT_TYPE_JSON)) {
            return (AIDocIntakeService.PortalSubmissionRequest) JSON.deserialize(
                RestContext.request.requestBody.toString(),
                AIDocIntakeService.PortalSubmissionRequest.class
            );
        }

        AIDocIntakeService.PortalSubmissionRequest payload =
            new AIDocIntakeService.PortalSubmissionRequest();
        payload.applicationId = headerValue('X-Application-Id');
        payload.fileName = headerValue('X-File-Name');
        payload.source = headerValue('X-Source');
        payload.fileBody = RestContext.request.requestBody;
        return payload;
    }

    private static String headerValue(String name) {
        if (RestContext.request == null || RestContext.request.headers == null) {
            return null;
        }
        if (RestContext.request.headers.containsKey(name)) {
            return RestContext.request.headers.get(name);
        }
        for (String key : RestContext.request.headers.keySet()) {
            if (key != null && key.equalsIgnoreCase(name)) {
                return RestContext.request.headers.get(key);
            }
        }
        return null;
    }

    /**
     * Retrieves the current state of a document submission.
     */
    @HttpGet
    global static void doGet() {
        RestResponse response = currentResponse();
        addJsonHeader(response);
        try {
            Id intakeJobId = parseStatusJobId();
            AIDocIntakeService.SubmissionResult result =
                AIDocIntakeService.getSubmission(intakeJobId);
            result.statusUrl = buildStatusUrl(result.jobId);

            writeResponse(response, 200, successResponse('Submission retrieved.', result));
        } catch (AIDocIntakeService.IntakeException e) {
            writeError(response, e.statusCode, e.getMessage());
        } catch (Exception e) {
            writeError(response, 500, 'Unable to retrieve document submission.');
        }
    }

    private static RestResponse currentResponse() {
        if (RestContext.response == null) {
            RestContext.response = new RestResponse();
        }
        return RestContext.response;
    }

    private static void addJsonHeader(RestResponse response) {
        response.addHeader('Content-Type', CONTENT_TYPE_JSON);
    }

    private static ApiResponse successResponse(String message, Object data) {
        ApiResponse apiResponse = new ApiResponse();
        apiResponse.success = true;
        apiResponse.message = message;
        apiResponse.data = data;
        return apiResponse;
    }

    private static void writeError(RestResponse response, Integer statusCode, String message) {
        ApiResponse apiResponse = new ApiResponse();
        apiResponse.success = false;
        apiResponse.message = message;
        writeResponse(response, statusCode, apiResponse);
    }

    private static void writeResponse(RestResponse response, Integer statusCode, ApiResponse apiResponse) {
        response.statusCode = statusCode;
        response.responseBody = Blob.valueOf(JSON.serialize(apiResponse));
    }

    private static String buildStatusUrl(Id jobId) {
        return '/services/apexrest/document-submissions/'
            + EncodingUtil.urlEncode(String.valueOf(jobId), 'UTF-8');
    }

    private static void validatePutPath() {
        String requestUri = RestContext.request.requestURI;
        List<String> parts = requestUri == null ? new List<String>() : requestUri.split('/');
        Integer rootIndex = findSegment(parts, 'document-submissions');
        if (rootIndex < 0 || parts.size() > rootIndex + 1) {
            throw AIDocIntakeService.error(400, 'Expected /document-submissions.');
        }
    }

    private static Id parseStatusJobId() {
        String requestUri = RestContext.request.requestURI;
        List<String> parts = requestUri == null ? new List<String>() : requestUri.split('/');
        Integer rootIndex = findSegment(parts, 'document-submissions');
        if (rootIndex < 0 || parts.size() <= rootIndex + 1) {
            throw AIDocIntakeService.error(400, 'Expected /document-submissions/{intakeJobId}.');
        }
        if (parts.size() > rootIndex + 2) {
            throw AIDocIntakeService.error(400, 'Expected only one intake job id path segment.');
        }
        return AIDocIntakeService.parseRecordId(
            EncodingUtil.urlDecode(parts[rootIndex + 1], 'UTF-8'),
            'Intake Job Id'
        );
    }

    private static Integer findSegment(List<String> parts, String segment) {
        for (Integer i = 0; i < parts.size(); i++) {
            if (parts[i] == segment) {
                return i;
            }
        }
        return -1;
    }

    private class ApiResponse {
        public Boolean success;
        public String message;
        public Object data;
    }

}

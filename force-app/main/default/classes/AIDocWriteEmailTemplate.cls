/**
 * Post-processes an AI-drafted borrower email and persists it on the Application.
 *
 * The Flow calls the AIDocBorrowerEmailCombined prompt directly via generatePromptResponse
 * and passes the raw response string into this action. This class does only what
 * Flow does poorly: truncate to fit the field length, and update the record with
 * graceful error handling so a save failure does not halt the rest of the flow.
 */
public with sharing class AIDocWriteEmailTemplate {

    private static final Integer MAX_EMAIL_LENGTH = 32768;

    @InvocableMethod(
        label='AI Doc - Save Borrower Email'
        description='Truncates and saves an AI-drafted borrower email to the Application.'
        category='AI Document Review'
    )
    public static List<Response> execute(List<Request> requests) {
        if (requests == null || requests.isEmpty()) {
            return new List<Response>();
        }

        List<Response> responses = initializeResponses(requests.size());
        List<PendingUpdate> pendingUpdates = collectPendingUpdates(requests, responses);
        saveUpdates(pendingUpdates, responses);
        return responses;
    }

    private static List<Response> initializeResponses(Integer responseCount) {
        List<Response> responses = new List<Response>();
        for (Integer i = 0; i < responseCount; i++) {
            responses.add(new Response());
        }
        return responses;
    }

    private static List<PendingUpdate> collectPendingUpdates(List<Request> requests, List<Response> responses) {
        List<PendingUpdate> pendingUpdates = new List<PendingUpdate>();
        for (Integer i = 0; i < requests.size(); i++) {
            Request req = requests[i];
            if (req == null || req.applicationId == null) {
                markMissingApplication(responses[i], req);
                continue;
            }

            String safeText = truncate(req.emailText);
            responses[i].emailTemplate = safeText;
            pendingUpdates.add(new PendingUpdate(i, new genesis__Applications__c(
                Id = req.applicationId,
                Email_Template__c = safeText
            )));
        }
        return pendingUpdates;
    }

    private static void saveUpdates(List<PendingUpdate> pendingUpdates, List<Response> responses) {
        if (pendingUpdates.isEmpty()) {
            return;
        }
        try {
            Database.SaveResult[] results = Database.update(toRecords(pendingUpdates), false, AccessLevel.USER_MODE);
            for (Integer i = 0; i < results.size(); i++) {
                applySaveResult(results[i], responses[pendingUpdates[i].responseIndex]);
            }
        } catch (Exception e) {
            for (PendingUpdate pendingUpdate : pendingUpdates) {
                markError(responses[pendingUpdate.responseIndex], e.getMessage());
            }
        }
    }

    private static List<genesis__Applications__c> toRecords(List<PendingUpdate> pendingUpdates) {
        List<genesis__Applications__c> records = new List<genesis__Applications__c>();
        for (PendingUpdate pendingUpdate : pendingUpdates) {
            records.add(pendingUpdate.record);
        }
        return records;
    }

    private static void applySaveResult(Database.SaveResult result, Response res) {
        if (result.isSuccess()) {
            res.success = true;
            return;
        }
        markError(res, result.getErrors()[0].getMessage());
    }

    private static void markMissingApplication(Response res, Request req) {
        res.emailTemplate = req == null || req.emailText == null ? '' : req.emailText;
        markError(res, 'Application Id is required.');
    }

    private static void markError(Response res, String message) {
        res.success = false;
        res.errorMessage = message;
    }

    private static String truncate(String emailText) {
        String safeText = emailText == null ? '' : emailText;
        return safeText.length() <= MAX_EMAIL_LENGTH ? safeText : safeText.substring(0, MAX_EMAIL_LENGTH);
    }

    private class PendingUpdate {
        private Integer responseIndex;
        private genesis__Applications__c record;

        private PendingUpdate(Integer responseIndex, genesis__Applications__c record) {
            this.responseIndex = responseIndex;
            this.record = record;
        }
    }

    public class Request {
        @InvocableVariable(label='Application Id' required=true)
        public Id applicationId;

        @InvocableVariable(label='Email Text' description='Raw email body from the AIDocBorrowerEmailCombined prompt response')
        public String emailText;
    }

    public class Response {
        @InvocableVariable(label='Success')
        public Boolean success;

        @InvocableVariable(label='Email Template')
        public String emailTemplate;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }
}

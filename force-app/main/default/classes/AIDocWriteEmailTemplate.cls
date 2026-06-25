/**
 * Post-processes an AI-drafted borrower email and persists it on the Application.
 *
 * The Flow calls the AIDocBorrowerEmail prompt directly via generatePromptResponse
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
        List<Response> out = new List<Response>();
        for (Request req : requests) {
            out.add(processOne(req));
        }
        return out;
    }

    private static Response processOne(Request req) {
        Response res = new Response();

        if (req == null || req.applicationId == null) {
            res.success = false;
            res.errorMessage = 'Application Id is required.';
            return res;
        }

        try {
            String emailText = req.emailText == null ? '' : req.emailText;
            String safeText = emailText.length() <= MAX_EMAIL_LENGTH ? emailText : emailText.substring(0, MAX_EMAIL_LENGTH);

            update new genesis__Applications__c(
                Id = req.applicationId,
                Email_Template__c = safeText
            );

            res.success = true;
            res.emailTemplate = safeText;
        } catch (Exception e) {
            res.success = false;
            res.errorMessage = e.getMessage();
            res.emailTemplate = req.emailText == null ? '' : req.emailText;
        }
        return res;
    }

    public class Request {
        @InvocableVariable(label='Application Id' required=true)
        public Id applicationId;

        @InvocableVariable(label='Email Text' description='Raw email body from the AIDocBorrowerEmail prompt response')
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

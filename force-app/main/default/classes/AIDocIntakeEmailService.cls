/**
 * Generates the borrower email draft after headless intake review stores AI verdicts.
 */
public with sharing class AIDocIntakeEmailService {
    @TestVisible
    private static final String EMAIL_FLOW_NAME = 'AIDocBorrowerEmailDraft';

    @TestVisible
    static String testStubEmailText;

    @TestVisible
    static Boolean testForceEmailFailure = false;

    /**
     * Generates and saves borrower email drafts for the applications tied to intake jobs.
     * @param intakeJobIds Intake jobs that finished AI review.
     * @throws SplitJobException when coverage, prompt generation, or persistence fails.
     */
    public static void generateAndSaveForIntakeJobs(Set<Id> intakeJobIds) {
        Map<Id, Boolean> includeFallbackByApplicationId =
            loadFallbackReviewSettingByApplicationId(intakeJobIds);
        if (includeFallbackByApplicationId.isEmpty()) {
            return;
        }

        List<String> errors = new List<String>();
        for (Id applicationId : includeFallbackByApplicationId.keySet()) {
            try {
                generateAndSaveForApplication(
                    applicationId,
                    includeFallbackByApplicationId.get(applicationId) == true
                );
            } catch (Exception e) {
                errors.add(e.getTypeName() + ': ' + e.getMessage());
            }
        }
        if (!errors.isEmpty()) {
            throw new SplitJobException(String.join(errors, ' | '));
        }
    }

    private static Map<Id, Boolean> loadFallbackReviewSettingByApplicationId(Set<Id> intakeJobIds) {
        Map<Id, Boolean> includeFallbackByApplicationId = new Map<Id, Boolean>();
        if (intakeJobIds == null || intakeJobIds.isEmpty()) {
            return includeFallbackByApplicationId;
        }

        for (Document_Intake_Job__c job : [
            SELECT Application__c, Source__c
            FROM Document_Intake_Job__c
            WHERE Id IN :intakeJobIds
            WITH USER_MODE
        ]) {
            if (job.Application__c != null) {
                Boolean includeFallback = includeFallbackByApplicationId.get(job.Application__c) == true
                    || AIDocIntakeReviewService.shouldAutoReviewFallbackCategory(job.Source__c);
                includeFallbackByApplicationId.put(job.Application__c, includeFallback);
            }
        }
        return includeFallbackByApplicationId;
    }

    private static void generateAndSaveForApplication(
        Id applicationId,
        Boolean includeFallbackCategory
    ) {
        AIDocCoverageCheck.Response coverage = loadCoverage(applicationId, includeFallbackCategory);
        validateCoverage(coverage);
        String emailText = invokeEmailFlow(coverage);
        saveEmailDraft(applicationId, emailText);
    }

    private static void validateCoverage(AIDocCoverageCheck.Response coverage) {
        if (coverage != null && coverage.isSuccess == true) {
            return;
        }
        if (coverage != null && !String.isBlank(coverage.errorMessage)) {
            throw new SplitJobException(coverage.errorMessage);
        }
        throw new SplitJobException('AI document coverage check failed before borrower email draft.');
    }

    private static void saveEmailDraft(Id applicationId, String emailText) {
        AIDocWriteEmailTemplate.Request writeRequest = new AIDocWriteEmailTemplate.Request();
        writeRequest.applicationId = applicationId;
        writeRequest.emailText = emailText;
        List<AIDocWriteEmailTemplate.Response> responses =
            AIDocWriteEmailTemplate.execute(new List<AIDocWriteEmailTemplate.Request>{ writeRequest });
        AIDocWriteEmailTemplate.Response response = responses.isEmpty() ? null : responses[0];
        if (response != null && response.success == true) {
            return;
        }
        if (response != null && !String.isBlank(response.errorMessage)) {
            throw new SplitJobException(response.errorMessage);
        }
        throw new SplitJobException('Borrower email draft could not be saved.');
    }

    private static AIDocCoverageCheck.Response loadCoverage(
        Id applicationId,
        Boolean includeFallbackCategory
    ) {
        AIDocCoverageCheck.Request request = new AIDocCoverageCheck.Request();
        request.applicationId = applicationId;
        request.includeFallbackCategory = includeFallbackCategory;
        List<AIDocCoverageCheck.Response> responses =
            AIDocCoverageCheck.execute(new List<AIDocCoverageCheck.Request>{ request });
        return responses.isEmpty() ? null : responses[0];
    }

    private static String invokeEmailFlow(AIDocCoverageCheck.Response coverage) {
        if (Test.isRunningTest() && testForceEmailFailure == true) {
            throw new SplitJobException('Forced borrower email failure.');
        }
        if (Test.isRunningTest()) {
            return String.isBlank(testStubEmailText)
                ? 'Dear Borrower,\n\nWe have everything we need and will be in touch shortly.\n\nBest regards,\nYour Loan Officer'
                : testStubEmailText;
        }

        Map<String, Object> inputs = new Map<String, Object>{
            'borrowerName' => coverage.borrowerName,
            'coverageJson' => coverage.coverageJson,
            'verdictsText' => coverage.reviewedClassificationJson,
            'sanityFindingsText' => coverage.reviewedSanityJson
        };
        Flow.Interview interview = Flow.Interview.createInterview(EMAIL_FLOW_NAME, inputs);
        interview.start();
        String emailText = (String) interview.getVariableValue('emailText');
        if (String.isBlank(emailText)) {
            throw new SplitJobException('Borrower email prompt returned no text.');
        }
        return emailText;
    }
}

/**
 * Batch wrapper for portal/API document intake review.
 */
public with sharing class AIDocIntakeReviewBatch
    implements Database.Batchable<String>, Database.AllowsCallouts, Database.Stateful {
    private final Set<Id> intakeJobIds = new Set<Id>();
    private final List<String> errors = new List<String>();

    /**
     * Creates a review batch for one or more intake jobs.
     * @param intakeJobIds Intake jobs whose mapped files should be reviewed.
     * @throws SplitJobException when no intake job id is supplied.
     */
    public AIDocIntakeReviewBatch(List<Id> intakeJobIds) {
        if (intakeJobIds != null) {
            for (Id intakeJobId : intakeJobIds) {
                if (intakeJobId != null) {
                    this.intakeJobIds.add(intakeJobId);
                }
            }
        }
        if (this.intakeJobIds.isEmpty()) {
            throw new SplitJobException('intakeJobIds are required.');
        }
    }

    /**
     * Loads current unreviewed file/category rows.
     * @param context Batch context.
     * @return Encoded review rows to process.
     */
    public Iterable<String> start(Database.BatchableContext context) {
        try {
            return AIDocIntakeReviewService.buildReviewRows(intakeJobIds);
        } catch (Exception e) {
            errors.add(e.getTypeName() + ': ' + e.getMessage());
            return new List<String>();
        }
    }

    /**
     * Runs one or more file reviews. The intake service launches this batch with scope size 1.
     * @param context Batch context.
     * @param scope Encoded review rows in this batch scope.
     */
    public void execute(Database.BatchableContext context, List<String> scope) {
        try {
            AIDocIntakeReviewService.reviewEncodedRows(scope);
        } catch (Exception e) {
            errors.add(e.getTypeName() + ': ' + e.getMessage());
        }
    }

    /**
     * Drafts the borrower email and moves intake file rows out of Reviewing after all review rows are handled.
     * @param context Batch context.
     */
    public void finish(Database.BatchableContext context) {
        if (errors.isEmpty()) {
            try {
                AIDocIntakeEmailService.generateAndSaveForIntakeJobs(intakeJobIds);
            } catch (Exception e) {
                errors.add('[Borrower email] ' + e.getTypeName() + ': ' + e.getMessage());
            }
        }

        if (errors.isEmpty()) {
            AIDocIntakeService.markReviewComplete(
                intakeJobIds,
                'AI review and borrower email draft completed for mapped intake files.'
            );
            return;
        }

        AIDocIntakeService.markReviewFailed(
            intakeJobIds,
            String.join(errors, ' | ')
        );
    }
}

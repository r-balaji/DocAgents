/**
 * Async handoff for accepted document intake submissions.
 */
public with sharing class AIDocIntakeQueueable implements Queueable {
    private final Id intakeJobId;

    /**
     * @param intakeJobId Document intake job to process.
     * @throws SplitJobException when the intake job id is missing.
     */
    public AIDocIntakeQueueable(Id intakeJobId) {
        if (intakeJobId == null) {
            throw new SplitJobException('intakeJobId is required.');
        }
        this.intakeJobId = intakeJobId;
    }

    /**
     * Starts splitter jobs for accepted file items.
     * @param context Queueable context.
     */
    public void execute(QueueableContext context) {
        AIDocIntakeService.processAcceptedFiles(intakeJobId);
    }
}

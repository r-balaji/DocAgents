/**
 * Async handoff that maps split output files to application document categories.
 */
@SuppressWarnings('PMD.QueueableWithoutFinalizer')
public with sharing class AIDocIntakeCategoryMappingQueueable implements Queueable, Database.AllowsCallouts {
    private final Id splitJobId;

    /**
     * Creates a mapping job for one completed split job.
     * @param splitJobId Completed split job whose outputs need category placement.
     * @throws SplitJobException when the split job id is missing.
     */
    public AIDocIntakeCategoryMappingQueueable(Id splitJobId) {
        if (splitJobId == null) {
            throw new SplitJobException('splitJobId is required.');
        }
        this.splitJobId = splitJobId;
    }

    /**
     * Runs LLM-assisted category mapping and places all split output files.
     * @param context Queueable context.
     */
    public void execute(QueueableContext context) {
        AIDocIntakeCategoryMappingService.mapSplitOutputs(splitJobId);
    }
}

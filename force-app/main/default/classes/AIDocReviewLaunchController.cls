/**
 * LWC controller for deciding whether AI Document Review can use cached results
 * or needs to launch the review Flow.
 */
public with sharing class AIDocReviewLaunchController {
    private static final String USER_ERROR_MESSAGE = 'Unable to prepare AI document review.';

    /**
     * Checks the current review state for an application.
     * @param applicationId Application record Id.
     * @param includeFallbackCategory Whether to include the configured fallback category in this review run.
     * @return Launch state with cached review JSON when every selected current file is already reviewed.
     * @throws AuraHandledException when the application Id is missing or review state cannot be loaded.
     */
    @AuraEnabled
    public static LaunchState getLaunchState(Id applicationId, Boolean includeFallbackCategory) {
        validateApplicationId(applicationId);

        try {
            AIDocCoverageCheck.Response coverage = loadCoverage(
                applicationId,
                includeFallbackCategory == true
            );
            LaunchState state = new LaunchState();
            state.isSuccess = coverage.isSuccess;
            state.errorMessage = coverage.errorMessage;
            state.errorType = coverage.errorType;
            state.coverageJson = coverage.coverageJson;
            state.classificationJson = coverage.reviewedClassificationJson;
            state.sanityJson = coverage.reviewedSanityJson;
            state.totalCount = coverage.totalCount;
            state.filledCount = coverage.filledCount;
            state.missingCount = coverage.missingCount;
            state.borrowerName = coverage.borrowerName;
            state.unreviewedFileCount = coverage.encodedRows == null ? 0 : coverage.encodedRows.size();
            state.canShowCachedReview = canShowCachedReview(coverage);
            state.shouldRunFlow = !state.canShowCachedReview;
            return state;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(USER_ERROR_MESSAGE);
        }
    }

    /**
     * Clears stored AI review feedback for active document categories on an application.
     * @param applicationId Application record Id.
     * @return Clear operation result including number of categories reset.
     * @throws AuraHandledException when the application Id is missing or feedback cannot be cleared.
     */
    @AuraEnabled
    public static ClearResult clearReview(Id applicationId) {
        validateApplicationId(applicationId);

        try {
            List<clcommon__Document_Category__c> updates = buildClearUpdates(applicationId);
            ClearResult result = new ClearResult();
            result.success = true;
            Database.SaveResult[] applicationResults = Database.update(
                new List<genesis__Applications__c>{
                    new genesis__Applications__c(
                        Id = applicationId,
                        Email_Template__c = ''
                    )
                },
                false,
                AccessLevel.USER_MODE
            );
            if (!applicationResults[0].isSuccess()) {
                throw new AuraHandledException('Unable to clear the AI review email draft.');
            }
            if (updates.isEmpty()) {
                return result;
            }

            Database.SaveResult[] saveResults = Database.update(updates, false, AccessLevel.USER_MODE);
            collectClearErrors(saveResults, result);
            result.success = result.errorCount == 0;
            return result;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Unable to clear AI review.');
        }
    }

    private static void validateApplicationId(Id applicationId) {
        if (applicationId == null) {
            throw new AuraHandledException('Application Id is required.');
        }
    }

    private static AIDocCoverageCheck.Response loadCoverage(
        Id applicationId,
        Boolean includeFallbackCategory
    ) {
        AIDocCoverageCheck.Request req = new AIDocCoverageCheck.Request();
        req.applicationId = applicationId;
        req.includeFallbackCategory = includeFallbackCategory;
        List<AIDocCoverageCheck.Response> responses =
            AIDocCoverageCheck.execute(new List<AIDocCoverageCheck.Request>{ req });
        if (responses.isEmpty()) {
            throw new AuraHandledException(USER_ERROR_MESSAGE);
        }
        return responses[0];
    }

    private static Boolean canShowCachedReview(AIDocCoverageCheck.Response coverage) {
        if (coverage == null || coverage.isSuccess != true) {
            return false;
        }
        if (coverage.encodedRows != null && !coverage.encodedRows.isEmpty()) {
            return false;
        }
        return coverage.filledCount != null
            && coverage.filledCount > 0
            && (hasJsonItems(coverage.reviewedClassificationJson) || hasJsonItems(coverage.reviewedSanityJson));
    }

    private static Boolean hasJsonItems(String rawJson) {
        if (String.isBlank(rawJson)) {
            return false;
        }

        try {
            Object parsed = JSON.deserializeUntyped(rawJson);
            if (!(parsed instanceof Map<String, Object>)) {
                return false;
            }

            Object items = ((Map<String, Object>) parsed).get('items');
            return items instanceof List<Object> && !((List<Object>) items).isEmpty();
        } catch (Exception ignored) {
            return false;
        }
    }

    private static List<clcommon__Document_Category__c> buildClearUpdates(Id applicationId) {
        List<clcommon__Document_Category__c> updates = new List<clcommon__Document_Category__c>();
        for (clcommon__Document_Category__c category : [
            SELECT Id, AI_Reviewed__c, AI_Review_Feedback_JSON__c
            FROM clcommon__Document_Category__c
            WHERE genesis__Application__c = :applicationId
            AND clcommon__Active__c = true
            WITH USER_MODE
            LIMIT 5000
        ]) {
            if (category.AI_Reviewed__c != true && String.isBlank(category.AI_Review_Feedback_JSON__c)) {
                continue;
            }
            updates.add(new clcommon__Document_Category__c(
                Id = category.Id,
                AI_Reviewed__c = false,
                AI_Review_Feedback_JSON__c = null
            ));
        }
        return updates;
    }

    private static void collectClearErrors(Database.SaveResult[] saveResults, ClearResult result) {
        result.errorCount = 0;
        result.clearedCount = 0;
        for (Database.SaveResult saveResult : saveResults) {
            if (saveResult.isSuccess()) {
                result.clearedCount++;
                continue;
            }

            result.errorCount++;
            if (String.isBlank(result.errorMessage)) {
                Database.Error err = saveResult.getErrors()[0];
                result.errorMessage = err.getMessage();
                result.errorType = String.valueOf(err.getStatusCode());
            }
        }
    }

    /**
     * Launch decision consumed by the AI Document Review button.
     */
    public class LaunchState {
        @AuraEnabled public Boolean isSuccess;
        @AuraEnabled public Boolean canShowCachedReview;
        @AuraEnabled public Boolean shouldRunFlow;
        @AuraEnabled public String coverageJson;
        @AuraEnabled public String classificationJson;
        @AuraEnabled public String sanityJson;
        @AuraEnabled public Integer totalCount;
        @AuraEnabled public Integer filledCount;
        @AuraEnabled public Integer missingCount;
        @AuraEnabled public Integer unreviewedFileCount;
        @AuraEnabled public String borrowerName;
        @AuraEnabled public String errorMessage;
        @AuraEnabled public String errorType;
    }

    /**
     * Result returned after clearing cached AI review feedback.
     */
    public class ClearResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public Integer clearedCount;
        @AuraEnabled public Integer errorCount;
        @AuraEnabled public String errorMessage;
        @AuraEnabled public String errorType;

        /**
         * Initializes clear counters.
         */
        public ClearResult() {
            this.clearedCount = 0;
            this.errorCount = 0;
        }
    }
}

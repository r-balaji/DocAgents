/**
 * Stores AI Document Review verdicts by ContentDocumentId on the document category.
 */
public with sharing class AIDocReviewResultStore {
    /**
     * Merges a newly generated per-file review result into the category feedback JSON.
     * @param requests Flow requests containing category, ContentDocumentId, and prompt output.
     * @return Per-request save status.
     */
    @InvocableMethod(
        label='AI Doc - Save Review Result'
        description='Stores AI Document Review output by ContentDocumentId on the document category.'
        category='AI Document Review'
    )
    public static List<Response> execute(List<Request> requests) {
        if (requests == null || requests.isEmpty()) {
            return new List<Response>();
        }

        List<Response> responses = initializeResponses(requests.size());
        Set<Id> categoryIds = collectCategoryIds(requests);
        Map<Id, clcommon__Document_Category__c> categoriesById = loadCategories(categoryIds);
        Map<Id, Set<Id>> currentDocIdsByCategoryId =
            AIDocReviewFileSelector.selectCurrentContentDocumentIdsByCategoryUserMode(categoryIds);
        Map<Id, Map<String, Object>> feedbackByCategoryId = new Map<Id, Map<String, Object>>();
        Map<Id, clcommon__Document_Category__c> updatesByCategoryId = new Map<Id, clcommon__Document_Category__c>();
        Map<Id, List<Integer>> responseIndexesByCategoryId = new Map<Id, List<Integer>>();

        for (Integer i = 0; i < requests.size(); i++) {
            Request req = requests[i];
            Response res = responses[i];
            if (!validateRequest(req, res)) {
                continue;
            }
            clcommon__Document_Category__c category = categoriesById.get(req.documentCategoryId);
            if (category == null) {
                markError(res, 'NOT_FOUND', 'Document category was not found.');
                continue;
            }

            Map<String, Object> feedbackByDocId = getFeedbackForCategory(category, feedbackByCategoryId);
            String documentName = category.clcommon__Category_Name__c;
            String normalizedClassificationJson = normalizeDocumentName(req.classificationJson, documentName);
            String normalizedSanityJson = normalizeDocumentName(req.sanityJson, documentName);
            feedbackByDocId.put(String.valueOf(req.fileContentDocumentId), new Map<String, Object>{
                AIDocReviewFeedbackUtil.CLASSIFICATION_JSON_KEY => normalizedClassificationJson,
                AIDocReviewFeedbackUtil.SANITY_JSON_KEY => normalizedSanityJson
            });

            Boolean allFilesReviewed = AIDocReviewFeedbackUtil.hasReviewForEveryFile(
                feedbackByDocId,
                currentDocIdsByCategoryId.get(req.documentCategoryId)
            );
            updatesByCategoryId.put(req.documentCategoryId, new clcommon__Document_Category__c(
                Id = req.documentCategoryId,
                AI_Reviewed__c = allFilesReviewed,
                AI_Review_Feedback_JSON__c = JSON.serialize(feedbackByDocId)
            ));
            if (!responseIndexesByCategoryId.containsKey(req.documentCategoryId)) {
                responseIndexesByCategoryId.put(req.documentCategoryId, new List<Integer>());
            }
            responseIndexesByCategoryId.get(req.documentCategoryId).add(i);
            res.isReviewed = allFilesReviewed;
            res.classificationJson = normalizedClassificationJson;
            res.sanityJson = normalizedSanityJson;
            res.reviewFeedbackJson = JSON.serialize(feedbackByDocId);
        }

        saveUpdates(updatesByCategoryId.values(), responseIndexesByCategoryId, responses);
        return responses;
    }

    /**
     * Rewrites each item.documentName in a prompt JSON payload to the supplied category display name.
     * @param rawJson Prompt JSON payload to normalize.
     * @param documentName Category display name for the reviewed document slot.
     * @return Normalized JSON, or the original payload if it cannot be parsed.
     */
    public static String normalizeDocumentName(String rawJson, String documentName) {
        return AIDocReviewJsonUtil.normalizeDocumentName(rawJson, documentName);
    }

    /**
     * Recalculates the category-level reviewed flag after file links change.
     * @param links ContentDocumentLink records from trigger context.
     */
    public static void recalculateForContentDocumentLinks(List<ContentDocumentLink> links) {
        AIDocReviewStateRecalculator.recalculateReviewFlags(
            AIDocReviewStateRecalculator.extractDocumentCategoryIds(links)
        );
    }

    /**
     * Recalculates review state after product file-association rows change.
     * @param newAssociations New trigger-context association rows, when available.
     * @param oldAssociations Old trigger-context association rows, when available.
     */
    public static void recalculateForCategoryAttachmentAssociations(
        List<clcommon__Category_Attachment_Association__c> newAssociations,
        List<clcommon__Category_Attachment_Association__c> oldAssociations
    ) {
        Set<Id> documentCategoryIds =
            AIDocReviewStateRecalculator.extractDocumentCategoryIdsFromAssociations(newAssociations);
        documentCategoryIds.addAll(
            AIDocReviewStateRecalculator.extractDocumentCategoryIdsFromAssociations(oldAssociations)
        );
        AIDocReviewStateRecalculator.recalculateReviewFlags(documentCategoryIds);
    }

    /**
     * Recalculates review state for the given document categories.
     * @param documentCategoryIds Category Ids whose active file set should be re-evaluated.
     */
    public static void recalculateForDocumentCategoryIds(Set<Id> documentCategoryIds) {
        AIDocReviewStateRecalculator.recalculateReviewFlags(documentCategoryIds);
    }

    private static List<Response> initializeResponses(Integer responseCount) {
        List<Response> responses = new List<Response>();
        for (Integer i = 0; i < responseCount; i++) {
            Response res = new Response();
            res.isSuccess = true;
            res.isReviewed = false;
            responses.add(res);
        }
        return responses;
    }

    private static Set<Id> collectCategoryIds(List<Request> requests) {
        Set<Id> categoryIds = new Set<Id>();
        for (Request req : requests) {
            if (req != null && req.documentCategoryId != null) {
                categoryIds.add(req.documentCategoryId);
            }
        }
        return categoryIds;
    }

    private static Map<Id, clcommon__Document_Category__c> loadCategories(Set<Id> categoryIds) {
        if (categoryIds.isEmpty()) {
            return new Map<Id, clcommon__Document_Category__c>();
        }
        return new Map<Id, clcommon__Document_Category__c>([
            SELECT Id, clcommon__Category_Name__c, AI_Review_Feedback_JSON__c
            FROM clcommon__Document_Category__c
            WHERE Id IN :categoryIds
            WITH USER_MODE
        ]);
    }

    private static Boolean validateRequest(Request req, Response res) {
        if (req == null || req.documentCategoryId == null) {
            markError(res, 'MISSING_INPUT', 'Document Category Id is required.');
            return false;
        }
        if (req.fileContentDocumentId == null) {
            markError(res, 'MISSING_INPUT', 'File ContentDocument Id is required.');
            return false;
        }
        if (String.isBlank(req.classificationJson) || String.isBlank(req.sanityJson)) {
            markError(res, 'MISSING_INPUT', 'Classification JSON and Sanity JSON are required.');
            return false;
        }
        return true;
    }

    private static Map<String, Object> getFeedbackForCategory(
        clcommon__Document_Category__c category,
        Map<Id, Map<String, Object>> feedbackByCategoryId
    ) {
        if (!feedbackByCategoryId.containsKey(category.Id)) {
            feedbackByCategoryId.put(
                category.Id,
                AIDocReviewFeedbackUtil.parseFeedbackByDocumentId(category.AI_Review_Feedback_JSON__c)
            );
        }
        return feedbackByCategoryId.get(category.Id);
    }

    private static void saveUpdates(
        List<clcommon__Document_Category__c> updates,
        Map<Id, List<Integer>> responseIndexesByCategoryId,
        List<Response> responses
    ) {
        if (updates.isEmpty()) {
            return;
        }

        Database.SaveResult[] results = Database.update(updates, false, AccessLevel.USER_MODE);
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                continue;
            }
            clcommon__Document_Category__c updateRecord = updates[i];
            Database.Error err = results[i].getErrors()[0];
            for (Integer responseIndex : responseIndexesByCategoryId.get(updateRecord.Id)) {
                Response res = responses[responseIndex];
                markError(res, String.valueOf(err.getStatusCode()), err.getMessage());
                res.isReviewed = false;
            }
        }
    }

    private static void markError(Response res, String errorType, String errorMessage) {
        res.isSuccess = false;
        res.errorType = errorType;
        res.errorMessage = errorMessage;
    }

    public class Request {
        @InvocableVariable(label='Document Category Id' description='Leaf clcommon__Document_Category__c record being reviewed' required=true)
        public Id documentCategoryId;

        @InvocableVariable(label='File ContentDocument Id' description='ContentDocument Id currently attached to the category' required=true)
        public Id fileContentDocumentId;

        @InvocableVariable(label='Classification JSON' description='Fresh review classification JSON output to store' required=true)
        public String classificationJson;

        @InvocableVariable(label='Sanity JSON' description='Fresh review sanity JSON output to store' required=true)
        public String sanityJson;
    }

    public class Response {
        @InvocableVariable(label='Success' description='Whether the save action succeeded')
        public Boolean isSuccess;

        @InvocableVariable(label='All Files Reviewed' description='True when every current file on the category has a stored verdict')
        public Boolean isReviewed;

        @InvocableVariable(label='Classification JSON' description='Normalized classification JSON for this file')
        public String classificationJson;

        @InvocableVariable(label='Sanity JSON' description='Normalized sanity JSON for this file')
        public String sanityJson;

        @InvocableVariable(label='Review Feedback JSON' description='Updated ContentDocumentId-to-review JSON map')
        public String reviewFeedbackJson;

        @InvocableVariable(label='Error Message' description='Error details if the action failed')
        public String errorMessage;

        @InvocableVariable(label='Error Type' description='Exception or platform error type if the action failed')
        public String errorType;
    }
}

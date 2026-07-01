/**
 * Stores AI Document Review verdicts by ContentDocumentId on the document category.
 */
public with sharing class AIDocReviewResultStore {
    private static final String CLASSIFICATION_JSON_KEY = 'classificationJson';
    private static final String SANITY_JSON_KEY = 'sanityJson';

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
        Map<Id, Set<Id>> currentDocIdsByCategoryId = loadCurrentContentDocumentIdsUserMode(categoryIds);
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
            feedbackByDocId.put(String.valueOf(req.fileContentDocumentId), new Map<String, Object>{
                CLASSIFICATION_JSON_KEY => req.classificationJson,
                SANITY_JSON_KEY => req.sanityJson
            });

            Boolean allFilesReviewed = hasReviewForEveryFile(feedbackByDocId, currentDocIdsByCategoryId.get(req.documentCategoryId));
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
            res.reviewFeedbackJson = JSON.serialize(feedbackByDocId);
        }

        saveUpdates(updatesByCategoryId.values(), responseIndexesByCategoryId, responses);
        return responses;
    }

    /**
     * Recalculates the category-level reviewed flag after file links change.
     * @param links ContentDocumentLink records from trigger context.
     */
    public static void recalculateForContentDocumentLinks(List<ContentDocumentLink> links) {
        recalculateReviewFlags(extractDocumentCategoryIds(links));
    }

    @SuppressWarnings('PMD.ApexCRUDViolation')
    @TestVisible
    private static void recalculateReviewFlags(Set<Id> documentCategoryIds) {
        if (documentCategoryIds == null || documentCategoryIds.isEmpty()) {
            return;
        }

        Map<Id, clcommon__Document_Category__c> categoriesById = new Map<Id, clcommon__Document_Category__c>([
            SELECT Id, AI_Reviewed__c, AI_Review_Feedback_JSON__c
            FROM clcommon__Document_Category__c
            WHERE Id IN :documentCategoryIds
        ]);
        Map<Id, Set<Id>> currentDocIdsByCategoryId = loadCurrentContentDocumentIdsSystemMode(documentCategoryIds);

        List<clcommon__Document_Category__c> updates = new List<clcommon__Document_Category__c>();
        for (clcommon__Document_Category__c category : categoriesById.values()) {
            Boolean allFilesReviewed = hasReviewForEveryFile(
                parseFeedbackByDocumentId(category.AI_Review_Feedback_JSON__c),
                currentDocIdsByCategoryId.get(category.Id)
            );
            if (category.AI_Reviewed__c != allFilesReviewed) {
                updates.add(new clcommon__Document_Category__c(
                    Id = category.Id,
                    AI_Reviewed__c = allFilesReviewed
                ));
            }
        }
        if (!updates.isEmpty()) {
            Database.update(updates, false);
        }
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
            SELECT Id, AI_Review_Feedback_JSON__c
            FROM clcommon__Document_Category__c
            WHERE Id IN :categoryIds
            WITH USER_MODE
        ]);
    }

    private static Map<Id, Set<Id>> loadCurrentContentDocumentIdsUserMode(Set<Id> categoryIds) {
        Map<Id, Set<Id>> docIdsByCategoryId = new Map<Id, Set<Id>>();
        if (categoryIds == null || categoryIds.isEmpty()) {
            return docIdsByCategoryId;
        }

        for (ContentDocumentLink link : [
            SELECT LinkedEntityId, ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :categoryIds
            WITH USER_MODE
        ]) {
            addContentDocumentId(docIdsByCategoryId, link);
        }
        return docIdsByCategoryId;
    }

    @SuppressWarnings('PMD.ApexCRUDViolation')
    private static Map<Id, Set<Id>> loadCurrentContentDocumentIdsSystemMode(Set<Id> categoryIds) {
        Map<Id, Set<Id>> docIdsByCategoryId = new Map<Id, Set<Id>>();
        if (categoryIds == null || categoryIds.isEmpty()) {
            return docIdsByCategoryId;
        }

        for (ContentDocumentLink link : [
            SELECT LinkedEntityId, ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId IN :categoryIds
        ]) {
            addContentDocumentId(docIdsByCategoryId, link);
        }
        return docIdsByCategoryId;
    }

    private static void addContentDocumentId(Map<Id, Set<Id>> docIdsByCategoryId, ContentDocumentLink link) {
        if (!docIdsByCategoryId.containsKey(link.LinkedEntityId)) {
            docIdsByCategoryId.put(link.LinkedEntityId, new Set<Id>());
        }
        docIdsByCategoryId.get(link.LinkedEntityId).add(link.ContentDocumentId);
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
            feedbackByCategoryId.put(category.Id, parseFeedbackByDocumentId(category.AI_Review_Feedback_JSON__c));
        }
        return feedbackByCategoryId.get(category.Id);
    }

    private static Map<String, Object> parseFeedbackByDocumentId(String feedbackJson) {
        Map<String, Object> feedbackByDocId = new Map<String, Object>();
        if (String.isBlank(feedbackJson)) {
            return feedbackByDocId;
        }

        try {
            Object parsed = JSON.deserializeUntyped(feedbackJson);
            if (parsed instanceof Map<String, Object>) {
                feedbackByDocId.putAll((Map<String, Object>) parsed);
            }
        } catch (Exception ignored) {
            return new Map<String, Object>();
        }
        return feedbackByDocId;
    }

    private static Boolean hasReviewForEveryFile(Map<String, Object> feedbackByDocId, Set<Id> currentDocIds) {
        if (currentDocIds == null || currentDocIds.isEmpty()) {
            return false;
        }
        for (Id docId : currentDocIds) {
            if (!hasCompleteReview(feedbackByDocId.get(String.valueOf(docId)))) {
                return false;
            }
        }
        return true;
    }

    private static Boolean hasCompleteReview(Object reviewValue) {
        if (!(reviewValue instanceof Map<String, Object>)) {
            return false;
        }
        Map<String, Object> review = (Map<String, Object>) reviewValue;
        return String.isNotBlank(valueAsString(review.get(CLASSIFICATION_JSON_KEY)))
            && String.isNotBlank(valueAsString(review.get(SANITY_JSON_KEY)));
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

    private static Set<Id> extractDocumentCategoryIds(List<ContentDocumentLink> links) {
        Set<Id> documentCategoryIds = new Set<Id>();
        String categoryPrefix = clcommon__Document_Category__c.SObjectType
            .getDescribe(SObjectDescribeOptions.DEFERRED)
            .getKeyPrefix();
        for (ContentDocumentLink link : links) {
            if (link != null
                && link.LinkedEntityId != null
                && String.valueOf(link.LinkedEntityId).startsWith(categoryPrefix)) {
                documentCategoryIds.add(link.LinkedEntityId);
            }
        }
        return documentCategoryIds;
    }

    private static String valueAsString(Object value) {
        return value == null ? '' : String.valueOf(value);
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

        @InvocableVariable(label='Classification JSON' description='Fresh AIDocClassifyFile prompt output to store' required=true)
        public String classificationJson;

        @InvocableVariable(label='Sanity JSON' description='Fresh AIDocSanityCheck prompt output to store' required=true)
        public String sanityJson;
    }

    public class Response {
        @InvocableVariable(label='Success' description='Whether the save action succeeded')
        public Boolean isSuccess;

        @InvocableVariable(label='All Files Reviewed' description='True when every current file on the category has a stored verdict')
        public Boolean isReviewed;

        @InvocableVariable(label='Review Feedback JSON' description='Updated ContentDocumentId-to-review JSON map')
        public String reviewFeedbackJson;

        @InvocableVariable(label='Error Message' description='Error details if the action failed')
        public String errorMessage;

        @InvocableVariable(label='Error Type' description='Exception or platform error type if the action failed')
        public String errorType;
    }
}

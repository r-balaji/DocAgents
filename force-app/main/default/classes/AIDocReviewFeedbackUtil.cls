/**
 * Handles cached AI review feedback keyed by ContentDocumentId.
 */
public inherited sharing class AIDocReviewFeedbackUtil {
    public static final String CLASSIFICATION_JSON_KEY = 'classificationJson';
    public static final String SANITY_JSON_KEY = 'sanityJson';

    /**
     * Parses the category feedback JSON into the stored ContentDocumentId map.
     * @param feedbackJson Serialized category review feedback.
     * @return Feedback map keyed by ContentDocumentId string.
     */
    public static Map<String, Object> parseFeedbackByDocumentId(String feedbackJson) {
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

    /**
     * Parses cached review entries into typed stored-review values.
     * @param feedbackJson Serialized category review feedback.
     * @return Stored reviews keyed by ContentDocumentId string.
     */
    public static Map<String, StoredReview> parseStoredReviews(String feedbackJson) {
        Map<String, StoredReview> reviewsByDocId = new Map<String, StoredReview>();
        Map<String, Object> feedbackByDocId = parseFeedbackByDocumentId(feedbackJson);
        for (String docId : feedbackByDocId.keySet()) {
            addStoredReview(reviewsByDocId, docId, feedbackByDocId.get(docId));
        }
        return reviewsByDocId;
    }

    /**
     * Keeps only cached feedback entries that still correspond to current live files.
     * @param feedbackByDocId Existing feedback keyed by ContentDocumentId string.
     * @param currentDocIds Current live ContentDocument ids.
     * @return Feedback map pruned to current live file ids.
     */
    public static Map<String, Object> keepCurrentFeedbackEntries(
        Map<String, Object> feedbackByDocId,
        Set<Id> currentDocIds
    ) {
        Map<String, Object> currentFeedbackByDocId = new Map<String, Object>();
        if (feedbackByDocId == null || feedbackByDocId.isEmpty() || currentDocIds == null || currentDocIds.isEmpty()) {
            return currentFeedbackByDocId;
        }

        Set<String> currentDocIdKeys = toStringSet(currentDocIds);
        for (String docIdKey : feedbackByDocId.keySet()) {
            if (currentDocIdKeys.contains(docIdKey)) {
                currentFeedbackByDocId.put(docIdKey, feedbackByDocId.get(docIdKey));
            }
        }
        return currentFeedbackByDocId;
    }

    /**
     * Serializes feedback to null when the cache is empty.
     * @param feedbackByDocId Feedback map keyed by ContentDocumentId string.
     * @return Serialized feedback JSON, or null for no feedback.
     */
    public static String serializeFeedback(Map<String, Object> feedbackByDocId) {
        if (feedbackByDocId == null || feedbackByDocId.isEmpty()) {
            return null;
        }
        return JSON.serialize(feedbackByDocId);
    }

    /**
     * Checks whether every current file has both classification and sanity JSON stored.
     * @param feedbackByDocId Feedback map keyed by ContentDocumentId string.
     * @param currentDocIds Current live ContentDocument ids.
     * @return True when every current file has a complete cached review.
     */
    public static Boolean hasReviewForEveryFile(Map<String, Object> feedbackByDocId, Set<Id> currentDocIds) {
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

    private static void addStoredReview(Map<String, StoredReview> reviewsByDocId, String docId, Object rawReview) {
        if (rawReview instanceof Map<String, Object>) {
            Map<String, Object> reviewMap = (Map<String, Object>) rawReview;
            reviewsByDocId.put(docId, new StoredReview(
                valueAsString(reviewMap.get(CLASSIFICATION_JSON_KEY)),
                valueAsString(reviewMap.get(SANITY_JSON_KEY))
            ));
        }
    }

    private static Set<String> toStringSet(Set<Id> ids) {
        Set<String> idStrings = new Set<String>();
        for (Id recordId : ids) {
            idStrings.add(String.valueOf(recordId));
        }
        return idStrings;
    }

    private static Boolean hasCompleteReview(Object reviewValue) {
        if (!(reviewValue instanceof Map<String, Object>)) {
            return false;
        }
        Map<String, Object> review = (Map<String, Object>) reviewValue;
        return String.isNotBlank(valueAsString(review.get(CLASSIFICATION_JSON_KEY)))
            && String.isNotBlank(valueAsString(review.get(SANITY_JSON_KEY)));
    }

    private static String valueAsString(Object value) {
        return value == null ? '' : String.valueOf(value);
    }

    public class StoredReview {
        public String classificationJson;
        public String sanityJson;

        public StoredReview(String classificationJson, String sanityJson) {
            this.classificationJson = classificationJson;
            this.sanityJson = sanityJson;
        }

        public Boolean hasCompleteReview() {
            return String.isNotBlank(classificationJson) && String.isNotBlank(sanityJson);
        }
    }
}

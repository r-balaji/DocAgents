/**
 * Shared JSON helpers for AI Document Review prompt payloads.
 */
public inherited sharing class AIDocReviewJsonUtil {
    private static final String ITEMS_KEY = 'items';
    private static final String DOCUMENT_NAME_KEY = 'documentName';

    /**
     * Rewrites each item.documentName in a prompt JSON payload to the supplied category display name.
     * @param rawJson Prompt JSON payload to normalize.
     * @param documentName Category display name for the reviewed document slot.
     * @return Normalized JSON, or the original payload if it cannot be parsed.
     */
    public static String normalizeDocumentName(String rawJson, String documentName) {
        if (String.isBlank(rawJson) || String.isBlank(documentName)) {
            return rawJson;
        }

        String cleaned = extractJsonObject(rawJson);
        if (String.isBlank(cleaned)) {
            return rawJson;
        }

        try {
            Object parsed = JSON.deserializeUntyped(cleaned);
            if (!(parsed instanceof Map<String, Object>)) {
                return rawJson;
            }

            Map<String, Object> payload = (Map<String, Object>) parsed;
            Object items = payload.get(ITEMS_KEY);
            if (!(items instanceof List<Object>)) {
                return rawJson;
            }

            for (Object rawItem : (List<Object>) items) {
                if (rawItem instanceof Map<String, Object>) {
                    ((Map<String, Object>) rawItem).put(DOCUMENT_NAME_KEY, documentName);
                }
            }
            return JSON.serialize(payload);
        } catch (Exception ignored) {
            return rawJson;
        }
    }

    /**
     * Merges multiple prompt payloads into one JSON object with a single items array.
     * @param jsonStrings Prompt JSON payloads to merge.
     * @return Serialized JSON with an items array.
     */
    public static String mergeJsonItems(List<String> jsonStrings) {
        if (jsonStrings == null || jsonStrings.isEmpty()) {
            return '{"items":[]}';
        }

        List<Object> allItems = new List<Object>();
        for (String jsonString : jsonStrings) {
            if (String.isBlank(jsonString)) {
                continue;
            }
            addJsonItems(allItems, jsonString);
        }
        return JSON.serialize(new Map<String, Object>{ ITEMS_KEY => allItems });
    }

    private static void addJsonItems(List<Object> allItems, String rawJson) {
        String cleaned = extractJsonObject(rawJson);
        if (String.isBlank(cleaned)) {
            return;
        }
        try {
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(cleaned);
            Object items = parsed.get(ITEMS_KEY);
            if (items instanceof List<Object>) {
                allItems.addAll((List<Object>) items);
            }
        } catch (Exception ignored) {
            allItems.add(new Map<String, Object>{
                DOCUMENT_NAME_KEY => 'Unknown',
                'status' => 'UNREADABLE',
                'severity' => 'warning',
                'detail' => cleaned.left(240)
            });
        }
    }

    private static String extractJsonObject(String rawJson) {
        String cleaned = rawJson == null ? '' : rawJson.trim();
        if (cleaned.startsWith('```')) {
            Integer jsonStart = cleaned.indexOf('{');
            Integer jsonEnd = cleaned.lastIndexOf('}');
            if (jsonStart >= 0 && jsonEnd > jsonStart) {
                return cleaned.substring(jsonStart, jsonEnd + 1);
            }
        }
        return cleaned;
    }

}

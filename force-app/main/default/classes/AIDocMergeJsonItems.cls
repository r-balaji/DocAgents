/**
 * Merges per-file {"items":[...]} JSON strings into two consolidated payloads in a single
 * invocation: one for the Classify prompt outputs and one for the Sanity prompt outputs.
 *
 * Replaces the previous design where the flow called this action twice. The merge logic
 * is identical for both kinds, so they share the helper and just expose two named slots.
 */
public with sharing class AIDocMergeJsonItems {

    public class Request {
        @InvocableVariable(label='Classification JSON Strings' description='Per-file Classify prompt outputs to merge')
        public List<String> classificationJsonStrings;

        @InvocableVariable(label='Sanity JSON Strings' description='Per-file Sanity prompt outputs to merge')
        public List<String> sanityJsonStrings;
    }

    public class Response {
        @InvocableVariable(label='Classification Merged JSON')
        public String classificationMergedJson;

        @InvocableVariable(label='Sanity Merged JSON')
        public String sanityMergedJson;
    }

    @InvocableMethod(
        label='AI Doc - Merge JSON Items'
        description='Merges per-file Classify and Sanity {"items":[...]} JSON strings into one payload each.'
        category='AI Document Review'
    )
    public static List<Response> execute(List<Request> requests) {
        List<Response> results = new List<Response>();
        for (Request req : requests) {
            Response res = new Response();
            res.classificationMergedJson = mergeItems(req.classificationJsonStrings);
            res.sanityMergedJson         = mergeItems(req.sanityJsonStrings);
            results.add(res);
        }
        return results;
    }

    private static String mergeItems(List<String> jsonStrings) {
        if (jsonStrings == null || jsonStrings.isEmpty()) {
            return '{"items":[]}';
        }
        List<Object> allItems = new List<Object>();
        for (String s : jsonStrings) {
            if (String.isBlank(s)) continue;
            String cleaned = s.trim();
            // Strip code fences if the model wrapped the response
            if (cleaned.startsWith('```')) {
                Integer jsonStart = cleaned.indexOf('{');
                Integer jsonEnd = cleaned.lastIndexOf('}');
                if (jsonStart >= 0 && jsonEnd > jsonStart) {
                    cleaned = cleaned.substring(jsonStart, jsonEnd + 1);
                }
            }
            try {
                Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(cleaned);
                Object items = parsed.get('items');
                if (items instanceof List<Object>) {
                    allItems.addAll((List<Object>) items);
                }
            } catch (Exception e) {
                allItems.add(new Map<String, Object>{
                    'documentName' => 'Unknown',
                    'status' => 'UNREADABLE',
                    'severity' => 'warning',
                    'detail' => cleaned.left(240)
                });
            }
        }
        return JSON.serialize(new Map<String, Object>{ 'items' => allItems });
    }
}

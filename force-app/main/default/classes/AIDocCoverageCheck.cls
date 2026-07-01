/**
 * Single invocable Apex action that owns all deterministic data for the AI Document Review feature:
 *
 *  1. Coverage stats — counts every borrower-facing document slot, files attached, missing categories.
 *  2. Party roster   — resolves all parties on the Application from clcommon__Party__c.
 *  3. Unreviewed-file rows — one pipe-encoded row per attached file that is missing stored
 *     AI feedback, including the party that owns the file's category tree.
 *
 * Encoding for encodedRows: "<docId>|<categoryName>|<partyName>|<partyType>|<categoryId>"
 *
 * Why all in one class: the same SOQL on clcommon__Document_Category__c and clcommon__Party__c
 * was being run twice per flow execution. Consolidating cuts two queries per run and removes
 * duplicated processing. No AI involvement — fully deterministic SOQL.
 */
public with sharing class AIDocCoverageCheck {
    private static final String CLASSIFICATION_JSON_KEY = 'classificationJson';
    private static final String SANITY_JSON_KEY = 'sanityJson';

    @InvocableMethod(
        label='AI Doc - Coverage Check'
        description='Returns coverage stats, borrower name, stored review JSON, and party-aware rows for files still needing review.'
        category='AI Document Review'
    )
    public static List<Response> execute(List<Request> requests) {
        List<Response> responses = new List<Response>();

        Set<Id> allApplicationIds = new Set<Id>();
        for (Request req : requests) {
            if (req != null && req.applicationId != null) {
                allApplicationIds.add(req.applicationId);
            }
        }

        if (allApplicationIds.isEmpty()) {
            for (Request req : requests) {
                Response r = new Response();
                r.isSuccess = false;
                r.errorMessage = 'Application Id is required.';
                r.errorType = 'MISSING_INPUT';
                responses.add(r);
            }
            return responses;
        }

        // All active categories on the requested applications, keyed by Id for tree-walking.
        Map<Id, clcommon__Document_Category__c> categoriesById = new Map<Id, clcommon__Document_Category__c>([SELECT Id, Name, clcommon__Category_Name__c, genesis__Application__c, clcommon__Parent_Document_Category__c, clcommon__Account__c,
                                                                                                                   AI_Reviewed__c, AI_Review_Feedback_JSON__c
                                                                                                            FROM clcommon__Document_Category__c
                                                                                                            WHERE genesis__Application__c IN :allApplicationIds
                                                                                                            AND clcommon__Active__c = true
                                                                                                            WITH USER_MODE
                                                                                                            ORDER BY clcommon__Category_Name__c
                                                                                                            LIMIT 5000]);

        // Index categories by application, and identify which categories are group nodes (have children).
        Map<Id, List<clcommon__Document_Category__c>> catsByApp = new Map<Id, List<clcommon__Document_Category__c>>();
        Set<Id> groupCatIds = new Set<Id>();
        for (clcommon__Document_Category__c category : categoriesById.values()) {
            if (!catsByApp.containsKey(category.genesis__Application__c)) {
                catsByApp.put(category.genesis__Application__c, new List<clcommon__Document_Category__c>());
            }
            catsByApp.get(category.genesis__Application__c).add(category);
            if (category.clcommon__Parent_Document_Category__c != null) {
                groupCatIds.add(category.clcommon__Parent_Document_Category__c);
            }
        }

        // Files attached to each category, with full ContentDocumentId list per category for encoded rows.
        Set<Id> allCatIds = categoriesById.keySet();
        Map<Id, Integer> fileCountByCatId = new Map<Id, Integer>();
        Map<Id, List<Id>> docIdsByCatId = new Map<Id, List<Id>>();
        if (!allCatIds.isEmpty()) {
            List<ContentDocumentLink> files = [
                SELECT LinkedEntityId, ContentDocumentId
                FROM ContentDocumentLink
                WHERE LinkedEntityId IN :allCatIds
                WITH USER_MODE
            ];
            for (ContentDocumentLink l : files) {
                Integer n = fileCountByCatId.containsKey(l.LinkedEntityId) ? fileCountByCatId.get(l.LinkedEntityId) : 0;
                fileCountByCatId.put(l.LinkedEntityId, n + 1);
                if (!docIdsByCatId.containsKey(l.LinkedEntityId)) {
                    docIdsByCatId.put(l.LinkedEntityId, new List<Id>());
                }
                docIdsByCatId.get(l.LinkedEntityId).add(l.ContentDocumentId);
            }
        }

        // Parties on the application — both keyed two ways:
        //  - by application Id → party type → list of names (for the coverage JSON / borrowerName)
        //  - by Account Id → PartyContext            (for per-file root-category party lookup)
        Map<Id, Map<String, List<String>>> partiesByApp = new Map<Id, Map<String, List<String>>>();
        Map<Id, PartyContext> partyByAccountId = new Map<Id, PartyContext>();
        List<clcommon__Party__c> parties = [SELECT Id, genesis__Application__c, clcommon__Account__c, clcommon__Party_Types__c, clcommon__isPrimary__c,
                                                   clcommon__Account__r.Name,
                                                   clcommon__Contact__r.FirstName, clcommon__Contact__r.LastName
                                            FROM clcommon__Party__c
                                            WHERE genesis__Application__c IN :allApplicationIds
                                            WITH USER_MODE
                                            ORDER BY clcommon__isPrimary__c DESC NULLS LAST, Name];
        for (clcommon__Party__c p : parties) {
            String partyType = String.isBlank(p.clcommon__Party_Types__c) ? 'UNSPECIFIED' : p.clcommon__Party_Types__c;
            String partyName = resolvePartyName(p);
            if (String.isBlank(partyName)) {
                continue;
            }
            if (!partiesByApp.containsKey(p.genesis__Application__c)) {
                partiesByApp.put(p.genesis__Application__c, new Map<String, List<String>>());
            }
            Map<String, List<String>> typeMap = partiesByApp.get(p.genesis__Application__c);
            if (!typeMap.containsKey(partyType)) {
                typeMap.put(partyType, new List<String>());
            }
            typeMap.get(partyType).add(partyName);
            if (p.clcommon__Account__c != null) {
                partyByAccountId.put(p.clcommon__Account__c, new PartyContext(partyName, partyType));
            }
        }

        for (Request req : requests) {
            responses.add(buildResponse(req, catsByApp, fileCountByCatId, docIdsByCatId, groupCatIds, partiesByApp, partyByAccountId, categoriesById));
        }
        return responses;
    }

    private static String resolvePartyName(clcommon__Party__c p) {
        if (p.clcommon__Account__r != null && String.isNotBlank(p.clcommon__Account__r.Name)) {
            return p.clcommon__Account__r.Name;
        }
        if (p.clcommon__Contact__r != null) {
            String first = p.clcommon__Contact__r.FirstName;
            String last = p.clcommon__Contact__r.LastName;
            String combined = String.isBlank(first) ? '' : first;
            if (String.isNotBlank(last)) {
                combined = String.isBlank(combined) ? last : combined + ' ' + last;
            }
            return combined;
        }
        return '';
    }

    /**
     * Walks the category tree from the given leaf up to the root and returns the party
     * context for the root. The root category's clcommon__Account__c identifies which
     * party (e.g. Bill Vance / GUARANTOR vs Vance Electric / BORROWER) the file belongs to.
     */
    private static PartyContext resolvePartyForCategory(
        clcommon__Document_Category__c leaf,
        Map<Id, clcommon__Document_Category__c> categoriesById,
        Map<Id, PartyContext> partyByAccountId
    ) {
        clcommon__Document_Category__c cursor = leaf;
        Integer guard = 0;
        while (cursor != null && cursor.clcommon__Parent_Document_Category__c != null && guard < 20) {
            cursor = categoriesById.get(cursor.clcommon__Parent_Document_Category__c);
            guard++;
        }
        if (cursor == null || cursor.clcommon__Account__c == null) {
            return new PartyContext('', '');
        }
        PartyContext ctx = partyByAccountId.get(cursor.clcommon__Account__c);
        return ctx == null ? new PartyContext('', '') : ctx;
    }

    private static String nullToEmpty(String s) {
        return s == null ? '' : s;
    }

    private static Response buildResponse(
        Request req,
        Map<Id, List<clcommon__Document_Category__c>> catsByApp,
        Map<Id, Integer> fileCountByCatId,
        Map<Id, List<Id>> docIdsByCatId,
        Set<Id> groupCatIds,
        Map<Id, Map<String, List<String>>> partiesByApp,
        Map<Id, PartyContext> partyByAccountId,
        Map<Id, clcommon__Document_Category__c> categoriesById
    ) {
        Response res = new Response();

        if (req == null || req.applicationId == null) {
            res.isSuccess = false;
            res.errorMessage = 'Application Id is required.';
            res.errorType = 'MISSING_INPUT';
            return res;
        }

        List<clcommon__Document_Category__c> cats = catsByApp.containsKey(req.applicationId) ? catsByApp.get(req.applicationId) : new List<clcommon__Document_Category__c>();
        Integer totalCount = 0;
        Integer filledCount = 0;
        List<String> missingNames = new List<String>();
        List<String> filledNames = new List<String>();
        List<Map<String, Object>> rows = new List<Map<String, Object>>();

        for (clcommon__Document_Category__c c : cats) {
            Boolean isSlot = !groupCatIds.contains(c.Id);
            if (!isSlot) {
                continue;
            }
            Integer fc = fileCountByCatId.containsKey(c.Id) ? fileCountByCatId.get(c.Id) : 0;
            totalCount++;
            if (fc > 0) {
                filledCount++;
                filledNames.add(c.clcommon__Category_Name__c);
            } else {
                missingNames.add(c.clcommon__Category_Name__c);
            }
            rows.add(new Map<String, Object>{
                'id' => c.Id,
                'name' => c.clcommon__Category_Name__c,
                'fileCount' => fc,
                'onFile' => fc > 0,
                'aiReviewed' => c.AI_Reviewed__c
            });

            // Build encodedRows only for attached files that do not already have stored AI feedback.
            if (fc > 0 && docIdsByCatId.containsKey(c.Id)) {
                PartyContext party = resolvePartyForCategory(c, categoriesById, partyByAccountId);
                Map<String, StoredReview> storedReviews = parseStoredReviews(c.AI_Review_Feedback_JSON__c);
                for (Id docId : docIdsByCatId.get(c.Id)) {
                    StoredReview storedReview = storedReviews.get(String.valueOf(docId));
                    if (storedReview != null && storedReview.hasCompleteReview()) {
                        res.reviewedClassificationJsonStrings.add(storedReview.classificationJson);
                        res.reviewedSanityJsonStrings.add(storedReview.sanityJson);
                    } else {
                        res.encodedRows.add(String.valueOf(docId)
                            + '|' + nullToEmpty(c.clcommon__Category_Name__c)
                            + '|' + nullToEmpty(party.partyName)
                            + '|' + nullToEmpty(party.partyType)
                            + '|' + String.valueOf(c.Id));
                    }
                }
            }
        }

        Integer missingCount = totalCount - filledCount;

        Map<String, List<String>> partyTypeMap = partiesByApp.containsKey(req.applicationId) ? partiesByApp.get(req.applicationId) : new Map<String, List<String>>();
        List<String> borrowerNames = partyTypeMap.containsKey('BORROWER') ? partyTypeMap.get('BORROWER') : new List<String>();
        // Single-string convenience field used by the email-writer and other String-based consumers.
        String borrowerNameJoined = String.join(borrowerNames, ', ');

        Map<String, Object> coverage = new Map<String, Object>{
            'applicationId' => req.applicationId,
            'asOfDate' => String.valueOf(Date.today()),
            'totals' => new Map<String, Object>{
                'total' => totalCount,
                'filled' => filledCount,
                'missing' => missingCount
            },
            'filledCategoryNames' => filledNames,
            'missingCategoryNames' => missingNames,
            'rows' => rows,
            'parties' => partyTypeMap
        };

        res.isSuccess = true;
        res.coverageJson = JSON.serialize(coverage);
        res.totalCount = totalCount;
        res.filledCount = filledCount;
        res.missingCount = missingCount;
        res.borrowerName = borrowerNameJoined;
        res.reviewedClassificationJson = mergeJsonItems(res.reviewedClassificationJsonStrings);
        res.reviewedSanityJson = mergeJsonItems(res.reviewedSanityJsonStrings);
        return res;
    }

    private static Map<String, StoredReview> parseStoredReviews(String feedbackJson) {
        Map<String, StoredReview> reviewsByDocId = new Map<String, StoredReview>();
        if (String.isBlank(feedbackJson)) {
            return reviewsByDocId;
        }

        try {
            Object parsed = JSON.deserializeUntyped(feedbackJson);
            if (!(parsed instanceof Map<String, Object>)) {
                return reviewsByDocId;
            }
            Map<String, Object> rawByDocId = (Map<String, Object>) parsed;
            for (String docId : rawByDocId.keySet()) {
                Object rawReview = rawByDocId.get(docId);
                if (rawReview instanceof Map<String, Object>) {
                    Map<String, Object> reviewMap = (Map<String, Object>) rawReview;
                    reviewsByDocId.put(docId, new StoredReview(
                        valueAsString(reviewMap.get(CLASSIFICATION_JSON_KEY)),
                        valueAsString(reviewMap.get(SANITY_JSON_KEY))
                    ));
                }
            }
        } catch (Exception ignored) {
            return new Map<String, StoredReview>();
        }
        return reviewsByDocId;
    }

    private static String mergeJsonItems(List<String> jsonStrings) {
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
        return JSON.serialize(new Map<String, Object>{ 'items' => allItems });
    }

    private static void addJsonItems(List<Object> allItems, String rawJson) {
        String cleaned = extractJsonObject(rawJson);
        if (String.isBlank(cleaned)) {
            return;
        }
        try {
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(cleaned);
            Object items = parsed.get('items');
            if (items instanceof List<Object>) {
                allItems.addAll((List<Object>) items);
            }
        } catch (Exception ignored) {
            allItems.add(new Map<String, Object>{
                'documentName' => 'Unknown',
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

    private static String valueAsString(Object value) {
        return value == null ? '' : String.valueOf(value);
    }

    public class Request {
        @InvocableVariable(label='Application Id'
                           description='The Id of the genesis__Applications__c record to check'
                           required=true)
        public Id applicationId;
    }

    public class Response {
        @InvocableVariable(label='Success' description='Whether the action succeeded')
        public Boolean isSuccess;

        @InvocableVariable(label='Coverage JSON' description='Serialized coverage payload consumed by the LWC (includes parties map)')
        public String coverageJson;

        @InvocableVariable(label='Total Count' description='Number of leaf document categories on the application')
        public Integer totalCount;

        @InvocableVariable(label='Filled Count' description='Number of categories with at least one file attached')
        public Integer filledCount;

        @InvocableVariable(label='Missing Count' description='Number of categories with no file attached')
        public Integer missingCount;

        @InvocableVariable(label='Borrower Name' description='Comma-joined BORROWER party names from clcommon__Party__c. Empty if none.')
        public String borrowerName;

        @InvocableVariable(label='Encoded Rows' description='One pipe-encoded "<docId>|<categoryName>|<partyName>|<partyType>|<categoryId>" string per attached file that still needs AI review.')
        public List<String> encodedRows;

        @InvocableVariable(label='Reviewed Classification JSON' description='Merged classification JSON from files already stored on document categories.')
        public String reviewedClassificationJson;

        @InvocableVariable(label='Reviewed Sanity JSON' description='Merged sanity-check JSON from files already stored on document categories.')
        public String reviewedSanityJson;

        @InvocableVariable(label='Error Message' description='Error details if the action failed')
        public String errorMessage;

        @InvocableVariable(label='Error Type' description='Exception type if the action failed')
        public String errorType;

        private List<String> reviewedClassificationJsonStrings;
        private List<String> reviewedSanityJsonStrings;

        public Response() {
            this.encodedRows = new List<String>();
            this.reviewedClassificationJsonStrings = new List<String>();
            this.reviewedSanityJsonStrings = new List<String>();
        }
    }

    private class PartyContext {
        public String partyName;
        public String partyType;
        public PartyContext(String partyName, String partyType) {
            this.partyName = partyName;
            this.partyType = partyType;
        }
    }

    private class StoredReview {
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

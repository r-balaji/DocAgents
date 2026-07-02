/**
 * Single invocable Apex action that owns all deterministic data for the AI Document Review feature:
 *
 *  1. Coverage stats — counts every borrower-facing document slot, files attached, missing categories.
 *  2. Party roster   — resolves all parties on the Application from clcommon__Party__c.
 *  3. Unreviewed-file rows — one JSON row per attached file that is missing stored
 *     AI feedback, including the party that owns the file's category tree.
 *
 * Encoding for encodedRows: JSON with fileContentDocumentId, categoryName, partyName,
 * partyType, and documentCategoryId.
 *
 * Why all in one class: the same SOQL on clcommon__Document_Category__c and clcommon__Party__c
 * was being run twice per flow execution. Consolidating cuts two queries per run and removes
 * duplicated processing. No AI involvement — fully deterministic SOQL.
 */
public with sharing class AIDocCoverageCheck {
    @InvocableMethod(
        label='AI Doc - Coverage Check'
        description='Returns coverage stats, borrower name, stored review JSON, and party-aware rows for files still needing review.'
        category='AI Document Review'
    )
    public static List<Response> execute(List<Request> requests) {
        Set<Id> allApplicationIds = collectApplicationIds(requests);
        if (allApplicationIds.isEmpty()) {
            return buildMissingInputResponses(requests);
        }

        CoverageContext context = buildContext(allApplicationIds);
        List<Response> responses = new List<Response>();
        for (Request req : requests) {
            responses.add(buildResponse(req, context));
        }
        return responses;
    }

    private static Set<Id> collectApplicationIds(List<Request> requests) {
        Set<Id> applicationIds = new Set<Id>();
        if (requests == null) {
            return applicationIds;
        }
        for (Request req : requests) {
            if (req != null && req.applicationId != null) {
                applicationIds.add(req.applicationId);
            }
        }
        return applicationIds;
    }

    private static List<Response> buildMissingInputResponses(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null) {
            return responses;
        }
        for (Request req : requests) {
            responses.add(errorResponse('Application Id is required.', 'MISSING_INPUT'));
        }
        return responses;
    }

    private static Response errorResponse(String message, String errorType) {
        Response r = new Response();
        r.isSuccess = false;
        r.errorMessage = message;
        r.errorType = errorType;
        return r;
    }

    private static CoverageContext buildContext(Set<Id> applicationIds) {
        CoverageContext context = new CoverageContext();
        context.categoriesById = loadCategories(applicationIds);
        indexCategories(context);
        context.docIdsByCatId =
            AIDocReviewFileSelector.selectCurrentContentDocumentIdsByCategoryUserMode(context.categoriesById.keySet());
        AIDocReviewPartyResolver.PartyIndex partyIndex = AIDocReviewPartyResolver.load(applicationIds);
        context.partiesByApp = partyIndex.partiesByApp;
        context.partyByAccountId = partyIndex.partyByAccountId;
        return context;
    }

    private static Map<Id, clcommon__Document_Category__c> loadCategories(Set<Id> applicationIds) {
        return new Map<Id, clcommon__Document_Category__c>([
            SELECT Id, Name, clcommon__Category_Name__c, genesis__Application__c,
                   clcommon__Parent_Document_Category__c, clcommon__Account__c,
                   AI_Reviewed__c, AI_Review_Feedback_JSON__c
            FROM clcommon__Document_Category__c
            WHERE genesis__Application__c IN :applicationIds
            AND clcommon__Active__c = true
            WITH USER_MODE
            ORDER BY clcommon__Category_Name__c
            LIMIT 5000
        ]);
    }

    private static void indexCategories(CoverageContext context) {
        for (clcommon__Document_Category__c category : context.categoriesById.values()) {
            if (!context.catsByApp.containsKey(category.genesis__Application__c)) {
                context.catsByApp.put(category.genesis__Application__c, new List<clcommon__Document_Category__c>());
            }
            context.catsByApp.get(category.genesis__Application__c).add(category);
            if (category.clcommon__Parent_Document_Category__c != null) {
                context.groupCatIds.add(category.clcommon__Parent_Document_Category__c);
            }
        }
    }

    private static String nullToEmpty(String s) {
        return s == null ? '' : s;
    }

    private static Response buildResponse(
        Request req,
        CoverageContext context
    ) {
        Response res = new Response();

        if (req == null || req.applicationId == null) {
            return errorResponse('Application Id is required.', 'MISSING_INPUT');
        }

        CoverageAccumulator coverage = new CoverageAccumulator();
        List<clcommon__Document_Category__c> cats = context.catsByApp.containsKey(req.applicationId)
            ? context.catsByApp.get(req.applicationId)
            : new List<clcommon__Document_Category__c>();

        ResponseBuildState state = new ResponseBuildState(res, coverage, context);
        for (clcommon__Document_Category__c c : cats) {
            addCategoryToResponse(c, state);
        }

        Integer missingCount = coverage.totalCount - coverage.filledCount;
        Map<String, List<String>> partyTypeMap = context.partiesByApp.containsKey(req.applicationId)
            ? context.partiesByApp.get(req.applicationId)
            : new Map<String, List<String>>();
        List<String> borrowerNames = partyTypeMap.containsKey('BORROWER')
            ? partyTypeMap.get('BORROWER')
            : new List<String>();
        // Single-string convenience field used by the email-writer and other String-based consumers.
        String borrowerNameJoined = String.join(borrowerNames, ', ');

        Map<String, Object> coverageJson = new Map<String, Object>{
            'applicationId' => req.applicationId,
            'asOfDate' => String.valueOf(Date.today()),
            'totals' => new Map<String, Object>{
                'total' => coverage.totalCount,
                'filled' => coverage.filledCount,
                'missing' => missingCount
            },
            'filledCategoryNames' => coverage.filledNames,
            'missingCategoryNames' => coverage.missingNames,
            'rows' => coverage.rows,
            'parties' => partyTypeMap
        };

        res.isSuccess = true;
        res.coverageJson = JSON.serialize(coverageJson);
        res.totalCount = coverage.totalCount;
        res.filledCount = coverage.filledCount;
        res.missingCount = missingCount;
        res.borrowerName = borrowerNameJoined;
        res.reviewedClassificationJson = AIDocReviewJsonUtil.mergeJsonItems(res.reviewedClassificationJsonStrings);
        res.reviewedSanityJson = AIDocReviewJsonUtil.mergeJsonItems(res.reviewedSanityJsonStrings);
        return res;
    }

    private static void addCategoryToResponse(
        clcommon__Document_Category__c category,
        ResponseBuildState state
    ) {
        if (state.context.groupCatIds.contains(category.Id)) {
            return;
        }

        Integer fileCount = state.context.docIdsByCatId.containsKey(category.Id)
            ? state.context.docIdsByCatId.get(category.Id).size()
            : 0;
        state.coverage.addSlot(category, fileCount);
        if (fileCount > 0) {
            addReviewRows(category, state);
        }
    }

    private static void addReviewRows(
        clcommon__Document_Category__c category,
        ResponseBuildState state
    ) {
        AIDocReviewPartyResolver.PartyContext party = AIDocReviewPartyResolver.resolvePartyForCategory(
            category,
            state.context.categoriesById,
            state.context.partyByAccountId
        );
        Map<String, AIDocReviewFeedbackUtil.StoredReview> storedReviews =
            AIDocReviewFeedbackUtil.parseStoredReviews(category.AI_Review_Feedback_JSON__c);
        ReviewCategoryState reviewState = new ReviewCategoryState();
        reviewState.category = category;
        reviewState.party = party;
        reviewState.storedReviews = storedReviews;
        reviewState.res = state.res;
        for (Id docId : state.context.docIdsByCatId.get(category.Id)) {
            addReviewRow(reviewState, docId);
        }
    }

    private static void addReviewRow(
        ReviewCategoryState state,
        Id docId
    ) {
        AIDocReviewFeedbackUtil.StoredReview storedReview = state.storedReviews.get(String.valueOf(docId));
        if (storedReview != null && storedReview.hasCompleteReview()) {
            state.res.reviewedClassificationJsonStrings.add(
                AIDocReviewJsonUtil.normalizeDocumentName(
                    storedReview.classificationJson,
                    state.category.clcommon__Category_Name__c
                )
            );
            state.res.reviewedSanityJsonStrings.add(
                AIDocReviewJsonUtil.normalizeDocumentName(
                    storedReview.sanityJson,
                    state.category.clcommon__Category_Name__c
                )
            );
            return;
        }
        state.res.encodedRows.add(JSON.serialize(new Map<String, String>{
            'fileContentDocumentId' => String.valueOf(docId),
            'categoryName' => nullToEmpty(state.category.clcommon__Category_Name__c),
            'partyName' => nullToEmpty(state.party.partyName),
            'partyType' => nullToEmpty(state.party.partyType),
            'documentCategoryId' => String.valueOf(state.category.Id)
        }));
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

        @InvocableVariable(label='Encoded Rows' description='One JSON row per attached file that still needs AI review.')
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

    private class CoverageContext {
        public Map<Id, clcommon__Document_Category__c> categoriesById =
            new Map<Id, clcommon__Document_Category__c>();
        public Map<Id, List<clcommon__Document_Category__c>> catsByApp =
            new Map<Id, List<clcommon__Document_Category__c>>();
        public Set<Id> groupCatIds = new Set<Id>();
        public Map<Id, Set<Id>> docIdsByCatId = new Map<Id, Set<Id>>();
        public Map<Id, Map<String, List<String>>> partiesByApp =
            new Map<Id, Map<String, List<String>>>();
        public Map<Id, AIDocReviewPartyResolver.PartyContext> partyByAccountId =
            new Map<Id, AIDocReviewPartyResolver.PartyContext>();
    }

    private class CoverageAccumulator {
        public Integer totalCount = 0;
        public Integer filledCount = 0;
        public List<String> missingNames = new List<String>();
        public List<String> filledNames = new List<String>();
        public List<Map<String, Object>> rows = new List<Map<String, Object>>();

        public void addSlot(clcommon__Document_Category__c category, Integer fileCount) {
            totalCount++;
            if (fileCount > 0) {
                filledCount++;
                filledNames.add(category.clcommon__Category_Name__c);
            } else {
                missingNames.add(category.clcommon__Category_Name__c);
            }
            rows.add(new Map<String, Object>{
                'id' => category.Id,
                'name' => category.clcommon__Category_Name__c,
                'fileCount' => fileCount,
                'onFile' => fileCount > 0,
                'aiReviewed' => category.AI_Reviewed__c
            });
        }
    }

    private class ResponseBuildState {
        public Response res;
        public CoverageAccumulator coverage;
        public CoverageContext context;

        public ResponseBuildState(Response res, CoverageAccumulator coverage, CoverageContext context) {
            this.res = res;
            this.coverage = coverage;
            this.context = context;
        }
    }

    private class ReviewCategoryState {
        public clcommon__Document_Category__c category;
        public AIDocReviewPartyResolver.PartyContext party;
        public Map<String, AIDocReviewFeedbackUtil.StoredReview> storedReviews;
        public Response res;
    }
}

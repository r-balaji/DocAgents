/**
 * Resolves the smaller AI Document Review prompt route for a document category.
 */
public with sharing class AIDocReviewPromptRouter {
    public static final String ROUTE_BANK_STATEMENT = 'BANK_STATEMENT';
    public static final String ROUTE_TAX_RETURN = 'TAX_RETURN';
    public static final String ROUTE_WAGE_INCOME = 'WAGE_INCOME';
    public static final String ROUTE_IDENTITY = 'IDENTITY';
    public static final String ROUTE_ENTITY_FORMATION = 'ENTITY_FORMATION';
    public static final String ROUTE_FINANCIAL_STATEMENT = 'FINANCIAL_STATEMENT';
    public static final String ROUTE_BUSINESS_DOCUMENT = 'BUSINESS_DOCUMENT';
    public static final String ROUTE_GENERIC = 'GENERIC';

    private static final Set<String> ALLOWED_ROUTES = new Set<String>{
        ROUTE_BANK_STATEMENT,
        ROUTE_TAX_RETURN,
        ROUTE_WAGE_INCOME,
        ROUTE_IDENTITY,
        ROUTE_ENTITY_FORMATION,
        ROUTE_FINANCIAL_STATEMENT,
        ROUTE_BUSINESS_DOCUMENT,
        ROUTE_GENERIC
    };

    /**
     * @param requests Flow requests containing a document category label.
     * @return Prompt route decisions for each request.
     */
    @InvocableMethod(
        label='AI Doc - Route Review Prompt'
        description='Routes a document category to the smallest applicable AI Document Review prompt.'
        category='AI Document Review'
    )
    public static List<Response> execute(List<Request> requests) {
        List<Response> responses = new List<Response>();
        List<Document_Type__mdt> documentTypes = loadActiveDocumentTypes();
        for (Request req : requests) {
            Response res = resolve(req == null ? null : req.categoryName, documentTypes);
            responses.add(res);
        }
        return responses;
    }

    @TestVisible
    private static Response resolve(String categoryName, List<Document_Type__mdt> documentTypes) {
        Response res = new Response();
        res.route = ROUTE_GENERIC;
        res.matchedTypeCode = '';
        res.matchedLabel = '';

        if (String.isBlank(categoryName)) {
            return res;
        }

        Document_Type__mdt matchedType = AIDocReviewPromptRouteMatcher.findMatchingDocumentType(
            categoryName,
            documentTypes
        );
        if (matchedType != null) {
            res.route = normalizeRoute(matchedType.Review_Prompt_Route__c);
            res.matchedTypeCode = String.isBlank(matchedType.Type_Code__c) ? '' : matchedType.Type_Code__c;
            res.matchedLabel = String.isBlank(matchedType.Label) ? '' : matchedType.Label;
            if (res.route != ROUTE_GENERIC || String.isNotBlank(matchedType.Review_Prompt_Route__c)) {
                return res;
            }
        }

        res.route = AIDocReviewPromptRouteMatcher.inferRouteFromKeywords(categoryName);
        return res;
    }

    private static List<Document_Type__mdt> loadActiveDocumentTypes() {
        List<Document_Type__mdt> documentTypes = new List<Document_Type__mdt>();
        for (Document_Type__mdt documentType : Document_Type__mdt.getAll().values()) {
            if (documentType.Is_Active__c) {
                documentTypes.add(documentType);
            }
        }
        return documentTypes;
    }

    private static String normalizeRoute(String route) {
        if (String.isBlank(route)) {
            return ROUTE_GENERIC;
        }
        String normalizedRoute = route.trim().toUpperCase();
        return ALLOWED_ROUTES.contains(normalizedRoute) ? normalizedRoute : ROUTE_GENERIC;
    }

    public class Request {
        @InvocableVariable(label='Category Name' description='Document category label to route.' required=true)
        public String categoryName;
    }

    public class Response {
        @InvocableVariable(label='Route' description='Review prompt route bucket.')
        public String route;

        @InvocableVariable(label='Matched Type Code' description='Matched Document_Type__mdt Type_Code__c, when found.')
        public String matchedTypeCode;

        @InvocableVariable(label='Matched Label' description='Matched Document_Type__mdt label, when found.')
        public String matchedLabel;
    }

}

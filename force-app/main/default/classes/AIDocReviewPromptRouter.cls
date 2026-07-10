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
        if (requests == null) {
            return responses;
        }
        for (Request req : requests) {
            responses.add(resolve(req == null ? null : req.categoryName));
        }
        return responses;
    }

    @TestVisible
    private static Response resolve(String categoryName) {
        Response res = new Response();
        res.route = AIDocReviewPromptRouteMatcher.inferRouteFromKeywords(categoryName);
        res.matchedTypeCode = '';
        res.matchedLabel = '';
        return res;
    }

    public class Request {
        @InvocableVariable(label='Category Name' description='Document category label to route.' required=true)
        public String categoryName;
    }

    public class Response {
        @InvocableVariable(label='Route' description='Review prompt route bucket.')
        public String route;

        @InvocableVariable(label='Matched Type Code' description='Reserved compatibility output; currently empty.')
        public String matchedTypeCode;

        @InvocableVariable(label='Matched Label' description='Reserved compatibility output; currently empty.')
        public String matchedLabel;
    }

}

/**
 * Matches document category labels to AI Document Review prompt families.
 */
public inherited sharing class AIDocReviewPromptRouteMatcher {
    /**
     * Infers a prompt route directly from category keywords when metadata does not route it.
     * @param categoryName Document category label supplied by the review flow.
     * @return Prompt route bucket.
     */
    public static String inferRouteFromKeywords(String categoryName) {
        String normalizedCategory = normalize(categoryName);
        for (RouteKeywordSet keywordSet : routeKeywordSets()) {
            if (containsAny(normalizedCategory, keywordSet.keywords)) {
                return keywordSet.route;
            }
        }
        return AIDocReviewPromptRouter.ROUTE_GENERIC;
    }

    private static List<RouteKeywordSet> routeKeywordSets() {
        return new List<RouteKeywordSet>{
            new RouteKeywordSet(
                AIDocReviewPromptRouter.ROUTE_BANK_STATEMENT,
                new List<String>{ 'bank statement', 'checking statement', 'savings statement' }
            ),
            new RouteKeywordSet(
                AIDocReviewPromptRouter.ROUTE_TAX_RETURN,
                new List<String>{ 'tax return', '1040', '1120', '1120s', '1065' }
            ),
            new RouteKeywordSet(
                AIDocReviewPromptRouter.ROUTE_WAGE_INCOME,
                new List<String>{ 'w 2', 'w2', '1099', 'pay stub', 'paystub', 'payroll' }
            ),
            new RouteKeywordSet(
                AIDocReviewPromptRouter.ROUTE_IDENTITY,
                new List<String>{ 'driver', 'license', 'licence', 'passport', 'state id', 'identification' }
            ),
            new RouteKeywordSet(
                AIDocReviewPromptRouter.ROUTE_ENTITY_FORMATION,
                entityFormationKeywords()
            ),
            new RouteKeywordSet(
                AIDocReviewPromptRouter.ROUTE_FINANCIAL_STATEMENT,
                new List<String>{ 'financial statement', 'profit loss', 'profit and loss', 'balance sheet', 'debt schedule' }
            ),
            new RouteKeywordSet(
                AIDocReviewPromptRouter.ROUTE_BUSINESS_DOCUMENT,
                businessDocumentKeywords()
            )
        };
    }

    private static List<String> entityFormationKeywords() {
        return new List<String>{
            'articles',
            'incorporation',
            'organization',
            'ein',
            'business license',
            'operating agreement',
            'bylaws'
        };
    }

    private static List<String> businessDocumentKeywords() {
        return new List<String>{
            'voided check',
            'ach',
            'insurance',
            'certificate of insurance',
            'title',
            'deed',
            'ucc',
            'appraisal'
        };
    }

    private static Boolean containsAny(String value, List<String> needles) {
        for (String needle : needles) {
            if (value.contains(needle)) {
                return true;
            }
        }
        return false;
    }

    private static String normalize(String value) {
        if (String.isBlank(value)) {
            return '';
        }
        String lower = value.toLowerCase();
        lower = lower.replace('&', ' ');
        lower = lower.replace('/', ' ');
        lower = lower.replace('-', ' ');
        lower = lower.replace('_', ' ');
        lower = lower.replace('(', ' ');
        lower = lower.replace(')', ' ');
        lower = lower.replace(',', ' ');
        lower = lower.replace('.', ' ');
        lower = lower.replace('\'', ' ');
        while (lower.contains('  ')) {
            lower = lower.replace('  ', ' ');
        }
        return lower.trim();
    }

    private class RouteKeywordSet {
        public String route;
        public List<String> keywords;

        public RouteKeywordSet(String route, List<String> keywords) {
            this.route = route;
            this.keywords = keywords;
        }
    }
}

/**
 * Matches document category labels to AI Document Review prompt route buckets.
 */
public inherited sharing class AIDocReviewPromptRouteMatcher {
    /**
     * Finds the best matching active document type metadata row for a category label.
     * @param categoryName Document category label supplied by the review flow.
     * @param documentTypes Active Document_Type__mdt rows.
     * @return Best matching metadata row, or null when none matches.
     */
    public static Document_Type__mdt findMatchingDocumentType(
        String categoryName,
        List<Document_Type__mdt> documentTypes
    ) {
        if (String.isBlank(categoryName) || documentTypes == null || documentTypes.isEmpty()) {
            return null;
        }

        String normalizedCategory = normalize(categoryName);
        Document_Type__mdt bestMatch;
        Integer bestScore = 0;
        for (Document_Type__mdt documentType : documentTypes) {
            Integer score = matchScore(normalizedCategory, documentType);
            if (score > bestScore) {
                bestScore = score;
                bestMatch = documentType;
            }
        }
        return bestMatch;
    }

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

    private static Integer matchScore(String normalizedCategory, Document_Type__mdt documentType) {
        Integer score = 0;
        score = Math.max(score, tokenMatchScore(normalizedCategory, normalize(documentType.Label), 100));
        score = Math.max(score, tokenMatchScore(normalizedCategory, normalize(documentType.Type_Code__c), 90));
        score = Math.max(score, tokenMatchScore(normalizedCategory, normalizeDeveloperName(documentType.DeveloperName), 80));
        return score;
    }

    private static Integer tokenMatchScore(String normalizedCategory, String normalizedCandidate, Integer baseScore) {
        if (String.isBlank(normalizedCandidate)) {
            return 0;
        }
        Integer directScore = directCandidateScore(normalizedCategory, normalizedCandidate, baseScore);
        if (directScore > 0) {
            return directScore;
        }
        return tokenCoverageScore(normalizedCategory, normalizedCandidate, baseScore);
    }

    private static Integer directCandidateScore(
        String normalizedCategory,
        String normalizedCandidate,
        Integer baseScore
    ) {
        if (normalizedCategory == normalizedCandidate) {
            return baseScore + 20;
        }
        if (normalizedCategory.contains(normalizedCandidate) || normalizedCandidate.contains(normalizedCategory)) {
            return baseScore;
        }
        return 0;
    }

    private static Integer tokenCoverageScore(
        String normalizedCategory,
        String normalizedCandidate,
        Integer baseScore
    ) {
        List<String> candidateTokens = normalizedCandidate.split(' ');
        Integer matchedTokens = 0;
        Integer meaningfulTokens = 0;
        for (String token : candidateTokens) {
            if (isMeaningfulToken(token)) {
                meaningfulTokens++;
                if (normalizedCategory.contains(token)) {
                    matchedTokens++;
                }
            }
        }
        if (meaningfulTokens > 0 && matchedTokens == meaningfulTokens) {
            return baseScore - 10;
        }
        return 0;
    }

    private static Boolean isMeaningfulToken(String token) {
        return String.isNotBlank(token) && token.length() >= 3;
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

    private static String normalizeDeveloperName(String developerName) {
        return String.isBlank(developerName) ? '' : normalize(developerName.replace('_', ' '));
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

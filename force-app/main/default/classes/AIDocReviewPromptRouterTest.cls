@IsTest
private class AIDocReviewPromptRouterTest {
    @IsTest
    static void shouldRouteToBankStatement_WhenCategoryMentionsBankStatement() {
        AIDocReviewPromptRouter.Request req = new AIDocReviewPromptRouter.Request();
        req.categoryName = 'Business Bank Statement';

        Test.startTest();
        List<AIDocReviewPromptRouter.Response> out =
            AIDocReviewPromptRouter.execute(new List<AIDocReviewPromptRouter.Request>{ req });
        Test.stopTest();

        Assert.areEqual(
            AIDocReviewPromptRouter.ROUTE_BANK_STATEMENT,
            out[0].route,
            'Bank statement category should use the bank statement prompt.'
        );
    }

    @IsTest
    static void shouldRouteToIdentity_WhenCategoryMentionsDriversLicense() {
        AIDocReviewPromptRouter.Request req = new AIDocReviewPromptRouter.Request();
        req.categoryName = 'Driver\'s License';

        Test.startTest();
        List<AIDocReviewPromptRouter.Response> out =
            AIDocReviewPromptRouter.execute(new List<AIDocReviewPromptRouter.Request>{ req });
        Test.stopTest();

        Assert.areEqual(
            AIDocReviewPromptRouter.ROUTE_IDENTITY,
            out[0].route,
            'Driver license category should use the identity prompt.'
        );
    }

    @IsTest
    static void shouldRouteToWageIncome_WhenCategoryMentionsW2() {
        AIDocReviewPromptRouter.Request req = new AIDocReviewPromptRouter.Request();
        req.categoryName = 'W-2';

        Test.startTest();
        List<AIDocReviewPromptRouter.Response> out =
            AIDocReviewPromptRouter.execute(new List<AIDocReviewPromptRouter.Request>{ req });
        Test.stopTest();

        Assert.areEqual(
            AIDocReviewPromptRouter.ROUTE_WAGE_INCOME,
            out[0].route,
            'W-2 category should use the wage income prompt.'
        );
    }

    @IsTest
    static void shouldRouteToGeneric_WhenCategoryIsUnknown() {
        AIDocReviewPromptRouter.Request req = new AIDocReviewPromptRouter.Request();
        req.categoryName = 'Mystery Upload';

        Test.startTest();
        List<AIDocReviewPromptRouter.Response> out =
            AIDocReviewPromptRouter.execute(new List<AIDocReviewPromptRouter.Request>{ req });
        Test.stopTest();

        Assert.areEqual(
            AIDocReviewPromptRouter.ROUTE_GENERIC,
            out[0].route,
            'Unknown category should use the generic fallback prompt.'
        );
    }

    @IsTest
    static void shouldReturnGeneric_WhenCategoryNameIsBlank() {
        AIDocReviewPromptRouter.Request req = new AIDocReviewPromptRouter.Request();
        req.categoryName = ' ';

        Test.startTest();
        List<AIDocReviewPromptRouter.Response> out =
            AIDocReviewPromptRouter.execute(new List<AIDocReviewPromptRouter.Request>{ req });
        Test.stopTest();

        Assert.areEqual(
            AIDocReviewPromptRouter.ROUTE_GENERIC,
            out[0].route,
            'Blank category should use the generic fallback prompt.'
        );
    }
}

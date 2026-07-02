@IsTest
private class AIDocWriteEmailTemplateTest {

    @IsTest
    static void shouldSaveEmail_WhenInputsValid() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);

        AIDocWriteEmailTemplate.Request req = new AIDocWriteEmailTemplate.Request();
        req.applicationId = app.Id;
        req.emailText = 'Subject: Hello\n\nDear Jane,\n\nWe need documents.\n\nBest regards,\nYour Loan Officer';

        Test.startTest();
        List<AIDocWriteEmailTemplate.Response> out =
            AIDocWriteEmailTemplate.execute(new List<AIDocWriteEmailTemplate.Request>{ req });
        Test.stopTest();

        Assert.areEqual(true, out[0].success, 'should succeed');
        Assert.isTrue(out[0].emailTemplate.contains('Jane'), 'returned text echoes the input');

        genesis__Applications__c saved =
            [SELECT Email_Template__c FROM genesis__Applications__c WHERE Id = :app.Id];
        Assert.areEqual(req.emailText, saved.Email_Template__c,
            'Email_Template__c saved verbatim when within length limit');
    }

    @IsTest
    static void shouldTruncate_WhenEmailExceedsFieldLimit() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);

        // 40,000 char body — well over the 32,768 field limit.
        String longBody = 'A'.repeat(40000);

        AIDocWriteEmailTemplate.Request req = new AIDocWriteEmailTemplate.Request();
        req.applicationId = app.Id;
        req.emailText = longBody;

        Test.startTest();
        List<AIDocWriteEmailTemplate.Response> out =
            AIDocWriteEmailTemplate.execute(new List<AIDocWriteEmailTemplate.Request>{ req });
        Test.stopTest();

        Assert.areEqual(true, out[0].success, 'oversize input is truncated, not failed');
        Assert.areEqual(32768, out[0].emailTemplate.length(),
            'returned text capped at field-length limit');

        genesis__Applications__c saved =
            [SELECT Email_Template__c FROM genesis__Applications__c WHERE Id = :app.Id];
        Assert.areEqual(32768, saved.Email_Template__c.length(),
            'saved text capped at field-length limit');
    }

    @IsTest
    static void shouldHandleNullEmailText_WhenPromptReturnedNothing() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);

        AIDocWriteEmailTemplate.Request req = new AIDocWriteEmailTemplate.Request();
        req.applicationId = app.Id;
        req.emailText = null;

        Test.startTest();
        List<AIDocWriteEmailTemplate.Response> out =
            AIDocWriteEmailTemplate.execute(new List<AIDocWriteEmailTemplate.Request>{ req });
        Test.stopTest();

        Assert.areEqual(true, out[0].success, 'null body is saved as empty string');
        Assert.areEqual('', out[0].emailTemplate);
    }

    @IsTest
    static void shouldReturnError_WhenApplicationIdNull() {
        AIDocWriteEmailTemplate.Request req = new AIDocWriteEmailTemplate.Request();
        req.applicationId = null;
        req.emailText = 'irrelevant';

        Test.startTest();
        List<AIDocWriteEmailTemplate.Response> out =
            AIDocWriteEmailTemplate.execute(new List<AIDocWriteEmailTemplate.Request>{ req });
        Test.stopTest();

        Assert.areEqual(false, out[0].success, 'should fail');
        Assert.isTrue(String.isNotBlank(out[0].errorMessage), 'errorMessage populated');
    }

    @IsTest
    static void shouldBulkSaveEmails_WhenMultipleRequestsProvided() {
        genesis__Applications__c firstApp = AIDocTestFactory.createApplication(true);
        genesis__Applications__c secondApp = AIDocTestFactory.createApplication(true);

        AIDocWriteEmailTemplate.Request firstReq = new AIDocWriteEmailTemplate.Request();
        firstReq.applicationId = firstApp.Id;
        firstReq.emailText = 'First body';

        AIDocWriteEmailTemplate.Request secondReq = new AIDocWriteEmailTemplate.Request();
        secondReq.applicationId = secondApp.Id;
        secondReq.emailText = 'Second body';

        Test.startTest();
        List<AIDocWriteEmailTemplate.Response> out =
            AIDocWriteEmailTemplate.execute(new List<AIDocWriteEmailTemplate.Request>{ firstReq, secondReq });
        Test.stopTest();

        Assert.areEqual(2, out.size(), 'one response per request');
        Assert.areEqual(true, out[0].success, 'first update should succeed');
        Assert.areEqual(true, out[1].success, 'second update should succeed');

        Map<Id, genesis__Applications__c> savedById = new Map<Id, genesis__Applications__c>([
            SELECT Id, Email_Template__c
            FROM genesis__Applications__c
            WHERE Id IN :new Set<Id>{ firstApp.Id, secondApp.Id }
        ]);
        Assert.areEqual('First body', savedById.get(firstApp.Id).Email_Template__c,
            'first application should be updated');
        Assert.areEqual('Second body', savedById.get(secondApp.Id).Email_Template__c,
            'second application should be updated');
    }
}

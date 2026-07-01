/**
 * Test class for AIDocCoverageCheck.
 * Validates totals, missing list, error paths, and bulkified execution.
 */
@isTest
private class AIDocCoverageCheckTest {
    private static final String CLASSIFICATION_JSON =
        '{"items":[{"documentName":"Passport","category":"Passport","status":"OK"}]}';
    private static final String SANITY_JSON =
        '{"items":[{"documentName":"Passport","severity":"success","status":"ACCEPTABLE","summary":"Passport is current."}]}';

    // ─── Positive Tests ───────────────────────────────────────────────────

    @isTest
    static void shouldReturnZeroCounts_WhenNoCategoriesExist() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);

        AIDocCoverageCheck.Request req = new AIDocCoverageCheck.Request();
        req.applicationId = app.Id;

        Test.startTest();
        List<AIDocCoverageCheck.Response> out = AIDocCoverageCheck.execute(
            new List<AIDocCoverageCheck.Request>{ req });
        Test.stopTest();

        Assert.areEqual(1, out.size(), 'One response for one request');
        AIDocCoverageCheck.Response r = out[0];
        Assert.areEqual(true, r.isSuccess, 'Empty app should still succeed');
        Assert.areEqual(0, r.totalCount, 'No categories yet');
        Assert.areEqual(0, r.filledCount, 'No filled');
        Assert.areEqual(0, r.missingCount, 'No missing');
        Assert.isTrue(String.isNotBlank(r.coverageJson), 'JSON should be populated');
    }

    @isTest
    static void shouldCountFilledAndMissing_WhenFilesAttachedToSome() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        List<clcommon__Document_Category__c> leaves =
            AIDocTestFactory.createCategories(app.Id, 5, true);
        AIDocTestFactory.attachFile(leaves[0].Id, 'passport');
        AIDocTestFactory.attachFile(leaves[1].Id, 'bank_statement');

        AIDocCoverageCheck.Request req = new AIDocCoverageCheck.Request();
        req.applicationId = app.Id;

        Test.startTest();
        List<AIDocCoverageCheck.Response> out = AIDocCoverageCheck.execute(
            new List<AIDocCoverageCheck.Request>{ req });
        Test.stopTest();

        AIDocCoverageCheck.Response r = out[0];
        Assert.areEqual(true, r.isSuccess, 'should succeed');
        Assert.areEqual(5, r.totalCount, '5 leaf categories created');
        Assert.areEqual(2, r.filledCount, '2 files attached');
        Assert.areEqual(3, r.missingCount, '3 still missing');

        // JSON should mention both totals and the missing names.
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(r.coverageJson);
        Map<String, Object> totals = (Map<String, Object>) parsed.get('totals');
        Assert.areEqual(5, ((Integer) totals.get('total')), 'JSON total matches');
        Assert.areEqual(2, ((Integer) totals.get('filled')), 'JSON filled matches');
        Assert.areEqual(3, ((Integer) totals.get('missing')), 'JSON missing matches');

        List<Object> missing = (List<Object>) parsed.get('missingCategoryNames');
        Assert.areEqual(3, missing.size(), 'Missing list has 3 entries');
    }

    @isTest
    static void shouldIgnoreParentCategories_WhenCountingLeaves() {
        // The factory inserts 1 parent group + N leaves.
        // execute() must count only leaves (parent has null parent_id).
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        List<clcommon__Document_Category__c> leaves =
            AIDocTestFactory.createCategories(app.Id, 3, true);
        Assert.areEqual(3, leaves.size(), 'factory should make 3 leaves');

        AIDocCoverageCheck.Request req = new AIDocCoverageCheck.Request();
        req.applicationId = app.Id;

        Test.startTest();
        List<AIDocCoverageCheck.Response> out = AIDocCoverageCheck.execute(
            new List<AIDocCoverageCheck.Request>{ req });
        Test.stopTest();

        Assert.areEqual(3, out[0].totalCount, 'Parent group is not counted; only leaves');
    }

    // ─── Bulkification Test ───────────────────────────────────────────────

    @isTest
    static void shouldBulkifyAcrossMultipleApplications_WhenManyRequests() {
        // Two apps with different shapes.
        genesis__Applications__c appA = AIDocTestFactory.createApplication(true);
        genesis__Applications__c appB = AIDocTestFactory.createApplication(true);
        AIDocTestFactory.createCategories(appA.Id, 2, true);
        List<clcommon__Document_Category__c> leavesB =
            AIDocTestFactory.createCategories(appB.Id, 4, true);
        AIDocTestFactory.attachFile(leavesB[0].Id, 'fileB1');

        AIDocCoverageCheck.Request reqA = new AIDocCoverageCheck.Request();
        reqA.applicationId = appA.Id;
        AIDocCoverageCheck.Request reqB = new AIDocCoverageCheck.Request();
        reqB.applicationId = appB.Id;

        Test.startTest();
        List<AIDocCoverageCheck.Response> out = AIDocCoverageCheck.execute(
            new List<AIDocCoverageCheck.Request>{ reqA, reqB });
        Test.stopTest();

        Assert.areEqual(2, out.size(), 'Two responses for two requests');
        Assert.areEqual(2, out[0].totalCount, 'App A had 2 leaves');
        Assert.areEqual(0, out[0].filledCount, 'App A had no files');
        Assert.areEqual(4, out[1].totalCount, 'App B had 4 leaves');
        Assert.areEqual(1, out[1].filledCount, 'App B had 1 file');
        Assert.areEqual(3, out[1].missingCount, 'App B is missing 3');
    }

    // ─── Borrower / Party Tests ───────────────────────────────────────────

    @isTest
    static void shouldReturnEmptyBorrowerName_WhenNoPartyExists() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);

        AIDocCoverageCheck.Request req = new AIDocCoverageCheck.Request();
        req.applicationId = app.Id;

        Test.startTest();
        List<AIDocCoverageCheck.Response> out = AIDocCoverageCheck.execute(
            new List<AIDocCoverageCheck.Request>{ req });
        Test.stopTest();

        Assert.areEqual('', out[0].borrowerName, 'No party means empty borrower name');
    }

    @isTest
    static void shouldReturnBorrowerName_WhenPartyOfTypeBorrowerExists() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);

        Account acct = new Account(Name = 'Vance Electric');
        insert acct;

        clcommon__Party__c party = new clcommon__Party__c(
            genesis__Application__c = app.Id,
            clcommon__Account__c = acct.Id,
            clcommon__Party_Types__c = 'BORROWER'
        );
        insert party;

        AIDocCoverageCheck.Request req = new AIDocCoverageCheck.Request();
        req.applicationId = app.Id;

        Test.startTest();
        List<AIDocCoverageCheck.Response> out = AIDocCoverageCheck.execute(
            new List<AIDocCoverageCheck.Request>{ req });
        Test.stopTest();

        Assert.areEqual('Vance Electric', out[0].borrowerName,
            'Borrower account name is returned');

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(out[0].coverageJson);
        Map<String, Object> partiesMap = (Map<String, Object>) parsed.get('parties');
        Assert.isNotNull(partiesMap.get('BORROWER'), 'BORROWER key present in parties map');
        List<Object> borrowers = (List<Object>) partiesMap.get('BORROWER');
        Assert.areEqual(1, borrowers.size(), 'one borrower');
        Assert.areEqual('Vance Electric', (String) borrowers[0], 'borrower name in parties map');
    }

    @isTest
    static void shouldJoinMultipleBorrowers_WhenSeveralPartiesOfBorrowerType() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);

        Account borrowerOne = new Account(Name = 'Acme Co');
        Account borrowerTwo = new Account(Name = 'Beta LLC');
        insert new List<Account>{ borrowerOne, borrowerTwo };

        insert new List<clcommon__Party__c>{
            new clcommon__Party__c(genesis__Application__c = app.Id,
                                   clcommon__Account__c = borrowerOne.Id,
                                   clcommon__Party_Types__c = 'BORROWER'),
            new clcommon__Party__c(genesis__Application__c = app.Id,
                                   clcommon__Account__c = borrowerTwo.Id,
                                   clcommon__Party_Types__c = 'BORROWER')
        };

        AIDocCoverageCheck.Request req = new AIDocCoverageCheck.Request();
        req.applicationId = app.Id;

        Test.startTest();
        List<AIDocCoverageCheck.Response> out = AIDocCoverageCheck.execute(
            new List<AIDocCoverageCheck.Request>{ req });
        Test.stopTest();

        Assert.isTrue(out[0].borrowerName.contains('Acme Co'), 'first borrower present');
        Assert.isTrue(out[0].borrowerName.contains('Beta LLC'), 'second borrower present');
        Assert.isTrue(out[0].borrowerName.contains(','), 'comma-joined');
    }

    // ─── Encoded Rows Tests ───────────────────────────────────────────────

    @isTest
    static void shouldReturnEmptyEncodedRows_WhenNoFilesAttached() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        AIDocTestFactory.createCategories(app.Id, 3, true);

        AIDocCoverageCheck.Request req = new AIDocCoverageCheck.Request();
        req.applicationId = app.Id;

        Test.startTest();
        List<AIDocCoverageCheck.Response> out = AIDocCoverageCheck.execute(
            new List<AIDocCoverageCheck.Request>{ req });
        Test.stopTest();

        Assert.isNotNull(out[0].encodedRows, 'encodedRows initialized');
        Assert.areEqual(0, out[0].encodedRows.size(), 'no files = no rows');
    }

    @isTest
    static void shouldEmitOneEncodedRowPerAttachedFile_WhenFilesAttached() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        List<clcommon__Document_Category__c> leaves =
            AIDocTestFactory.createCategories(app.Id, 3, true);

        ContentDocumentLink passportLink = AIDocTestFactory.attachFile(leaves[0].Id, 'passport');
        ContentDocumentLink bankStatementLink = AIDocTestFactory.attachFile(leaves[1].Id, 'bank_statement');

        AIDocCoverageCheck.Request req = new AIDocCoverageCheck.Request();
        req.applicationId = app.Id;

        Test.startTest();
        List<AIDocCoverageCheck.Response> out = AIDocCoverageCheck.execute(
            new List<AIDocCoverageCheck.Request>{ req });
        Test.stopTest();

        Assert.areEqual(2, out[0].encodedRows.size(), 'two files attached, two rows expected');

        Set<String> expectedDocIds = new Set<String>{
            String.valueOf(passportLink.ContentDocumentId),
            String.valueOf(bankStatementLink.ContentDocumentId)
        };
        Set<String> actualDocIds = new Set<String>();
        for (String row : out[0].encodedRows) {
            Assert.isTrue(row.contains('|'), 'row should contain pipe delimiter');
            List<String> parts = row.split('\\|', -1);
            Assert.areEqual(5, parts.size(), 'row should have 5 parts');
            actualDocIds.add(parts[0]);
            Assert.isNotNull(parts[4], 'category id should be present');
        }
        Assert.areEqual(expectedDocIds, actualDocIds, 'doc ids pipe-encoded in rows');
    }

    @isTest
    static void shouldSkipEncodedRowAndReturnStoredVerdicts_WhenFileAlreadyReviewed() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);
        List<clcommon__Document_Category__c> leaves =
            AIDocTestFactory.createCategories(app.Id, 1, true);
        ContentDocumentLink link = AIDocTestFactory.attachFile(leaves[0].Id, 'passport');
        update new clcommon__Document_Category__c(
            Id = leaves[0].Id,
            AI_Reviewed__c = true,
            AI_Review_Feedback_JSON__c = JSON.serialize(new Map<String, Object>{
                String.valueOf(link.ContentDocumentId) => new Map<String, Object>{
                    'classificationJson' => CLASSIFICATION_JSON,
                    'sanityJson' => SANITY_JSON
                }
            })
        );

        AIDocCoverageCheck.Request req = new AIDocCoverageCheck.Request();
        req.applicationId = app.Id;

        Test.startTest();
        List<AIDocCoverageCheck.Response> out = AIDocCoverageCheck.execute(
            new List<AIDocCoverageCheck.Request>{ req });
        Test.stopTest();

        Assert.areEqual(0, out[0].encodedRows.size(), 'reviewed file should not be sent to LLM again');
        Map<String, Object> classification =
            (Map<String, Object>) JSON.deserializeUntyped(out[0].reviewedClassificationJson);
        Map<String, Object> sanity =
            (Map<String, Object>) JSON.deserializeUntyped(out[0].reviewedSanityJson);
        Assert.areEqual(1, ((List<Object>) classification.get('items')).size(), 'stored classification should be returned');
        Assert.areEqual(1, ((List<Object>) sanity.get('items')).size(), 'stored sanity verdict should be returned');
    }

    @isTest
    static void shouldExposeAllPartyTypes_NotJustBorrower() {
        genesis__Applications__c app = AIDocTestFactory.createApplication(true);

        Account borrower = new Account(Name = 'Vance Electric');
        Account guarantor = new Account(Name = 'Bill Vance');
        insert new List<Account>{ borrower, guarantor };

        insert new List<clcommon__Party__c>{
            new clcommon__Party__c(genesis__Application__c = app.Id,
                                   clcommon__Account__c = borrower.Id,
                                   clcommon__Party_Types__c = 'BORROWER'),
            new clcommon__Party__c(genesis__Application__c = app.Id,
                                   clcommon__Account__c = guarantor.Id,
                                   clcommon__Party_Types__c = 'GUARANTOR')
        };

        AIDocCoverageCheck.Request req = new AIDocCoverageCheck.Request();
        req.applicationId = app.Id;

        Test.startTest();
        List<AIDocCoverageCheck.Response> out = AIDocCoverageCheck.execute(
            new List<AIDocCoverageCheck.Request>{ req });
        Test.stopTest();

        Assert.areEqual('Vance Electric', out[0].borrowerName, 'only BORROWER goes in borrowerName');

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(out[0].coverageJson);
        Map<String, Object> partiesMap = (Map<String, Object>) parsed.get('parties');
        Assert.isNotNull(partiesMap.get('BORROWER'), 'BORROWER key present');
        Assert.isNotNull(partiesMap.get('GUARANTOR'), 'GUARANTOR key present too');
    }

    // ─── Negative Tests ───────────────────────────────────────────────────

    @isTest
    static void shouldReturnError_WhenApplicationIdIsNull() {
        AIDocCoverageCheck.Request req = new AIDocCoverageCheck.Request();
        req.applicationId = null;

        Test.startTest();
        List<AIDocCoverageCheck.Response> out = AIDocCoverageCheck.execute(
            new List<AIDocCoverageCheck.Request>{ req });
        Test.stopTest();

        AIDocCoverageCheck.Response r = out[0];
        Assert.areEqual(false, r.isSuccess, 'null id should fail');
        Assert.areEqual('MISSING_INPUT', r.errorType, 'errorType set');
        Assert.isTrue(String.isNotBlank(r.errorMessage), 'errorMessage set');
    }

    @isTest
    static void shouldReturnEmpty_WhenRequestListIsEmpty() {
        Test.startTest();
        List<AIDocCoverageCheck.Response> out =
            AIDocCoverageCheck.execute(new List<AIDocCoverageCheck.Request>());
        Test.stopTest();

        Assert.areEqual(0, out.size(), 'Empty input -> empty output');
    }
}

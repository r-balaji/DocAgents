/**
 * Tests for AIDocSplitFileRow invocable.
 */
@IsTest
private class AIDocSplitFileRowTest {

    @IsTest
    static void shouldSplitDocIdAndCategoryName_WhenWellFormed() {
        AIDocSplitFileRow.Request req = new AIDocSplitFileRow.Request();
        req.encodedRow = '069a500000G7R0gAAF|Latest Personal Tax Forms';

        Test.startTest();
        List<AIDocSplitFileRow.Response> out =
            AIDocSplitFileRow.execute(new List<AIDocSplitFileRow.Request>{ req });
        Test.stopTest();

        Assert.areEqual('069a500000G7R0gAAF', out[0].fileContentDocumentId, 'docId parsed');
        Assert.areEqual('Latest Personal Tax Forms', out[0].categoryName, 'categoryName parsed');
    }

    @IsTest
    static void shouldReturnBlanks_WhenInputBlank() {
        AIDocSplitFileRow.Request req = new AIDocSplitFileRow.Request();
        req.encodedRow = null;

        Test.startTest();
        List<AIDocSplitFileRow.Response> out =
            AIDocSplitFileRow.execute(new List<AIDocSplitFileRow.Request>{ req });
        Test.stopTest();

        Assert.areEqual('', out[0].fileContentDocumentId, 'blank docId for null input');
        Assert.areEqual('', out[0].categoryName, 'blank categoryName for null input');
    }

    @IsTest
    static void shouldHandleNoDelimiter_WhenMalformed() {
        AIDocSplitFileRow.Request req = new AIDocSplitFileRow.Request();
        req.encodedRow = 'no-delimiter-here';

        Test.startTest();
        List<AIDocSplitFileRow.Response> out =
            AIDocSplitFileRow.execute(new List<AIDocSplitFileRow.Request>{ req });
        Test.stopTest();

        Assert.areEqual('no-delimiter-here', out[0].fileContentDocumentId, 'whole string goes to docId');
        Assert.areEqual('', out[0].categoryName, 'categoryName empty');
    }
}
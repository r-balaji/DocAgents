/**
 * Tests for AIDocSplitFileRow invocable.
 */
@IsTest
private class AIDocSplitFileRowTest {

    @IsTest
    static void shouldDecodeJsonRow_WhenWellFormed() {
        String contentDocumentId = 'content-document-id';
        String documentCategoryId = 'document-category-id';
        AIDocSplitFileRow.Request req = new AIDocSplitFileRow.Request();
        req.encodedRow = JSON.serialize(new Map<String, String>{
            'fileContentDocumentId' => contentDocumentId,
            'categoryName' => 'Latest Personal Tax Forms | 2025',
            'partyName' => 'Vance Electric',
            'partyType' => 'BORROWER',
            'documentCategoryId' => documentCategoryId
        });

        Test.startTest();
        List<AIDocSplitFileRow.Response> out =
            AIDocSplitFileRow.execute(new List<AIDocSplitFileRow.Request>{ req });
        Test.stopTest();

        Assert.areEqual(contentDocumentId, out[0].fileContentDocumentId, 'docId parsed');
        Assert.areEqual('Latest Personal Tax Forms | 2025', out[0].categoryName, 'categoryName parsed');
        Assert.areEqual('Vance Electric', out[0].partyName, 'partyName parsed');
        Assert.areEqual('BORROWER', out[0].partyType, 'partyType parsed');
        Assert.areEqual(documentCategoryId, out[0].documentCategoryId, 'category id parsed');
    }

    @IsTest
    static void shouldDecodeLegacyPipeRow_WhenExistingInterviewUsesOldFormat() {
        String contentDocumentId = 'content-document-id';
        String documentCategoryId = 'document-category-id';
        AIDocSplitFileRow.Request req = new AIDocSplitFileRow.Request();
        req.encodedRow = contentDocumentId + '|Latest Personal Tax Forms|Vance Electric|BORROWER|' + documentCategoryId;

        Test.startTest();
        List<AIDocSplitFileRow.Response> out =
            AIDocSplitFileRow.execute(new List<AIDocSplitFileRow.Request>{ req });
        Test.stopTest();

        Assert.areEqual(contentDocumentId, out[0].fileContentDocumentId, 'legacy docId parsed');
        Assert.areEqual('Latest Personal Tax Forms', out[0].categoryName, 'legacy categoryName parsed');
        Assert.areEqual('Vance Electric', out[0].partyName, 'legacy partyName parsed');
        Assert.areEqual('BORROWER', out[0].partyType, 'legacy partyType parsed');
        Assert.areEqual(documentCategoryId, out[0].documentCategoryId, 'legacy category id parsed');
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
        Assert.areEqual('', out[0].documentCategoryId, 'blank category id for null input');
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

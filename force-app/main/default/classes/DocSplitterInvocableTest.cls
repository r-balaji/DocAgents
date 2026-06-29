/**
 * Tests for DocSplitterInvocable @InvocableMethod.
 *
 * Exercises input validation. End-to-end behavior requires a real
 * ContentVersion to inspect ContentSize; that path is verified in the
 * sandbox smoke test described in the splitter walkthrough.
 */
@IsTest
private class DocSplitterInvocableTest {

    @IsTest
    static void shouldThrow_WhenSourceContentDocumentIdMissing() {
        DocSplitterInvocable.Request req = new DocSplitterInvocable.Request();
        req.sourceContentDocumentId = null;

        Test.startTest();
        try {
            DocSplitterInvocable.startHeadlessSplit(new List<DocSplitterInvocable.Request>{ req });
            Assert.fail('Expected AuraHandledException for null sourceContentDocumentId');
        } catch (AuraHandledException e) {
            Assert.areNotEqual(null, e);
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldThrow_WhenSourceNotFound() {
        DocSplitterInvocable.Request req = new DocSplitterInvocable.Request();
        req.sourceContentDocumentId = '069000000000999AAA';   // doesn't exist
        req.targetRecordId = '001000000000001AAA';

        Test.startTest();
        try {
            DocSplitterInvocable.startHeadlessSplit(new List<DocSplitterInvocable.Request>{ req });
            Assert.fail('Expected AuraHandledException for missing ContentVersion');
        } catch (AuraHandledException e) {
            Assert.areNotEqual(null, e);
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldExposeSingleCallThresholdConstant() {
        // Defensive check that the threshold constant stays in sync with
        // the JS-side SINGLE_CALL_THRESHOLD_BYTES on the LWCs.
        Test.startTest();
        Integer threshold = DocSplitterInvocable.SINGLE_CALL_THRESHOLD_BYTES;
        Test.stopTest();
        Assert.areEqual(12 * 1024 * 1024, threshold, '12 MB threshold matches LWC default');
    }
}

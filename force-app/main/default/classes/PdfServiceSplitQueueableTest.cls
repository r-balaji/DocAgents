/**
 * Tests for PdfServiceSplitQueueable.
 *
 * Most coverage focuses on the pure-logic helpers (buildSegmentInputs,
 * parsePages, buildTypeBreakdownJson) since the execute() path requires a
 * real ContentVersion + service round-trip. The end-to-end is verified via
 * the sandbox smoke test described in the splitter walkthrough.
 */
@IsTest
private class PdfServiceSplitQueueableTest {

    @IsTest
    static void shouldThrow_WhenConstructedWithNullJobId() {
        Test.startTest();
        try {
            new PdfServiceSplitQueueable(null);
            Assert.fail('Expected SplitJobException');
        } catch (SplitJobException e) {
            Assert.isTrue(e.getMessage().contains('jobId'));
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldBuildSegmentInputs_FromMergedJson() {
        String mergedJson = '['
            + '{"documentType":"BANK_STATEMENT","sourceInstitution":"Chase","namedParty":"John Smith","instanceLabel":"Chase 2026-04","pages":[1,2,3]},'
            + '{"documentType":"BANK_STATEMENT","sourceInstitution":"Wells Fargo","namedParty":"John Smith","instanceLabel":"WF 2026-04","pages":[4,5,6]},'
            + '{"documentType":"DRIVERS_LICENSE","sourceInstitution":null,"namedParty":"John Smith","instanceLabel":null,"pages":[7,10]},'
            + '{"documentType":"OTHER","sourceInstitution":null,"namedParty":null,"instanceLabel":null,"pages":[8,9]}'
            + ']';

        Test.startTest();
        List<PdfServiceClient.SegmentInput> out = PdfServiceSplitQueueable.buildSegmentInputs(mergedJson);
        Test.stopTest();

        Assert.areEqual(4, out.size());

        // Two different bank statements distinguished by source — Chase is _1 (no suffix),
        // Wells Fargo is _1 too (different source key, fresh counter).
        Assert.areEqual('BankStatement_Chase_John_Smith.pdf', out[0].fileName);
        Assert.areEqual('BankStatement_Wells_Fargo_John_Smith.pdf', out[1].fileName);

        // License with non-contiguous pages (front + back) preserved.
        Assert.areEqual(2, out[2].pages.size());
        Assert.areEqual(7, out[2].pages[0]);
        Assert.areEqual(10, out[2].pages[1]);
        Assert.areEqual('DriversLicense_John_Smith.pdf', out[2].fileName);

        // OTHER gets the numeric suffix.
        Assert.areEqual('Other_1.pdf', out[3].fileName);
    }

    @IsTest
    static void shouldNumberDuplicateInstances_SameTypeSameSourceSameParty() {
        // Two Chase statements for John (both with the same source key) → _1 and _2.
        String mergedJson = '['
            + '{"documentType":"BANK_STATEMENT","sourceInstitution":"Chase","namedParty":"John","instanceLabel":"Chase Jan","pages":[1,2]},'
            + '{"documentType":"BANK_STATEMENT","sourceInstitution":"Chase","namedParty":"John","instanceLabel":"Chase Feb","pages":[3,4]}'
            + ']';

        Test.startTest();
        List<PdfServiceClient.SegmentInput> out = PdfServiceSplitQueueable.buildSegmentInputs(mergedJson);
        Test.stopTest();

        Assert.areEqual('BankStatement_Chase_John.pdf', out[0].fileName);
        Assert.areEqual('BankStatement_Chase_John_2.pdf', out[1].fileName);
    }

    @IsTest
    static void shouldReturnEmpty_WhenMergedJsonBlank() {
        Test.startTest();
        List<PdfServiceClient.SegmentInput> a = PdfServiceSplitQueueable.buildSegmentInputs(null);
        List<PdfServiceClient.SegmentInput> b = PdfServiceSplitQueueable.buildSegmentInputs('');
        Test.stopTest();

        Assert.areEqual(0, a.size());
        Assert.areEqual(0, b.size());
    }

    @IsTest
    static void shouldParsePages_ToleratingIntAndDecimal() {
        Test.startTest();
        List<Integer> a = PdfServiceSplitQueueable.parsePages(new List<Object>{1, 2, 3});
        List<Integer> b = PdfServiceSplitQueueable.parsePages(new List<Object>{4.0, 5.0, 6.0});
        List<Integer> c = PdfServiceSplitQueueable.parsePages(null);
        List<Integer> d = PdfServiceSplitQueueable.parsePages('not a list');
        Test.stopTest();

        Assert.areEqual(3, a.size());
        Assert.areEqual(3, b.size());
        Assert.areEqual(5, b[1], 'Decimal converted to Integer');
        Assert.areEqual(0, c.size());
        Assert.areEqual(0, d.size());
    }

    @IsTest
    static void shouldBuildSortedTypeBreakdownJson() {
        Map<String, Integer> counts = new Map<String, Integer>{
            'W2' => 1, 'BANK_STATEMENT' => 2, 'OTHER' => 1
        };

        Test.startTest();
        String json = PdfServiceSplitQueueable.buildTypeBreakdownJson(counts);
        Test.stopTest();

        // Sorted alphabetically: BANK_STATEMENT < OTHER < W2
        Assert.isTrue(json.indexOf('BANK_STATEMENT') < json.indexOf('OTHER'));
        Assert.isTrue(json.indexOf('OTHER') < json.indexOf('W2'));
        Assert.isTrue(json.contains('"count":2'));
    }
}

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
            + '{"documentType":"OTHER","sourceInstitution":null,"namedParty":null,"instanceLabel":null,"pages":[8,9]},'
            + '{"documentType":"OTHER","sourceInstitution":"Unknown","namedParty":"Noise","instanceLabel":null,"pages":[11,9]}'
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

        // OTHER pages are grouped into one catch-all file.
        Assert.areEqual('Other.pdf', out[3].fileName);
        Assert.areEqual(3, out[3].pages.size());
        Assert.areEqual(8, out[3].pages[0]);
        Assert.areEqual(9, out[3].pages[1]);
        Assert.areEqual(11, out[3].pages[2]);
    }

    @IsTest
    static void shouldFinalizeJob_WhenSplitServiceSucceeds() {
        Id sourceContentDocumentId = createContentDocument('source_bundle');
        Id bankContentDocumentId = createContentDocument('BankStatement_Chase_John');
        Id otherContentDocumentId = createContentDocument('Other');
        Id jobId = SplitJobService.startJob(sourceContentDocumentId, fakeLibraryId(), 3, 1);
        update new Split_Job__c(
            Id = jobId,
            Status__c = 'Splitting',
            Merged_Segments_JSON__c = '['
                + '{"documentType":"BANK_STATEMENT","sourceInstitution":"Chase","namedParty":"John","instanceLabel":"Chase","pages":[1,2]},'
                + '{"documentType":"OTHER","sourceInstitution":null,"namedParty":null,"instanceLabel":null,"pages":[3]},'
                + '{"documentType":"OTHER","sourceInstitution":"Unknown","namedParty":"Noise","instanceLabel":null,"pages":[3]}'
                + ']'
        );

        PdfServiceClient.testEndpointOverride = 'https://pdf.example.test';
        Test.setMock(HttpCalloutMock.class, new SplitServiceMock(bankContentDocumentId, otherContentDocumentId));

        Test.startTest();
        System.enqueueJob(new PdfServiceSplitQueueable(jobId));
        Test.stopTest();

        Split_Job__c after = [
            SELECT Status__c, Documents_Created__c, Type_Breakdown_JSON__c, Error_Detail__c
            FROM Split_Job__c
            WHERE Id = :jobId
        ];
        Assert.areEqual('Complete', after.Status__c,
            'split queueable should finalize the job. Error: ' + after.Error_Detail__c);
        Assert.areEqual(2, after.Documents_Created__c, 'mock service returned two output files');
        Assert.isTrue(after.Type_Breakdown_JSON__c.contains('"type":"BANK_STATEMENT"'),
            'type breakdown should include the known document type');
        Assert.isTrue(after.Type_Breakdown_JSON__c.contains('"type":"OTHER"'),
            'type breakdown should include the grouped OTHER output');

        Set<Id> outputIds = new Set<Id>{ bankContentDocumentId, otherContentDocumentId };
        Assert.areEqual(2, [
            SELECT COUNT()
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :jobId
            AND ContentDocumentId IN :outputIds
        ], 'split outputs should be linked back to the split job');

        Assert.areEqual(2, [
            SELECT COUNT()
            FROM ContentVersion
            WHERE ContentDocumentId IN :outputIds
            AND IsLatest = true
            AND AI_Created_Doc__c = true
        ], 'split outputs should be marked as AI-created documents');
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

    private static Id createContentDocument(String title) {
        ContentVersion version = new ContentVersion(
            Title = title,
            PathOnClient = title + '.pdf',
            VersionData = Blob.valueOf('%PDF-1.4\n%%EOF\n'),
            IsMajorVersion = true
        );
        insert version;
        return [
            SELECT ContentDocumentId
            FROM ContentVersion
            WHERE Id = :version.Id
            LIMIT 1
        ].ContentDocumentId;
    }

    private static Id fakeLibraryId() {
        return (Id) (ContentWorkspace.SObjectType
            .getDescribe(SObjectDescribeOptions.DEFERRED)
            .getKeyPrefix() + String.valueOf(UserInfo.getOrganizationId()).right(12));
    }

    private class SplitServiceMock implements HttpCalloutMock {
        private final Id bankContentDocumentId;
        private final Id otherContentDocumentId;

        SplitServiceMock(Id bankContentDocumentId, Id otherContentDocumentId) {
            this.bankContentDocumentId = bankContentDocumentId;
            this.otherContentDocumentId = otherContentDocumentId;
        }

        public HttpResponse respond(HttpRequest req) {
            Assert.isTrue(req.getEndpoint().endsWith(PdfServiceClient.SPLITS_PATH),
                'queueable should call the splits endpoint');
            Assert.isTrue(req.getBody().contains('Other.pdf'),
                'OTHER pages should be sent as one catch-all file');
            Assert.isFalse(req.getBody().contains('Other_'),
                'OTHER output should not use numbered filenames');

            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setStatusCode(200);
            res.setBody('{"outputs":['
                + '{"fileName":"BankStatement_Chase_John.pdf","contentDocumentId":"' + bankContentDocumentId
                + '","contentVersionId":"068000000000001AAA","documentType":"BANK_STATEMENT","pages":[1,2]},'
                + '{"fileName":"Other.pdf","contentDocumentId":"' + otherContentDocumentId
                + '","contentVersionId":"068000000000002AAA","documentType":"OTHER","pages":[3]}'
                + ']}');
            return res;
        }
    }
}

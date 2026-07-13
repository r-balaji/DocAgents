/**
 * Unit tests for SegmentMerger.
 *
 * Pure logic — no SOQL, DML, or async, so no @TestSetup is needed.
 * With the page-list model the merger sanitizes inputs, de-duplicates overlapping
 * page claims (first-claimant-wins), groups matching type/party/source segments,
 * and fills any unclaimed pages with a single OTHER segment.
 */
@IsTest
private class SegmentMergerTest {

    private static final String FALLBACK = 'OTHER';

    // ----- Trivial / empty inputs --------------------------------------------

    @IsTest
    static void shouldReturnEmpty_WhenTotalPagesNull() {
        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(new List<DocSegment>(), null, FALLBACK);
        Test.stopTest();
        Assert.areEqual(0, out.size(), 'Null totalPages should produce empty list');
    }

    @IsTest
    static void shouldReturnEmpty_WhenTotalPagesZero() {
        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(new List<DocSegment>(), 0, FALLBACK);
        Test.stopTest();
        Assert.areEqual(0, out.size(), 'Zero totalPages should produce empty list');
    }

    @IsTest
    static void shouldFillEntireBundleWithFallback_WhenNoSegments() {
        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(new List<DocSegment>(), 10, FALLBACK);
        Test.stopTest();
        Assert.areEqual(1, out.size(), 'Empty input → one fallback segment');
        Assert.areEqual(FALLBACK, out[0].documentType);
        Assert.areEqual(10, out[0].pages.size(), 'Fallback should claim every page');
    }

    @IsTest
    static void shouldFillEntireBundleWithFallback_WhenRawSegmentsNull() {
        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(null, 5, FALLBACK);
        Test.stopTest();
        Assert.areEqual(1, out.size(), 'Null input → one fallback segment');
        Assert.areEqual(FALLBACK, out[0].documentType);
        Assert.areEqual(5, out[0].pages.size());
    }

    // ----- Happy path --------------------------------------------------------

    @IsTest
    static void shouldPassThroughSingleSegment_WhenItCoversWholeBundle() {
        List<DocSegment> raw = new List<DocSegment>{
            buildSegment('PASSPORT', null, null, null, new List<Integer>{1, 2, 3, 4, 5})
        };
        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(raw, 5, FALLBACK);
        Test.stopTest();
        Assert.areEqual(1, out.size(), 'Single full-coverage segment passes through');
        Assert.areEqual('PASSPORT', out[0].documentType);
        Assert.areEqual(5, out[0].pages.size());
    }

    @IsTest
    static void shouldPreserveNonContiguousPages_WhenDocumentSpansScatteredPages() {
        // Driver's license front on page 1, back on page 10 — non-contiguous.
        List<DocSegment> raw = new List<DocSegment>{
            buildSegment('DRIVERS_LICENSE', null, 'John Smith', 'CA DL', new List<Integer>{1, 10}),
            buildSegment('BANK_STATEMENT', 'Chase', 'John Smith', 'Chase 2026-04', new List<Integer>{3, 4, 5}),
            buildSegment('W2', null, 'John Smith', null, new List<Integer>{6, 7, 8})
        };

        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(raw, 10, FALLBACK);
        Test.stopTest();

        DocSegment license = findByType(out, 'DRIVERS_LICENSE');
        Assert.isNotNull(license);
        Assert.areEqual(2, license.pages.size(), 'License has two scattered pages');
        Assert.isTrue(license.pages.contains(1) && license.pages.contains(10),
            'Both license pages preserved');
        Assert.areEqual(1, countByType(out, 'OTHER'), 'Pages 2 and 9 become one OTHER segment');
    }

    @IsTest
    static void shouldKeepTwoInstancesSeparate_WhenSameTypeAppearsMultipleTimes() {
        // Two distinct bank statements from different banks for the same person.
        List<DocSegment> raw = new List<DocSegment>{
            buildSegment('BANK_STATEMENT', 'Chase', 'John Smith', 'Chase 2026-04', new List<Integer>{1, 2, 3}),
            buildSegment('BANK_STATEMENT', 'Wells Fargo', 'John Smith', 'WF 2026-04', new List<Integer>{4, 5, 6})
        };

        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(raw, 6, FALLBACK);
        Test.stopTest();

        Assert.areEqual(2, countByType(out, 'BANK_STATEMENT'),
            'Two distinct statements must remain as two separate segments');
        Assert.areEqual(0, countByType(out, 'OTHER'), 'No unclaimed pages → no fallback');
    }

    @IsTest
    static void shouldMergeMonthlyStatements_WhenTypePartyAndSourceMatch() {
        List<DocSegment> raw = new List<DocSegment>{
            buildSegment('BANK_STATEMENT', 'Chase', 'Jimmy Doe', 'Chase 2026-01', new List<Integer>{1}),
            buildSegment('BANK_STATEMENT', ' chase ', ' jimmy doe ', 'Chase 2026-02', new List<Integer>{2}),
            buildSegment('BANK_STATEMENT', 'CHASE', 'JIMMY DOE', 'Chase 2026-03', new List<Integer>{3})
        };

        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(raw, 3, FALLBACK);
        Test.stopTest();

        Assert.areEqual(1, out.size(), 'Matching monthly statements should produce one output');
        Assert.areEqual(new List<Integer>{1, 2, 3}, out[0].pages, 'All statement pages should be merged');
        Assert.isNull(out[0].instanceLabel, 'A month-specific label should not describe a multi-month output');
    }

    @IsTest
    static void shouldKeepStatementsSeparate_WhenPartiesDiffer() {
        List<DocSegment> raw = new List<DocSegment>{
            buildSegment('BANK_STATEMENT', 'Chase', 'Jimmy Doe', 'Jimmy Chase', new List<Integer>{1}),
            buildSegment('BANK_STATEMENT', 'Chase', 'Ben Doe', 'Ben Chase', new List<Integer>{2})
        };

        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(raw, 2, FALLBACK);
        Test.stopTest();

        Assert.areEqual(2, countByType(out, 'BANK_STATEMENT'),
            'The same bank must still produce separate outputs for different parties');
    }

    @IsTest
    static void shouldMergeTaxReturns_WhenTypeAndPartyMatchWithoutSource() {
        List<DocSegment> raw = new List<DocSegment>{
            buildSegment('PERSONAL_TAX_RETURN_1040', null, 'Jimmy Doe', 'Jimmy 2024', new List<Integer>{1}),
            buildSegment('PERSONAL_TAX_RETURN_1040', null, 'Jimmy Doe', 'Jimmy 2025', new List<Integer>{2})
        };

        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(raw, 2, FALLBACK);
        Test.stopTest();

        Assert.areEqual(1, out.size(), 'Source-free documents should group by type and party');
        Assert.areEqual(new List<Integer>{1, 2}, out[0].pages, 'Both tax-return pages should be retained');
    }

    // ----- De-duplication / overlap ------------------------------------------

    @IsTest
    static void shouldDropDuplicateClaim_WhenTwoSegmentsClaimSamePage() {
        // Both segments claim page 3; first claimant wins.
        List<DocSegment> raw = new List<DocSegment>{
            buildSegment('PAY_STUB', null, 'Alice', null, new List<Integer>{1, 2, 3}),
            buildSegment('W2', null, 'Alice', null, new List<Integer>{3, 4, 5})
        };

        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(raw, 5, FALLBACK);
        Test.stopTest();

        DocSegment payStub = findByType(out, 'PAY_STUB');
        DocSegment w2 = findByType(out, 'W2');
        Assert.areEqual(3, payStub.pages.size(), 'Pay stub keeps all three of its claimed pages');
        Assert.isTrue(payStub.pages.contains(3));
        Assert.areEqual(2, w2.pages.size(), 'W2 loses page 3 to first claimant');
        Assert.isFalse(w2.pages.contains(3));
    }

    @IsTest
    static void shouldDropSegmentEntirely_WhenAllItsPagesAreAlreadyClaimed() {
        List<DocSegment> raw = new List<DocSegment>{
            buildSegment('PASSPORT', null, null, null, new List<Integer>{1, 2, 3}),
            buildSegment('W2', null, null, null, new List<Integer>{1, 2, 3})   // total dupe
        };

        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(raw, 3, FALLBACK);
        Test.stopTest();

        Assert.areEqual(1, out.size(), 'Fully-duplicated segment is dropped');
        Assert.areEqual('PASSPORT', out[0].documentType, 'First claimant remains');
    }

    // ----- Gap filling -------------------------------------------------------

    @IsTest
    static void shouldFillGapBetweenSegments_WithFallback() {
        // Pages claimed: 1-3 and 6-8; pages 4-5 unclaimed.
        List<DocSegment> raw = new List<DocSegment>{
            buildSegment('PASSPORT', null, null, null, new List<Integer>{1, 2, 3}),
            buildSegment('W2', null, null, null, new List<Integer>{6, 7, 8})
        };

        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(raw, 8, FALLBACK);
        Test.stopTest();

        DocSegment other = findByType(out, FALLBACK);
        Assert.isNotNull(other);
        Assert.areEqual(2, other.pages.size(), 'Two unclaimed pages → one OTHER segment');
        Assert.isTrue(other.pages.contains(4));
        Assert.isTrue(other.pages.contains(5));
    }

    @IsTest
    static void shouldFillLeadingGap_WithFallback() {
        List<DocSegment> raw = new List<DocSegment>{
            buildSegment('PASSPORT', null, null, null, new List<Integer>{5, 6, 7})
        };
        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(raw, 7, FALLBACK);
        Test.stopTest();
        DocSegment other = findByType(out, FALLBACK);
        Assert.isNotNull(other);
        Assert.areEqual(4, other.pages.size(), 'Pages 1-4 become OTHER');
    }

    @IsTest
    static void shouldFillTrailingGap_WithFallback() {
        List<DocSegment> raw = new List<DocSegment>{
            buildSegment('PASSPORT', null, null, null, new List<Integer>{1, 2, 3, 4, 5})
        };
        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(raw, 8, FALLBACK);
        Test.stopTest();
        DocSegment other = findByType(out, FALLBACK);
        Assert.isNotNull(other);
        Assert.areEqual(3, other.pages.size(), 'Pages 6-8 become OTHER');
    }

    @IsTest
    static void shouldLumpAllOrphansIntoOneOtherSegment_WhenGapsAreNonContiguous() {
        // Unrecognized pages 2, 5, 9 should all land in ONE OTHER segment, not three.
        List<DocSegment> raw = new List<DocSegment>{
            buildSegment('PASSPORT', null, null, null, new List<Integer>{1}),
            buildSegment('W2', null, null, null, new List<Integer>{3, 4}),
            buildSegment('PAY_STUB', null, null, null, new List<Integer>{6, 7, 8})
        };

        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(raw, 9, FALLBACK);
        Test.stopTest();

        Assert.areEqual(1, countByType(out, FALLBACK),
            'All orphan pages (2, 5, 9) belong in ONE OTHER segment');
        DocSegment other = findByType(out, FALLBACK);
        Assert.areEqual(3, other.pages.size());
    }

    // ----- Sanitizing bad inputs ---------------------------------------------

    @IsTest
    static void shouldIgnoreInvalidSegments_WhenBlankTypeOrEmptyPages() {
        List<DocSegment> raw = new List<DocSegment>{
            null,
            buildSegment('', null, null, null, new List<Integer>{1}),
            buildSegment(null, null, null, null, new List<Integer>{1}),
            buildSegment('PASSPORT', null, null, null, null),
            buildSegment('PASSPORT', null, null, null, new List<Integer>()),
            buildSegment('PASSPORT', null, null, null, new List<Integer>{1, 2, 3})
        };

        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(raw, 3, FALLBACK);
        Test.stopTest();

        Assert.areEqual(1, out.size(), 'Only the one valid segment survives');
        Assert.areEqual('PASSPORT', out[0].documentType);
        Assert.areEqual(3, out[0].pages.size());
    }

    @IsTest
    static void shouldDropOutOfBoundsPages_WhenAboveTotalPagesOrBelowOne() {
        List<DocSegment> raw = new List<DocSegment>{
            buildSegment('PASSPORT', null, null, null, new List<Integer>{0, 1, 2, 100})
        };
        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(raw, 5, FALLBACK);
        Test.stopTest();
        DocSegment passport = findByType(out, 'PASSPORT');
        Assert.areEqual(2, passport.pages.size(), 'Out-of-bounds pages 0 and 100 dropped');
        Assert.isTrue(passport.pages.contains(1));
        Assert.isTrue(passport.pages.contains(2));
    }

    @IsTest
    static void shouldDropSegmentEntirely_WhenAllPagesOutOfBounds() {
        List<DocSegment> raw = new List<DocSegment>{
            buildSegment('PASSPORT', null, null, null, new List<Integer>{100, 200, 300})
        };
        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(raw, 5, FALLBACK);
        Test.stopTest();
        Assert.areEqual(1, out.size(), 'No valid segments → only the fallback OTHER for full bundle');
        Assert.areEqual(FALLBACK, out[0].documentType);
        Assert.areEqual(5, out[0].pages.size());
    }

    // ----- Helpers -----------------------------------------------------------

    private static DocSegment buildSegment(String type, String source, String party, String label, List<Integer> pages) {
        DocSegment s = new DocSegment();
        s.documentType = type;
        s.sourceInstitution = source;
        s.namedParty = party;
        s.instanceLabel = label;
        s.pages = pages;
        return s;
    }

    private static DocSegment findByType(List<DocSegment> segments, String type) {
        for (DocSegment s : segments) {
            if (s.documentType == type) {
                return s;
            }
        }
        return null;
    }

    private static Integer countByType(List<DocSegment> segments, String type) {
        Integer count = 0;
        for (DocSegment s : segments) {
            if (s.documentType == type) count++;
        }
        return count;
    }
}

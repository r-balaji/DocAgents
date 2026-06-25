/**
 * Unit tests for SegmentMerger.
 *
 * Pure logic -- no SOQL, DML, or async, so no @TestSetup is needed.
 * Coverage target: 100% (critical pre-LWC merge step in the document splitter).
 */
@IsTest
private class SegmentMergerTest {

    private static final String FALLBACK = 'OTHER';

    // --- Trivial passthrough ---------------------------------------------

    @IsTest
    static void shouldReturnEmpty_WhenTotalPagesNull() {
        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(
            new List<DocSegment>(), null, FALLBACK);
        Test.stopTest();

        Assert.areEqual(0, out.size(), 'Null totalPages should produce empty list');
    }

    @IsTest
    static void shouldReturnEmpty_WhenTotalPagesZero() {
        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(
            new List<DocSegment>(), 0, FALLBACK);
        Test.stopTest();

        Assert.areEqual(0, out.size(), 'Zero totalPages should produce empty list');
    }

    @IsTest
    static void shouldFillEntireBundleWithFallback_WhenNoSegments() {
        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(
            new List<DocSegment>(), 10, FALLBACK);
        Test.stopTest();

        Assert.areEqual(1, out.size(), 'Empty segments should produce one fallback segment');
        Assert.areEqual(FALLBACK, out[0].documentType, 'Type should be fallback');
        Assert.areEqual(1, out[0].startPage, 'Should start at page 1');
        Assert.areEqual(10, out[0].endPage, 'Should end at totalPages');
    }

    @IsTest
    static void shouldFillEntireBundleWithFallback_WhenRawSegmentsNull() {
        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(null, 5, FALLBACK);
        Test.stopTest();

        Assert.areEqual(1, out.size(), 'Null raw segments should produce one fallback segment');
        Assert.areEqual(FALLBACK, out[0].documentType, 'Type should be fallback');
        Assert.areEqual(1, out[0].startPage, 'Should start at page 1');
        Assert.areEqual(5, out[0].endPage, 'Should end at totalPages');
    }

    @IsTest
    static void shouldPassThroughSingleSegment_WhenItCoversWholeBundle() {
        List<DocSegment> raw = new List<DocSegment>{
            new DocSegment('PASSPORT', 1, 5)
        };

        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(raw, 5, FALLBACK);
        Test.stopTest();

        Assert.areEqual(1, out.size(), 'Single full-coverage segment should pass through');
        Assert.areEqual('PASSPORT', out[0].documentType, 'Type should be preserved');
        Assert.areEqual(1, out[0].startPage, 'Start should be 1');
        Assert.areEqual(5, out[0].endPage, 'End should be 5');
    }

    // --- Merging same-type -----------------------------------------------

    @IsTest
    static void shouldMergeAdjacentSegments_WhenSameType() {
        // A 1-3, A 4-6 -> A 1-6 (perfectly adjacent, no overlap).
        List<DocSegment> raw = new List<DocSegment>{
            new DocSegment('W2', 1, 3),
            new DocSegment('W2', 4, 6)
        };

        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(raw, 6, FALLBACK);
        Test.stopTest();

        Assert.areEqual(1, out.size(), 'Two adjacent same-type segments should merge into one');
        Assert.areEqual('W2', out[0].documentType, 'Type should be W2');
        Assert.areEqual(1, out[0].startPage, 'Start should be 1');
        Assert.areEqual(6, out[0].endPage, 'End should be 6');
    }

    @IsTest
    static void shouldMergeOverlappingSegments_WhenSameType() {
        // Bank Statement 7-9, Bank Statement 8-10 -> Bank Statement 7-10 (overlap absorbed).
        List<DocSegment> raw = new List<DocSegment>{
            new DocSegment('BANK_STATEMENT', 7, 9),
            new DocSegment('BANK_STATEMENT', 8, 10)
        };

        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(raw, 10, FALLBACK);
        Test.stopTest();

        DocSegment realDoc = findByType(out, 'BANK_STATEMENT');
        Assert.isNotNull(realDoc, 'Bank Statement segment should be present');
        Assert.areEqual(7, realDoc.startPage, 'Merged start should be 7');
        Assert.areEqual(10, realDoc.endPage, 'Merged end should be 10');
    }

    @IsTest
    static void shouldHealChunkSeam_WhenSameTypeStraddlesBoundary() {
        // The acceptance criterion from spec Sec11: a doc spans pages 7-10,
        // chunk boundary at 8, both chunks report the same doc -> must collapse.
        // Chunk A: pages 1-8, says doc starts at 7 -> segment 7-8
        // Chunk B: pages 7-14, says doc spans 7-10 (because of overlap) -> segment 7-10
        List<DocSegment> raw = new List<DocSegment>{
            new DocSegment('PAY_STUB', 7, 8),
            new DocSegment('PAY_STUB', 7, 10)
        };

        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(raw, 14, FALLBACK);
        Test.stopTest();

        DocSegment realDoc = findByType(out, 'PAY_STUB');
        Assert.isNotNull(realDoc, 'Pay Stub segment should be present');
        Assert.areEqual(7, realDoc.startPage, 'Healed segment should start at 7');
        Assert.areEqual(10, realDoc.endPage, 'Healed segment should end at 10 (no fragment at seam)');

        Integer payStubCount = 0;
        for (DocSegment s : out) {
            if (s.documentType == 'PAY_STUB') {
                payStubCount++;
            }
        }
        Assert.areEqual(1, payStubCount, 'Seam should heal to exactly one Pay Stub segment');
    }

    @IsTest
    static void shouldCarrySourceInstitution_WhenMergingSameType() {
        // First chunk doesn't know the source; second chunk does. The merger should propagate.
        List<DocSegment> raw = new List<DocSegment>{
            new DocSegment('BANK_STATEMENT', null, 1, 3),
            new DocSegment('BANK_STATEMENT', 'Chase', 3, 5)
        };

        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(raw, 5, FALLBACK);
        Test.stopTest();

        DocSegment realDoc = findByType(out, 'BANK_STATEMENT');
        Assert.isNotNull(realDoc, 'Bank Statement segment should be present');
        Assert.areEqual('Chase', realDoc.sourceInstitution,
            'Source institution from the second chunk should be carried forward');
    }

    // --- Splitting conflicting overlaps ----------------------------------

    @IsTest
    static void shouldSplitAtMidpoint_WhenDifferentTypesOverlap() {
        // PASSPORT 1-6, DRIVERS_LICENSE 4-9 -> overlap is pages 4-6 (start=4, end=6),
        // midpoint = 4 + (6-4)/2 = 5. So PASSPORT keeps 1-5, DRIVERS_LICENSE takes 6-9.
        List<DocSegment> raw = new List<DocSegment>{
            new DocSegment('PASSPORT', 1, 6),
            new DocSegment('DRIVERS_LICENSE', 4, 9)
        };

        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(raw, 9, FALLBACK);
        Test.stopTest();

        DocSegment passport = findByType(out, 'PASSPORT');
        DocSegment license = findByType(out, 'DRIVERS_LICENSE');
        Assert.isNotNull(passport, 'PASSPORT segment should remain');
        Assert.isNotNull(license, 'DRIVERS_LICENSE segment should remain');
        Assert.areEqual(1, passport.startPage, 'PASSPORT should still start at 1');
        Assert.areEqual(5, passport.endPage, 'PASSPORT should end at midpoint (5)');
        Assert.areEqual(6, license.startPage, 'DRIVERS_LICENSE should start at midpoint+1 (6)');
        Assert.areEqual(9, license.endPage, 'DRIVERS_LICENSE should end at 9');
    }

    @IsTest
    static void shouldDropContainedSegment_WhenFullyInsidePrevious() {
        // PASSPORT 1-10 (large), W2 4-6 (fully contained) -- the larger first segment wins.
        // Note: sort sends PASSPORT first because longer-segment-first breaks tie at startPage=1.
        List<DocSegment> raw = new List<DocSegment>{
            new DocSegment('PASSPORT', 1, 10),
            new DocSegment('W2', 4, 6)
        };

        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(raw, 10, FALLBACK);
        Test.stopTest();

        Assert.areEqual(1, out.size(), 'Fully-contained different-type segment should be dropped');
        Assert.areEqual('PASSPORT', out[0].documentType, 'Containing segment should remain');
        Assert.areEqual(1, out[0].startPage, 'Start preserved');
        Assert.areEqual(10, out[0].endPage, 'End preserved');
    }

    // --- Gap-filling with fallback ---------------------------------------

    @IsTest
    static void shouldFillGapBetweenSegments_WithFallback() {
        // PASSPORT 1-3, then gap 4-5, then W2 6-8.
        List<DocSegment> raw = new List<DocSegment>{
            new DocSegment('PASSPORT', 1, 3),
            new DocSegment('W2', 6, 8)
        };

        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(raw, 8, FALLBACK);
        Test.stopTest();

        Assert.areEqual(3, out.size(), 'Should produce [PASSPORT, OTHER gap, W2]');
        Assert.areEqual('PASSPORT', out[0].documentType, 'First segment is PASSPORT');
        Assert.areEqual(FALLBACK, out[1].documentType, 'Middle segment is fallback');
        Assert.areEqual(4, out[1].startPage, 'Gap starts at 4');
        Assert.areEqual(5, out[1].endPage, 'Gap ends at 5');
        Assert.areEqual('W2', out[2].documentType, 'Third segment is W2');
    }

    @IsTest
    static void shouldFillLeadingGap_WithFallback() {
        // No segment for pages 1-4; first real segment starts at page 5.
        List<DocSegment> raw = new List<DocSegment>{
            new DocSegment('PASSPORT', 5, 7)
        };

        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(raw, 7, FALLBACK);
        Test.stopTest();

        Assert.areEqual(2, out.size(), 'Should produce [OTHER 1-4, PASSPORT 5-7]');
        Assert.areEqual(FALLBACK, out[0].documentType, 'Leading gap is fallback');
        Assert.areEqual(1, out[0].startPage, 'Leading gap starts at 1');
        Assert.areEqual(4, out[0].endPage, 'Leading gap ends at 4');
        Assert.areEqual('PASSPORT', out[1].documentType, 'Then PASSPORT');
    }

    @IsTest
    static void shouldFillTrailingGap_WithFallback() {
        // PASSPORT covers 1-5; bundle has 8 pages so 6-8 needs a fallback.
        List<DocSegment> raw = new List<DocSegment>{
            new DocSegment('PASSPORT', 1, 5)
        };

        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(raw, 8, FALLBACK);
        Test.stopTest();

        Assert.areEqual(2, out.size(), 'Should produce [PASSPORT 1-5, OTHER 6-8]');
        Assert.areEqual('PASSPORT', out[0].documentType, 'First is PASSPORT');
        Assert.areEqual(FALLBACK, out[1].documentType, 'Trailing gap is fallback');
        Assert.areEqual(6, out[1].startPage, 'Trailing gap starts at 6');
        Assert.areEqual(8, out[1].endPage, 'Trailing gap ends at 8 (totalPages)');
    }

    // --- Sanitizing bad inputs -------------------------------------------

    @IsTest
    static void shouldIgnoreInvalidSegments_WhenBlankTypeOrNullPages() {
        List<DocSegment> raw = new List<DocSegment>{
            null,
            new DocSegment('', 1, 3),
            new DocSegment(null, 1, 3),
            new DocSegment('PASSPORT', null, 3),
            new DocSegment('PASSPORT', 1, null),
            new DocSegment('PASSPORT', 1, 3)
        };

        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(raw, 3, FALLBACK);
        Test.stopTest();

        Assert.areEqual(1, out.size(), 'Only the one valid segment should survive');
        Assert.areEqual('PASSPORT', out[0].documentType, 'Valid segment preserved');
        Assert.areEqual(1, out[0].startPage, 'Valid start preserved');
        Assert.areEqual(3, out[0].endPage, 'Valid end preserved');
    }

    @IsTest
    static void shouldClampOutOfBoundsPages_WhenStartBeforeOneOrEndAfterTotal() {
        // startPage 0 -> clamped to 1; endPage 100 -> clamped to totalPages (5).
        List<DocSegment> raw = new List<DocSegment>{
            new DocSegment('PASSPORT', 0, 100)
        };

        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(raw, 5, FALLBACK);
        Test.stopTest();

        Assert.areEqual(1, out.size(), 'Should produce one clamped segment');
        Assert.areEqual('PASSPORT', out[0].documentType, 'Type preserved');
        Assert.areEqual(1, out[0].startPage, 'Start clamped to 1');
        Assert.areEqual(5, out[0].endPage, 'End clamped to totalPages');
    }

    @IsTest
    static void shouldDropSegmentEntirely_WhenAllPagesOutOfBounds() {
        // Segment is 100-200 but totalPages is 5 -- entire range out of bounds, drop it.
        List<DocSegment> raw = new List<DocSegment>{
            new DocSegment('PASSPORT', 100, 200)
        };

        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(raw, 5, FALLBACK);
        Test.stopTest();

        Assert.areEqual(1, out.size(), 'Should be one fallback segment for the whole bundle');
        Assert.areEqual(FALLBACK, out[0].documentType, 'Type should be fallback');
        Assert.areEqual(1, out[0].startPage, 'Start at 1');
        Assert.areEqual(5, out[0].endPage, 'End at totalPages');
    }

    // --- Sorting behavior ------------------------------------------------

    @IsTest
    static void shouldSortByStartPage_WhenInputUnordered() {
        // Input given in reverse order -- output must be sorted ascending.
        List<DocSegment> raw = new List<DocSegment>{
            new DocSegment('W2', 7, 9),
            new DocSegment('PASSPORT', 1, 3),
            new DocSegment('PAY_STUB', 4, 6)
        };

        Test.startTest();
        List<DocSegment> out = SegmentMerger.mergeSegments(raw, 9, FALLBACK);
        Test.stopTest();

        Assert.areEqual(3, out.size(), 'Three real segments, contiguous coverage, no gaps');
        Assert.areEqual('PASSPORT', out[0].documentType, 'First by startPage is PASSPORT');
        Assert.areEqual('PAY_STUB', out[1].documentType, 'Second is PAY_STUB');
        Assert.areEqual('W2', out[2].documentType, 'Third is W2');
    }

    // --- Helper ----------------------------------------------------------

    private static DocSegment findByType(List<DocSegment> segments, String type) {
        for (DocSegment s : segments) {
            if (s.documentType == type) {
                return s;
            }
        }
        return null;
    }
}

/**
 * Pure-logic utility for the AI Document Splitter.
 *
 * Validates the raw classification segments returned by the vision prompt
 * (page-list shaped) and produces the final list the LWC uses for slicing.
 *
 * Responsibilities (page-list model):
 *  1. Sanitize: drop entries with blank type, drop out-of-bounds pages.
 *  2. De-duplicate: if two segments claim the same page, the first claimant wins
 *     (vision prompts shouldn't produce duplicates, but defend against it).
 *  3. Fill gaps: any page in [1..totalPages] not claimed by any segment becomes
 *     part of a single synthetic OTHER segment.
 *
 * Notable simplifications vs. the old range-based merger: the "merge adjacent
 * same-type" and "split conflicting overlap at midpoint" logic is gone — both
 * existed only because chunks classify in overlapping ranges. With page-list
 * segments, identity is explicit and the merger is just a coverage validator.
 *
 * No SOQL, no DML, no callouts.
 */
public class SegmentMerger {

    private static final Integer MIN_PAGE = 1;

    private SegmentMerger() {
        // Utility class -- instantiation prevented.
    }

    /**
     * Validate raw segments and fill any unclaimed pages with a fallback OTHER segment.
     *
     * @param rawSegments segments returned by the AI (any order, page lists may
     *                    include duplicates or out-of-bounds values).
     * @param totalPages  total page count of the source bundle (1-indexed). Null
     *                    or non-positive returns an empty list.
     * @param fallbackType Type_Code__c of the fallback Document_Type__mdt (OTHER).
     * @return list of segments whose page lists collectively cover every page in
     *         [1..totalPages] exactly once.
     */
    public static List<DocSegment> mergeSegments(List<DocSegment> rawSegments, Integer totalPages, String fallbackType) {
        if (totalPages == null || totalPages < MIN_PAGE) {
            return new List<DocSegment>();
        }

        Set<Integer> claimed = new Set<Integer>();
        List<DocSegment> out = new List<DocSegment>();

        if (rawSegments != null) {
            for (DocSegment s : rawSegments) {
                if (s == null || String.isBlank(s.documentType) || s.pages == null) {
                    continue;
                }
                List<Integer> validPages = new List<Integer>();
                for (Integer p : s.pages) {
                    if (p == null) {
                        continue;
                    }
                    if (p < MIN_PAGE || p > totalPages) {
                        continue;
                    }
                    if (claimed.contains(p)) {
                        continue;   // first claimant wins
                    }
                    validPages.add(p);
                    claimed.add(p);
                }
                if (validPages.isEmpty()) {
                    continue;
                }
                out.add(new DocSegment(s.documentType, s.sourceInstitution, s.namedParty, s.instanceLabel, validPages));
            }
        }

        // Any pages not claimed by a real segment land in one synthetic OTHER segment.
        List<Integer> orphans = new List<Integer>();
        for (Integer p = MIN_PAGE; p <= totalPages; p++) {
            if (!claimed.contains(p)) {
                orphans.add(p);
            }
        }
        if (!orphans.isEmpty()) {
            out.add(new DocSegment(fallbackType, null, null, null, orphans));
        }

        return out;
    }
}

/**
 * Pure-logic utility for the AI Document Splitter.
 *
 * Takes the raw per-chunk classification segments returned by the vision prompt
 * (each carrying absolute page numbers) and produces the final, non-overlapping
 * segments that the LWC will use to split the source PDF.
 *
 * Rules:
 * 1. Segments of the SAME documentType that are adjacent or overlapping are merged.
 * 2. Two segments of DIFFERENT documentTypes that overlap are split at the overlap
 * midpoint, with each side keeping its own type.
 * 3. Any page in [1..totalPages] not covered by a real segment becomes a
 * synthetic segment of the fallback type (e.g. "OTHER").
 * 4. The output is sorted by startPage, contiguous, and covers every page exactly once.
 *
 * No SOQL, no DML, no callouts -- designed to be unit-tested in isolation and
 * called from a Queueable that handles AI orchestration.
 */
public class SegmentMerger {

    private static final Integer MIN_PAGE = 1;

    private SegmentMerger() {
        // Utility class -- instantiation prevented.
    }

    /**
     * Coalesce overlapping/adjacent same-type segments, split conflicting overlaps,
     * and fill page gaps with the fallback type.
     *
     * @param rawSegments per-chunk segments returned by the AI; may be unsorted and may overlap.
     * Null or empty is treated as "no real segments" and the whole bundle
     * becomes one fallback segment.
     * @param totalPages total page count of the source bundle (1-indexed). Null or
     * non-positive returns an empty list.
     * @param fallbackType Type_Code__c of the Is_Fallback__c=true Document_Type__mdt record
     * (e.g. "OTHER"). Pages not covered by a real segment become a
     * synthetic segment of this type.
     * @return contiguous, sorted list of segments that exactly cover pages 1..totalPages.
     */
    public static List<DocSegment> mergeSegments(List<DocSegment> rawSegments, Integer totalPages, String fallbackType) {
        if (totalPages == null || totalPages < MIN_PAGE) {
            return new List<DocSegment>();
        }

        List<DocSegment> cleaned = sanitize(rawSegments, totalPages);
        cleaned.sort(new SegmentComparator());

        List<DocSegment> coalesced = coalesceAndSplit(cleaned);

        return fillGaps(coalesced, totalPages, fallbackType);
    }

    /**
     * Drop invalid / out-of-bounds inputs and clamp ranges into [1..totalPages].
     */
    private static List<DocSegment> sanitize(List<DocSegment> raw, Integer totalPages) {
        List<DocSegment> out = new List<DocSegment>();
        if (raw == null) {
            return out;
        }
        for (DocSegment s : raw) {
            if (s == null
                || String.isBlank(s.documentType)
                || s.startPage == null
                || s.endPage == null) {
                continue;
            }
            Integer startP = Math.max(MIN_PAGE, s.startPage);
            Integer endP = Math.min(totalPages, s.endPage);
            if (endP < startP) {
                continue;
            }
            out.add(new DocSegment(s.documentType, s.sourceInstitution, s.namedParty, startP, endP));
        }
        return out;
    }

    /**
     * Walk sorted segments left-to-right. For each segment, decide:
     * - disjoint from the previous output -> append
     * - same type as previous output, adjacent or overlapping -> merge into previous
     * - different type but contained inside previous -> drop (previous won the priority tie)
     * - different type extending past previous -> split at the overlap midpoint
     */
    private static List<DocSegment> coalesceAndSplit(List<DocSegment> sorted) {
        List<DocSegment> out = new List<DocSegment>();
        for (DocSegment incoming : sorted) {
            if (out.isEmpty()) {
                out.add(incoming);
                continue;
            }
            DocSegment last = out[out.size() - 1];

            if (incoming.startPage > last.endPage + 1) {
                out.add(incoming);
                continue;
            }

            // Merge only when BOTH the document type matches AND the named parties are
            // compatible. Parties are compatible if both are blank, OR one is blank
            // (one chunk didn't extract the name), OR both normalize to the same string.
            // Two adjacent DRIVERS_LICENSE segments with DIFFERENT populated names
            // (John on page 4, Jimmy on page 5) stay as separate segments.
            Boolean sameType = last.documentType == incoming.documentType;
            Boolean partiesCompatible = arePartiesCompatible(last.namedParty, incoming.namedParty);

            if (sameType && partiesCompatible) {
                last.endPage = Math.max(last.endPage, incoming.endPage);
                if (String.isBlank(last.sourceInstitution) && String.isNotBlank(incoming.sourceInstitution)) {
                    last.sourceInstitution = incoming.sourceInstitution;
                }
                if (String.isBlank(last.namedParty) && String.isNotBlank(incoming.namedParty)) {
                    last.namedParty = incoming.namedParty;
                }
                continue;
            }

            // Adjacent but different key (different type OR different populated party).
            // They are touching, not overlapping — just append the incoming segment.
            // The split-at-midpoint branch below only applies to true overlaps.
            Boolean adjacentNotOverlapping = incoming.startPage == last.endPage + 1;
            if (adjacentNotOverlapping) {
                out.add(incoming);
                continue;
            }

            if (incoming.endPage <= last.endPage) {
                continue;
            }

            Integer overlapStart = incoming.startPage;
            Integer overlapEnd = last.endPage;
            Integer mid = overlapStart + (overlapEnd - overlapStart) / 2;
            last.endPage = mid;
            incoming.startPage = mid + 1;
            if (incoming.startPage > incoming.endPage) {
                continue;
            }
            out.add(incoming);
        }
        return out;
    }

    /**
     * Fill any page gaps (before the first segment, between segments, after the last)
     * with synthetic segments of the fallback type so the output covers every page.
     */
    private static List<DocSegment> fillGaps(List<DocSegment> coalesced, Integer totalPages, String fallbackType) {
        List<DocSegment> filled = new List<DocSegment>();
        Integer cursor = MIN_PAGE;
        for (DocSegment s : coalesced) {
            if (s.startPage > cursor) {
                filled.add(new DocSegment(fallbackType, cursor, s.startPage - 1));
            }
            filled.add(s);
            cursor = s.endPage + 1;
        }
        if (cursor <= totalPages) {
            filled.add(new DocSegment(fallbackType, cursor, totalPages));
        }
        return filled;
    }

    /**
     * Lowercase + strip non-essential whitespace/punctuation so that two named
     * parties that differ only by case ("John Smith" vs "JOHN SMITH") or formatting
     * ("John Smith" vs "John  Smith") collapse to the same key. Returns empty string
     * for null/blank inputs so two null names compare equal (both treated as "no party").
     */
    @TestVisible
    private static String normalizeName(String s) {
        if (String.isBlank(s)) {
            return '';
        }
        return s.toLowerCase().replaceAll('\\s+', ' ').trim();
    }

    /**
     * Two party names are "compatible" for merging if at least one is blank, or
     * if both normalize to the same string. Blank-vs-populated represents the
     * common chunk-seam case where one chunk extracted the name and the other
     * did not; we treat that as the same document.
     */
    @TestVisible
    private static Boolean arePartiesCompatible(String a, String b) {
        String aNorm = normalizeName(a);
        String bNorm = normalizeName(b);
        if (aNorm == '' || bNorm == '') {
            return true;
        }
        return aNorm == bNorm;
    }

    /**
     * Sort by startPage ascending; on tie, the longer segment wins so the
     * merge step has a stable left edge to work against.
     */
    private class SegmentComparator implements System.Comparator<DocSegment> {
        public Integer compare(DocSegment a, DocSegment b) {
            if (a.startPage != b.startPage) {
                return a.startPage - b.startPage;
            }
            Integer aLen = a.endPage - a.startPage;
            Integer bLen = b.endPage - b.startPage;
            return bLen - aLen;
        }
    }
}

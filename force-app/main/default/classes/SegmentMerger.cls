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
 *  3. Group: combine segments with the same document type, party, and source.
 *  4. Fill gaps: any page in [1..totalPages] not claimed by any segment becomes
 *     part of a single synthetic OTHER segment.
 *
 * Instance labels distinguish physical documents during classification, but do
 * not create separate output files. For example, monthly statements from the
 * same bank for the same party are consolidated into one output.
 *
 * No SOQL, no DML, no callouts.
 */
public inherited sharing class SegmentMerger {

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
     * @param fallbackType Fallback document type code (OTHER).
     * @return grouped segments whose page lists collectively cover every page in
     *         [1..totalPages] exactly once.
     */
    public static List<DocSegment> mergeSegments(List<DocSegment> rawSegments, Integer totalPages, String fallbackType) {
        if (totalPages == null || totalPages < MIN_PAGE) {
            return new List<DocSegment>();
        }

        Set<Integer> claimed = new Set<Integer>();
        Map<String, DocSegment> segmentsByGroupKey = new Map<String, DocSegment>();
        List<String> orderedGroupKeys = new List<String>();

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
                addToGroup(segmentsByGroupKey, orderedGroupKeys, s, validPages, fallbackType);
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
            addToGroup(
                segmentsByGroupKey,
                orderedGroupKeys,
                new DocSegment(fallbackType, null, null, null, orphans),
                orphans,
                fallbackType
            );
        }

        List<DocSegment> out = new List<DocSegment>();
        for (String groupKey : orderedGroupKeys) {
            DocSegment segment = segmentsByGroupKey.get(groupKey);
            segment.pages.sort();
            out.add(segment);
        }

        return out;
    }

    private static void addToGroup(
        Map<String, DocSegment> segmentsByGroupKey,
        List<String> orderedGroupKeys,
        DocSegment sourceSegment,
        List<Integer> pages,
        String fallbackType
    ) {
        Boolean isFallback = sameGroupValue(sourceSegment.documentType, fallbackType);
        String groupKey = buildGroupKey(sourceSegment, isFallback);
        if (!segmentsByGroupKey.containsKey(groupKey)) {
            segmentsByGroupKey.put(groupKey, new DocSegment(
                sourceSegment.documentType,
                isFallback ? null : sourceSegment.sourceInstitution,
                isFallback ? null : sourceSegment.namedParty,
                isFallback ? null : sourceSegment.instanceLabel,
                new List<Integer>(pages)
            ));
            orderedGroupKeys.add(groupKey);
            return;
        }

        DocSegment grouped = segmentsByGroupKey.get(groupKey);
        grouped.pages.addAll(pages);
        grouped.instanceLabel = commonInstanceLabel(grouped.instanceLabel, sourceSegment.instanceLabel);
    }

    private static String buildGroupKey(DocSegment segment, Boolean isFallback) {
        String typeKey = normalizeGroupValue(segment.documentType);
        if (isFallback) {
            return typeKey;
        }
        return typeKey
            + '|' + normalizeGroupValue(segment.namedParty)
            + '|' + normalizeGroupValue(segment.sourceInstitution);
    }

    private static String commonInstanceLabel(String currentLabel, String nextLabel) {
        if (String.isBlank(currentLabel) || String.isBlank(nextLabel)) {
            return null;
        }
        return sameGroupValue(currentLabel, nextLabel) ? currentLabel : null;
    }

    private static Boolean sameGroupValue(String left, String right) {
        return normalizeGroupValue(left) == normalizeGroupValue(right);
    }

    private static String normalizeGroupValue(String value) {
        return String.isBlank(value) ? '' : value.trim().toLowerCase().replaceAll('\\s+', ' ');
    }
}

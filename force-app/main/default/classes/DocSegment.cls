/**
 * DTO representing one detected document instance inside a bundle.
 *
 * Produced by the AI vision prompt (one per distinct document instance,
 * regardless of whether its pages are contiguous or scattered) and consumed
 * by SegmentMerger and the splitter's save pipeline.
 *
 * Fields:
 *  - documentType: one of the Document_Type__mdt.Type_Code__c values (e.g. BANK_STATEMENT).
 *  - sourceInstitution: optional, only populated for types where
 *    Document_Type__mdt.Capture_Source__c is true (e.g. Bank Statement -> Chase).
 *  - namedParty: optional, the person or business name on the document.
 *  - instanceLabel: optional, distinguishes multiple instances of the same type
 *    (e.g. "Chase 2026-04" vs "Wells Fargo 2026-04"). Used by the prompt for
 *    grouping reasoning and by file-naming to disambiguate outputs.
 *  - pages: 1-based, absolute page numbers belonging to this document. Pages
 *    may be non-contiguous (e.g. license front on page 1, back on page 10).
 *    Within an entry, pages are in natural reading order.
 */
public class DocSegment {

    public String documentType;
    public String sourceInstitution;
    public String namedParty;
    public String instanceLabel;
    public List<Integer> pages;

    public DocSegment() {
        this.pages = new List<Integer>();
    }

    public DocSegment(String documentType, List<Integer> pages) {
        this(documentType, null, null, null, pages);
    }

    public DocSegment(String documentType, String sourceInstitution, String namedParty, String instanceLabel, List<Integer> pages) {
        this.documentType = documentType;
        this.sourceInstitution = sourceInstitution;
        this.namedParty = namedParty;
        this.instanceLabel = instanceLabel;
        this.pages = pages == null ? new List<Integer>() : pages;
    }
}

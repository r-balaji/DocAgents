/**
 * DTO representing one classified page range inside a document bundle.
 *
 * Produced by the AI vision prompt (one per detected segment) and consumed by
 * SegmentMerger, which coalesces them into the final non-overlapping list.
 *
 * Fields:
 *  - documentType: one of the Document_Type__mdt.Type_Code__c values (e.g. BANK_STATEMENT).
 *  - sourceInstitution: optional, only populated for types where
 *    Document_Type__mdt.Capture_Source__c is true (e.g. Bank Statement -> Chase).
 *  - namedParty: optional, the person or business name on the document
 *    (e.g. "John Smith" for a Driver's License, "Vance Electric LLC" for Articles
 *    of Incorporation). Used by SegmentMerger to keep documents of the same type
 *    but different parties separate (e.g. John's DL and Jimmy's DL stay as
 *    two segments even if they appear on adjacent pages).
 *  - startPage / endPage: 1-based, inclusive.
 */
public class DocSegment {

    public String documentType;
    public String sourceInstitution;
    public String namedParty;
    public Integer startPage;
    public Integer endPage;

    public DocSegment() {}

    public DocSegment(String documentType, Integer startPage, Integer endPage) {
        this(documentType, null, null, startPage, endPage);
    }

    public DocSegment(String documentType, String sourceInstitution, Integer startPage, Integer endPage) {
        this(documentType, sourceInstitution, null, startPage, endPage);
    }

    public DocSegment(String documentType, String sourceInstitution, String namedParty, Integer startPage, Integer endPage) {
        this.documentType = documentType;
        this.sourceInstitution = sourceInstitution;
        this.namedParty = namedParty;
        this.startPage = startPage;
        this.endPage = endPage;
    }
}

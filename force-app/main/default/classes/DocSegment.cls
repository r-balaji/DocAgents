/**
 * DTO representing one classified page range inside a document bundle.
 *
 * Produced by the AI vision prompt (one per detected segment) and consumed by
 * SegmentMerger, which coalesces them into the final non-overlapping list.
 * sourceInstitution is optional and only populated for document types where
 * Document_Type__mdt.Capture_Source__c is true (e.g. Bank Statement -> Chase).
 */
public class DocSegment {

    public String documentType;
    public String sourceInstitution;
    public Integer startPage;
    public Integer endPage;

    public DocSegment() {}

    public DocSegment(String documentType, Integer startPage, Integer endPage) {
        this(documentType, null, startPage, endPage);
    }

    public DocSegment(String documentType, String sourceInstitution, Integer startPage, Integer endPage) {
        this.documentType = documentType;
        this.sourceInstitution = sourceInstitution;
        this.startPage = startPage;
        this.endPage = endPage;
    }
}

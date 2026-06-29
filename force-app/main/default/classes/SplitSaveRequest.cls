/**
 * DTO representing one split PDF the LWC is asking us to save back to the library.
 *
 * The LWC builds these after running pdf-lib in the browser to extract the pages
 * (which may be non-contiguous) for one detected document instance. base64Content
 * holds the binary PDF for that document; pages is the absolute page list it
 * was assembled from (kept for traceability / debugging, not used to re-slice).
 *
 * fileName is built by the LWC (or via buildFileName below) using documentType,
 * sourceInstitution, namedParty, and an index so multiple files of the same kind
 * within one bundle don't collide.
 */
public class SplitSaveRequest {

    public String fileName;
    public String base64Content;
    public String documentType;
    public String sourceInstitution;
    public String namedParty;
    public String instanceLabel;
    public List<Integer> pages;

    public SplitSaveRequest() {}

    /**
     * Build a human-readable, filesystem-safe filename from the AI segment's metadata.
     *
     * Two patterns:
     *  - Known types: include source institution + named party so the loan
     *    officer can tell whose document it is.
     *      BankStatement_Bank_of_America_John_Smith.pdf
     *      DriversLicense_Jane_Doe.pdf
     *  - OTHER (fallback): strip party/source, use clean Other_N numbering.
     *    The AI's party extraction on unrecognized pages is unreliable noise.
     *      Other_1.pdf, Other_2.pdf, ...
     */
    public static String buildFileName(String documentType, String sourceInstitution, String namedParty, Integer index) {
        if ('OTHER'.equals(documentType)) {
            return 'Other_' + (index == null ? 1 : index) + '.pdf';
        }
        List<String> parts = new List<String>{ toTitleCase(documentType) };
        if (String.isNotBlank(sourceInstitution)) {
            parts.add(sanitize(sourceInstitution));
        }
        if (String.isNotBlank(namedParty)) {
            parts.add(sanitize(namedParty));
        }
        if (index != null && index > 1) {
            parts.add(String.valueOf(index));
        }
        return String.join(parts, '_') + '.pdf';
    }

    // BANK_STATEMENT -> BankStatement
    private static String toTitleCase(String typeCode) {
        if (String.isBlank(typeCode)) {
            return 'Document';
        }
        List<String> words = typeCode.toLowerCase().split('_');
        List<String> capped = new List<String>();
        for (String w : words) {
            if (w.length() == 0) {
                continue;
            }
            capped.add(w.substring(0, 1).toUpperCase() + (w.length() > 1 ? w.substring(1) : ''));
        }
        return String.join(capped, '');
    }

    // Strip filename-unfriendly chars: anything not letter/digit/dash/underscore.
    private static String sanitize(String s) {
        if (String.isBlank(s)) {
            return '';
        }
        // Collapse runs of non-alphanumerics to single underscore.
        String collapsed = s.replaceAll('[^A-Za-z0-9]+', '_');
        // Trim leading/trailing underscores.
        return collapsed.replaceAll('^_+|_+$', '');
    }
}

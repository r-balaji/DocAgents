/**
 * DTO representing one split PDF the LWC is asking us to save back to the library.
 *
 * The LWC builds these after running pdf-lib in the browser to extract page ranges
 * from the source bundle. base64Content holds the binary PDF for the segment.
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
    public Integer startPage;
    public Integer endPage;

    public SplitSaveRequest() {}

    /**
     * Build a human-readable, filesystem-safe filename from the AI segment's metadata.
     *
     * Examples:
     *   buildFileName('BANK_STATEMENT', 'Bank of America', 'John Smith', 1)
     *     -> 'BankStatement_BankOfAmerica_John_Smith.pdf'
     *   buildFileName('DRIVERS_LICENSE', null, 'Jane Doe', 1)
     *     -> 'DriversLicense_Jane_Doe.pdf'
     *   buildFileName('OTHER', null, null, 2)
     *     -> 'Other_2.pdf'
     */
    public static String buildFileName(String documentType, String sourceInstitution, String namedParty, Integer index) {
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

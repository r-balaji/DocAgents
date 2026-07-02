/**
 * Invocable Apex helper that decodes one review file row into separate Flow inputs.
 */
public with sharing class AIDocSplitFileRow {

    public static final String DELIMITER = '|';
    private static final String FILE_CONTENT_DOCUMENT_ID_KEY = 'fileContentDocumentId';
    private static final String CATEGORY_NAME_KEY = 'categoryName';
    private static final String PARTY_NAME_KEY = 'partyName';
    private static final String PARTY_TYPE_KEY = 'partyType';
    private static final String DOCUMENT_CATEGORY_ID_KEY = 'documentCategoryId';

    @InvocableMethod(
        label='AI Doc - Split File Row'
        description='Decodes a JSON review file row into individual values. Legacy pipe-encoded rows are still supported.'
        category='AI Document Review'
    )
    public static List<Response> execute(List<Request> requests) {
        List<Response> out = new List<Response>();
        for (Request req : requests) {
            Response r = blankResponse();
            if (req == null || String.isBlank(req.encodedRow)) {
                out.add(r);
                continue;
            }
            decodeRow(req.encodedRow, r);
            out.add(r);
        }
        return out;
    }

    private static Response blankResponse() {
        Response r = new Response();
        r.fileContentDocumentId = '';
        r.categoryName = '';
        r.partyName = '';
        r.partyType = '';
        r.documentCategoryId = '';
        return r;
    }

    private static void decodeRow(String encodedRow, Response r) {
        String trimmed = encodedRow == null ? '' : encodedRow.trim();
        if (trimmed.startsWith('{')) {
            try {
                Map<String, Object> row = (Map<String, Object>) JSON.deserializeUntyped(trimmed);
                r.fileContentDocumentId = valueAsString(row.get(FILE_CONTENT_DOCUMENT_ID_KEY));
                r.categoryName = valueAsString(row.get(CATEGORY_NAME_KEY));
                r.partyName = valueAsString(row.get(PARTY_NAME_KEY));
                r.partyType = valueAsString(row.get(PARTY_TYPE_KEY));
                r.documentCategoryId = valueAsString(row.get(DOCUMENT_CATEGORY_ID_KEY));
                return;
            } catch (Exception ignored) {
                // Fall through to legacy parsing so malformed JSON has a deterministic result.
            }
        }
        decodeLegacyPipeRow(encodedRow, r);
    }

    private static void decodeLegacyPipeRow(String encodedRow, Response r) {
        List<String> parts = encodedRow.split('\\|', -1);
        if (parts.size() > 0) { r.fileContentDocumentId = parts[0]; }
        if (parts.size() > 1) { r.categoryName = parts[1]; }
        if (parts.size() > 2) { r.partyName = parts[2]; }
        if (parts.size() > 3) { r.partyType = parts[3]; }
        if (parts.size() > 4) { r.documentCategoryId = parts[4]; }
    }

    private static String valueAsString(Object value) {
        return value == null ? '' : String.valueOf(value);
    }

    public class Request {
        @InvocableVariable(label='Encoded Row' description='JSON review file row to decode' required=true)
        public String encodedRow;
    }

    public class Response {
        @InvocableVariable(label='File ContentDocument Id') public String fileContentDocumentId;
        @InvocableVariable(label='Category Name')           public String categoryName;
        @InvocableVariable(label='Party Name')              public String partyName;
        @InvocableVariable(label='Party Type')              public String partyType;
        @InvocableVariable(label='Document Category Id')    public String documentCategoryId;
    }
}

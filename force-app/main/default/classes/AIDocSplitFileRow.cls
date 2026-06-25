/**
 * Invocable Apex helper that splits a "<docId>|<categoryName>|<partyName>|<partyType>"
 * row into its four parts so Flow can pass them as individual String inputs to the
 * AIDocVerifyOneFile subflow.
 */
public with sharing class AIDocSplitFileRow {

    public static final String DELIMITER = '|';

    @InvocableMethod(
        label='AI Doc - Split File Row'
        description='Splits a "<docId>|<categoryName>|<partyName>|<partyType>" row into its four parts.'
        category='AI Document Review'
    )
    public static List<Response> execute(List<Request> requests) {
        List<Response> out = new List<Response>();
        for (Request req : requests) {
            Response r = new Response();
            r.fileContentDocumentId = '';
            r.categoryName = '';
            r.partyName = '';
            r.partyType = '';
            if (req == null || String.isBlank(req.encodedRow)) {
                out.add(r);
                continue;
            }
            List<String> parts = req.encodedRow.split('\\|', -1);
            if (parts.size() > 0) { r.fileContentDocumentId = parts[0]; }
            if (parts.size() > 1) { r.categoryName          = parts[1]; }
            if (parts.size() > 2) { r.partyName             = parts[2]; }
            if (parts.size() > 3) { r.partyType             = parts[3]; }
            out.add(r);
        }
        return out;
    }

    public class Request {
        @InvocableVariable(label='Encoded Row' description='Pipe-encoded "<docId>|<categoryName>|<partyName>|<partyType>"' required=true)
        public String encodedRow;
    }

    public class Response {
        @InvocableVariable(label='File ContentDocument Id') public String fileContentDocumentId;
        @InvocableVariable(label='Category Name')           public String categoryName;
        @InvocableVariable(label='Party Name')              public String partyName;
        @InvocableVariable(label='Party Type')              public String partyType;
    }
}

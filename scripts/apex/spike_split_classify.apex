// Anonymous Apex driver for the Phase 3 prompt spike.
//
// Usage: paste a real ContentDocument Id (069...) into the line below, then run with:
//   sf apex run --file scripts/apex/spike_split_classify.apex --target-org "Originate Agents Enterprise"
//
// What it does:
//   1. Looks up the ContentDocument by Id (verifies the file exists).
//   2. Invokes the AIDocSplitClassifySpike subflow with that file Id.
//   3. Reads the segmentsJson output and prints it to the debug log.
//   4. Validates the response parses as a JSON array.
//
// What you should see in the log on success:
//   SPIKE_OUTPUT: [{"document_type":"...","source_institution":"...","start_page":1,"end_page":N}, ...]
//   SPIKE_PARSED: <N> segments returned

Id targetFileId = '069a500000G7T0rAAF';  // vance_electric_sample_bank_statement_april_2026_test_fixture (18KB)

ContentDocument cd = [SELECT Id, Title FROM ContentDocument WHERE Id = :targetFileId LIMIT 1];
System.debug('SPIKE_FILE: ' + cd.Title + ' (' + cd.Id + ')');

Map<String, Object> inputs = new Map<String, Object>{
    'fileContentDocumentId' => targetFileId
};

Flow.Interview interview = Flow.Interview.createInterview('AIDocSplitClassifySpike', inputs);
interview.start();

String segmentsJson = (String) interview.getVariableValue('segmentsJson');

if (String.isBlank(segmentsJson)) {
    System.debug('SPIKE_OUTPUT: <empty - prompt returned nothing>');
    return;
}

System.debug('SPIKE_OUTPUT: ' + segmentsJson);

// Validate JSON shape.
try {
    String cleaned = segmentsJson.trim();
    // Strip markdown fences if the model wrapped them despite instructions.
    if (cleaned.startsWith('```')) {
        Integer arrStart = cleaned.indexOf('[');
        Integer arrEnd = cleaned.lastIndexOf(']');
        if (arrStart >= 0 && arrEnd > arrStart) {
            cleaned = cleaned.substring(arrStart, arrEnd + 1);
        }
    }
    List<Object> parsed = (List<Object>) JSON.deserializeUntyped(cleaned);
    System.debug('SPIKE_PARSED: ' + parsed.size() + ' segments returned');
    for (Integer i = 0; i < parsed.size(); i++) {
        Map<String, Object> seg = (Map<String, Object>) parsed[i];
        System.debug('  [' + i + '] '
            + seg.get('document_type') + ' '
            + (seg.get('source_institution') == null ? '' : '(' + seg.get('source_institution') + ') ')
            + 'p' + seg.get('start_page') + '-' + seg.get('end_page'));
    }
} catch (Exception e) {
    System.debug('SPIKE_PARSE_ERROR: ' + e.getMessage());
}

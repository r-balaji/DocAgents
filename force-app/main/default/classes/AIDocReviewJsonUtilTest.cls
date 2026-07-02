/**
 * Tests for AIDocReviewJsonUtil.
 */
@IsTest
private class AIDocReviewJsonUtilTest {
    @IsTest
    static void shouldNormalizeDocumentName_WhenItemsArePresent() {
        String rawJson = '{"items":[{"documentName":"AI Doc Review - Identity","status":"ACCEPTABLE"}]}';

        String normalized = AIDocReviewJsonUtil.normalizeDocumentName(rawJson, 'Passport');

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(normalized);
        List<Object> items = (List<Object>) parsed.get('items');
        Map<String, Object> firstItem = (Map<String, Object>) items[0];
        Assert.areEqual('Passport', firstItem.get('documentName'), 'document name should use category label');
    }

    @IsTest
    static void shouldNormalizeDocumentName_WhenPayloadIsFenced() {
        String rawJson = '```json\n{"items":[{"documentName":"AI Doc Review - Tax Return"}]}\n```';

        String normalized = AIDocReviewJsonUtil.normalizeDocumentName(rawJson, 'Business Tax Return');

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(normalized);
        List<Object> items = (List<Object>) parsed.get('items');
        Map<String, Object> firstItem = (Map<String, Object>) items[0];
        Assert.areEqual('Business Tax Return', firstItem.get('documentName'), 'fenced JSON should be parsed');
    }

    @IsTest
    static void shouldReturnOriginalPayload_WhenNormalizeCannotParse() {
        String rawJson = 'not-json';

        String normalized = AIDocReviewJsonUtil.normalizeDocumentName(rawJson, 'Passport');

        Assert.areEqual(rawJson, normalized, 'invalid prompt payload should be preserved');
    }

    @IsTest
    static void shouldMergeJsonItems_WhenPayloadsAreMixed() {
        List<String> payloads = new List<String>{
            '{"items":[{"documentName":"Passport","status":"ACCEPTABLE"}]}',
            '',
            'not-json',
            '```json\n{"items":[{"documentName":"Bank Statement","status":"UNACCEPTABLE"}]}\n```'
        };

        String merged = AIDocReviewJsonUtil.mergeJsonItems(payloads);

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(merged);
        List<Object> items = (List<Object>) parsed.get('items');
        Assert.areEqual(3, items.size(), 'valid items plus fallback invalid item should be merged');
    }

    @IsTest
    static void shouldReturnEmptyItems_WhenMergeInputIsEmpty() {
        String merged = AIDocReviewJsonUtil.mergeJsonItems(new List<String>());

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(merged);
        List<Object> items = (List<Object>) parsed.get('items');
        Assert.areEqual(0, items.size(), 'empty input should produce empty items array');
    }
}

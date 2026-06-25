# Eliminate two workarounds in the AI Document Review pipeline

> Status: **research / proposal**. Not implemented. Take this doc to other tools to validate the approach before any code changes.

---

## Context

Two workarounds were introduced because Salesforce limitations made the natural design impossible at the time:

1. **Pipe-encoded loop**: Flow Builder couldn't resolve fields on Apex-Defined inner classes when iterating them in a loop, so `AIDocFilledFiles` returns `List<List<String>>` of `"<ContentDocumentId>|<categoryName>"` strings, and a second invocable (`AIDocSplitFileRow`) is called inside the loop to break each pipe-encoded string back into two primitive variables.
2. **Apex vs Flow prompt split**: `ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate()` only accepts `ConnectApi.WrappedValue` with String values — SObject references (needed for file grounding) are rejected. So the Coverage and Email prompts run from Apex via `ConnectApi`, but the file-grounded Classify and Sanity prompts had to be moved into the `AIDocVerifyOneFile` subflow using the `generatePromptResponse` Flow action type.

Both workarounds add code that future maintainers must understand. Workaround #1 introduces a second Apex action, a fragile delimiter contract, and a "Split_Row" step inside a hot loop. Workaround #2 splits prompt-invocation error handling across two code paths.

**Goal:** remove both workarounds and converge on a single clean pattern, end-to-end.

---

## Current state — exact code traces

### Workaround #1 — pipe-encoded loop

- `force-app/main/default/classes/AIDocFilledFiles.cls`
  - `@InvocableMethod` returns `List<List<String>>`
  - Line ~94: `rows.add(String.valueOf(docId) + DELIMITER + c.clcommon__Category_Name__c);` — encodes each row as `"<ContentDocumentId>|<categoryName>"`
- `force-app/main/default/classes/AIDocSplitFileRow.cls`
  - `@InvocableMethod` takes pipe-encoded string via `Request.encodedRow`
  - Splits on `DELIMITER` and returns `Response` with separate `fileContentDocumentId` + `categoryName` fields
- `force-app/main/default/flows/AIDocCoverageReview.flow-meta.xml`
  - Loop iterates `Get_Filled_Files` (the `List<String>`)
  - Inside the loop: `Split_Row` action takes `{!Loop_Files}` as `encodedRow`
  - Downstream consumes `{!Split_Row.fileContentDocumentId}` and `{!Split_Row.categoryName}`

### Workaround #2 — ConnectApi vs Flow prompt split

- `force-app/main/default/classes/AIDocCoverageCheck.cls` (lines 112–146) calls `ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate('AIDocCoverageReport', input)` with only String inputs wrapped as `ConnectApi.WrappedValue`.
- `force-app/main/default/classes/AIDocWriteEmailTemplate.cls` (lines 59–104) follows the identical pattern for `AIDocBorrowerEmail` with four String inputs.
- `force-app/main/default/flows/AIDocVerifyOneFile.flow-meta.xml` is a subflow whose actions use `<actionType>generatePromptResponse</actionType>` for `AIDocClassifyFile` and `AIDocSanityCheck` because those prompts require `Input:File` of type `SOBJECT://ContentDocument` (file grounding). The flow looks up the `ContentDocument` via a record query and passes the SObject reference directly to the prompt action.
- The main flow `AIDocCoverageReview` calls this subflow once per file (the loop in workaround #1).

---

## Proposed solution

### Workaround #1 — replace pipe-encoding with a proper Apex-Defined wrapper

Flow Builder's variable-picker limitation only applies to certain shapes of Apex-Defined inner classes. The reliable pattern is:

- Make `AIDocFilledFiles` return an outer per-request `List<Response>` (required by `@InvocableMethod`), where each `Response` contains `@InvocableVariable List<FilledFile> files`.
- `FilledFile` is an inner class with two `@InvocableVariable public String` fields: `fileContentDocumentId` and `categoryName`. Primitives (not nested classes), which Flow Builder's loop picker handles cleanly.
- In the flow: change `Loop_Files`'s collection reference to `Get_Filled_Files.files`. Reference loop fields as `{!Loop_Files.fileContentDocumentId}` / `{!Loop_Files.categoryName}` directly.
- Delete `AIDocSplitFileRow.cls` (and its test). Delete the `Split_Row` action from the flow. Reroute `Loop_Files` → `Call_Verify_Subflow` (or its replacement).
- Remove `AIDocSplitFileRow` from `permissionsets/AIDocAccess.permissionset-meta.xml`.

**Fallback if Flow Builder still can't read the fields**: mark `FilledFile`'s fields `@AuraEnabled` instead of `@InvocableVariable`. Some Salesforce builds resolved this issue this way. Test in a sandbox before declaring done.

### Workaround #2 — unify all prompt calls into Apex using `Prompt.Template` API

Salesforce shipped the `Prompt.Template` Apex API (Spring '25, API 63+) specifically to overcome `ConnectApi.EinsteinLLM`'s String-only input limit. `Prompt.Template.invoke()` accepts SObject references natively for grounding inputs.

**API shape (verify exact namespace/class names against current docs):**
```apex
Prompt.PromptTemplate template = Prompt.PromptTemplate.get('AIDocSanityCheck');
Prompt.Template.PromptInputBuilder inputs = new Prompt.Template.PromptInputBuilder()
    .withInput('File', contentDocumentRecord)       // SObject reference — works
    .withInput('categoryName', categoryName)        // String
    .withInput('borrowerName', borrowerName);       // String
Prompt.PromptResponse response = template.invoke(inputs.build());
String text = response.getResponse();
```

Plan:
- Add new Apex class `AIDocPerFileReview` (single invocable) — takes `fileContentDocumentId`, `categoryName`, `borrowerName` and calls both Classify and Sanity prompts in sequence via `Prompt.Template.invoke()`. Returns `verdictLine` + `sanityLine` (same shape as the current subflow output).
- Bump the `apiVersion` of `AIDocPerFileReview.cls-meta.xml` to **`63.0`** (minimum required for `Prompt.Template`). Other classes stay at v66.0 — `ConnectApi` still works fine for the Coverage and Email prompts. (Consistency migration of those two is optional, not required.)
- Look up the `ContentDocument` record by Id inside the Apex method, pass the SObject directly to `withInput('File', record)`.
- Replace the `Call_Verify_Subflow` action in `AIDocCoverageReview` with a direct Apex call to `AIDocPerFileReview`. The existing `Append_Verdict` assignment block continues to work unchanged because the outputs preserve the same names: `verdictLine`, `sanityLine`.
- Delete `flows/AIDocVerifyOneFile.flow-meta.xml`.
- Add `AIDocPerFileReview` to `permissionsets/AIDocAccess.permissionset-meta.xml`.

---

## Open questions to validate with other tools

1. **`Prompt.Template` namespace/class names** — the snippet above is from Salesforce's stated direction but the exact API names (`Prompt.PromptTemplate`, `Prompt.PromptInputBuilder`, `withInput()`, `invoke()`, `getResponse()`) should be confirmed against current Salesforce docs and the target org's Einstein license tier. Some orgs only have `ConnectApi.EinsteinLLM` enabled.
2. **Flow loop picker on Apex-Defined types** — whether the picker bug still exists in the current Salesforce release. Test with a minimal repro before committing to the rewrite.
3. **`@AuraEnabled` vs `@InvocableVariable` fallback** — if the picker still fails on `@InvocableVariable`, does adding `@AuraEnabled` fix it without breaking the invocable contract?
4. **Mocking `Prompt.Template.invoke()`** — there's no `Test.setMock` for Einstein prompt invocations. The pattern from `AIDocCoverageCheck.invokePromptTemplate()` (line ~113) is to wrap the call in a `@TestVisible private static` method that short-circuits with `if (Test.isRunningTest()) { return 'TEST_PROMPT_RESPONSE: ...'; }`. Confirm this pattern still works for the new API.

---

## Files to modify (when this is implemented)

### Add
- `force-app/main/default/classes/AIDocPerFileReview.cls` + `-meta.xml`
- `force-app/main/default/classes/AIDocPerFileReviewTest.cls` + `-meta.xml`

### Modify
- `force-app/main/default/classes/AIDocFilledFiles.cls` — return shape `List<List<String>>` → `List<Response>` with `List<FilledFile>`
- `force-app/main/default/classes/AIDocFilledFilesTest.cls` — assertions for new shape
- `force-app/main/default/flows/AIDocCoverageReview.flow-meta.xml` — drop `Split_Row`, change loop collection reference, replace subflow call with Apex action call
- `force-app/main/default/permissionsets/AIDocAccess.permissionset-meta.xml` — remove `AIDocSplitFileRow`, add `AIDocPerFileReview`

### Delete
- `force-app/main/default/classes/AIDocSplitFileRow.cls` + `-meta.xml`
- `force-app/main/default/classes/AIDocSplitFileRowTest.cls` + `-meta.xml`
- `force-app/main/default/flows/AIDocVerifyOneFile.flow-meta.xml`

### Org cleanup (manual, after deploy)
- Delete `AIDocSplitFileRow` Apex class
- Delete `AIDocSplitFileRowTest` Apex class
- Delete `AIDocVerifyOneFile` flow

---

## Critical existing files to reuse

- `classes/AIDocCoverageCheck.cls` lines 112–146 — exact `ConnectApi` pattern for reference (Coverage prompt, String-only).
- `classes/AIDocWriteEmailTemplate.cls` lines 59–104 — second `ConnectApi` example (four String inputs).
- `classes/AIDocMergeJsonItems.cls` — merges the per-file `verdictLine` / `sanityLine` strings into a single JSON array. Stays as-is. The `AIDocPerFileReview` outputs must keep the same field names so this consumer is unaffected.
- `flows/AIDocVerifyOneFile.flow-meta.xml` lines 3–61 — the current `generatePromptResponse` actions. The prompt input names (`Input:File`, `Input:categoryName`, `Input:borrowerName`) and the output binding (`promptResponse`) must be preserved when migrating to the Apex equivalent.

---

## Verification (when implemented)

### Unit
- Run `AIDocFilledFilesTest` after the return-shape refactor — assertions move from inspecting pipe-encoded strings to inspecting `FilledFile.fileContentDocumentId` / `.categoryName`.
- Run new `AIDocPerFileReviewTest` — `Prompt.Template.invoke()` is not directly mockable; wrap the call in a `@TestVisible private static` method (same pattern as `AIDocCoverageCheck.invokePromptTemplate()`, which short-circuits with `if (Test.isRunningTest()) { return 'TEST_PROMPT_RESPONSE: ...'; }`). The test verifies orchestration — both Classify and Sanity prompts are invoked with the right inputs, and the right output lines are returned.
- All other test classes (`AIDocCoverageCheckTest`, `AIDocGetBorrowerNameTest`, `AIDocWriteEmailTemplateTest`) should pass unchanged.

### Integration (manual in org)
- Open the John Morris Application record (`a9ka5000000AIrhAAG`).
- Run the AI Document Review quick action.
- Verify the dashboard renders with the same 3 coverage tiles, classification chips, and sanity finding rows as before.
- Confirm:
  - The Sanity prompt still receives the borrower name (was wired through the subflow).
  - The Classify prompt still returns its category-match verdicts.
  - Execution time per file is comparable (one Apex callout vs two Flow prompt actions).

### Rollback
- The two changes are independent and can be reverted independently.
- If `Prompt.Template` doesn't behave as documented in this org (unlikely but possible if the org's Einstein license doesn't enable the Apex API), revert workaround #2 by re-creating `AIDocVerifyOneFile.flow-meta.xml` and re-wiring `AIDocCoverageReview` to call it as a subflow. The loop simplification (workaround #1) is unaffected.

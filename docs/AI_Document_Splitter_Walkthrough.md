# AI Document Splitter — End-to-End Walkthrough

This document explains the AI Document Splitter the way you'd explain it to a teammate at a whiteboard. It covers what happens when a user clicks the button, why each piece exists, and what every Apex class / LWC / record acts as the entry and exit for.

If you only read one thing, read **Section 2 — The Big Picture**.

---

## 1. What the feature does (in plain English)

A borrower or loan officer uploads a single multi-page PDF "bundle" to Salesforce Files. The bundle contains many different documents stitched together — a driver's license, a W-2, three bank statements, an articles of incorporation, etc. The pages may be **in any order** — a document's pages can be scattered through the bundle.

Today this bundle is useless for downstream automation because Salesforce sees it as one big file. The AI Document Splitter:

1. Sends the bundle to a Claude Sonnet 4.6 vision prompt (inside the Einstein Trust Layer).
2. The model groups the pages into distinct document instances. A driver's license front on page 1 and back on page 10 becomes **one** entry. Two different bank statements interleaved become **two** entries with distinguishing labels.
3. Pulls the named party (e.g. "John Smith", "Vance Electric LLC") and (for bank statements) the issuing institution off each document.
4. Cuts the bundle into one new PDF per detected document instance — copying exactly the pages the model claimed, in their natural reading order.
5. Names each new file by type + party (`BankStatement_Chase_John_Smith.pdf`).
6. Drops each new file into the **same folder** as the source bundle.
7. If the source bundle turned out to be a single confidently-typed document (e.g. a borrower uploaded just a bank statement), the source is auto-deleted because the well-named output replaces it.

End-to-end takes about 20–40 seconds for a typical 14-page bundle, mostly waiting on the AI.

---

## 2. The big picture

```
   USER                       BROWSER (LWC)                      SALESFORCE PLATFORM
   ----                       -------------                      -------------------

   Click "Split Documents"
   ┌──────────────────────────────────────┐
   │     aiDocumentSplitterStudio LWC      │
   │   - reads source PDF bytes via Apex   │
   │   - uses pdf-lib to count pages       │
   │   - decides: SINGLE-CALL or CHUNKED?  │
   │       size <= 12 MB → single call     │
   │       size  > 12 MB → chunk via       │
   │                       pdf-lib         │
   │   - asks Apex to start a job          │
   └──────────────────┬───────────────────┘
                      │
                      ▼
   ┌──────────────────────────────────────────────────────────────────────────────┐
   │ SplitJobController.startJob()                                                 │
   │   creates Split_Job__c (Status=Queued)                                        │
   │   returns jobId to the LWC                                                    │
   └──────────────────────┬────────────────────────────────────────────────────────┘
                          │
   ┌──────────────────────┴────────────────────────────────────────────────────────┐
   │ SplitJobController.enqueueChunkClassification()                              │
   │   single-call path → 1 ClassifyQueueable, source ContentDocumentId as input  │
   │   chunked path     → N ClassifyQueueables, one per chunk                     │
   └──────────────────────┬────────────────────────────────────────────────────────┘
                          │
                          ▼ (each runs in its own Apex transaction)
   ┌─────────────────────────────────────────────────────────────────────────────┐
   │ ClassifyQueueable.execute()                                                  │
   │   1. invokes the AIDocSplitClassifySpike Flow                                │
   │      ↳ Flow calls the AIDocSplitClassify v4 vision prompt                    │
   │      ↳ Prompt reads the PDF, returns JSON entries with a "pages" array       │
   │   2. parses the JSON, shifts page numbers to absolute (chunked path only)    │
   │   3. appends entries to Split_Job__c.Raw_Segments_JSON__c (row-locked)       │
   │   4. increments Chunks_Completed__c                                          │
   │   5. if I'm the LAST chunk → run SegmentMerger and publish "Splitting"       │
   └──────────────────────┬───────────────────────────────────────────────────────┘
                          │
                          ▼
   ┌─────────────────────────────────────────────────────────────────────────────┐
   │ SegmentMerger.mergeSegments()  (pure logic, no DML)                          │
   │   sanitize: drop blank-type, out-of-bounds, malformed entries                │
   │   de-dupe: if two entries claim the same page, first claimant wins           │
   │   gap-fill: every unclaimed page goes into one synthetic OTHER entry         │
   └──────────────────────┬───────────────────────────────────────────────────────┘
                          │
                          ▼ (Platform Event published)
   ┌─────────────────────────────────────────────────────────────────────────────┐
   │ Split_Job_Update__e   Status=Splitting   payload=merged segments JSON        │
   └──────────────────────┬───────────────────────────────────────────────────────┘
                          │
                          ▼ (LWC subscribed via empApi, filtered by jobId)
   ┌─────────────────────────────────────────────────────────────────────────────┐
   │ aiDocumentSplitterStudio.splitAndSave()                                       │
   │   1. uses pdf-lib in the browser: copyPages(sourceDoc, segment.pages-1)      │
   │      (works for arbitrary index arrays — non-contiguous pages are fine)      │
   │   2. builds filenames like BankStatement_Chase_John_Smith.pdf                │
   │   3. base64-encodes each output PDF                                          │
   │   4. calls SplitJobController.startSaving()                                  │
   └──────────────────────┬───────────────────────────────────────────────────────┘
                          │
                          ▼
   ┌─────────────────────────────────────────────────────────────────────────────┐
   │ SplitSaveQueueable.execute()  (chained: 8 files per batch)                   │
   │   1. inserts ContentVersion records with FirstPublishLocationId = library    │
   │   2. inserts explicit ContentDocumentLink records (library + job)            │
   │   3. updates the auto-created ContentFolderMember to point at target folder  │
   │   4. publishes "Saving" progress event with running Documents_Created count  │
   │   5. when remaining list empty → calls finalizeJob, which:                   │
   │      - sets Status=Complete, writes Type_Breakdown_JSON__c                   │
   │      - cleans up temp chunk PDFs (only on the chunked path)                  │
   │      - auto-deletes source if it was a single full-coverage non-OTHER doc    │
   │      - publishes Complete event with documentsCreated populated              │
   └──────────────────────┬───────────────────────────────────────────────────────┘
                          │
                          ▼ (LWC receives Complete event)
   ┌─────────────────────────────────────────────────────────────────────────────┐
   │ User sees: split files in a results table, sorted by type + party,           │
   │ each clickable to preview, with Delete Selected / Delete All buttons         │
   │ (busy-state guard + spinner overlay while a delete is in flight)             │
   └─────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Why we built it this way (key constraints)

### Why does pdf-lib run in the browser, not in Apex?

- **No native Apex PDF library**: Apex cannot extract page ranges or copy pages from an existing PDF. Spring '26 added `Blob.toPdf()` for *generation* from HTML, but no `Blob.splitPdf()` for slicing. pdf-lib is a JavaScript library that runs in the user's authenticated browser session, processes bytes locally, and never makes external network calls. It loads from a static resource (~525 KB) — no third-party endpoints, no data egress, stays inside the customer's Salesforce session.
- **Apex heap limit doesn't bind us when pdf-lib runs in the browser**. The 12 MB async heap would have been the constraint for a server-side implementation; sidestepping it client-side is precisely why we use pdf-lib.

### Why a size threshold (12 MB) for single-call vs chunked?

- **Salesforce Prompt Builder caps total file input at 15 MB**, regardless of the underlying model's native capability (Sonnet 4.6's native ceiling is 32 MB, but Salesforce's wrapper enforces 15 MB).
- 12 MB threshold leaves a 3 MB buffer for the prompt envelope, JSON instructions, and system message overhead.
- For typical loan packets (5–10 MB), the single-call path runs: one LLM call, no chunking, no cross-chunk reconciliation, faster wall-clock.
- For thicker bundles (40-page high-res scans frequently land at 15–25 MB), the chunked path kicks in: pdf-lib slices into ~8-page chunks with 2 pages of overlap, each chunk classifies in parallel, `SegmentMerger` de-dupes overlapping claims.

### Why page lists instead of page ranges?

A document's pages can be scattered through the bundle — driver's license front on page 1, back on page 10. The range model (`startPage`/`endPage`) can't represent that and forced the prompt into a "must be contiguous, no gaps, no overlaps" contract that didn't reflect reality.

Switching to a `pages: [array]` model:
- The prompt asks for one entry per distinct document instance with all its pages listed (any order in the bundle, natural reading order within the entry).
- pdf-lib's `copyPages(sourceDoc, indices)` accepts any index array — non-contiguous works for free.
- `SegmentMerger` becomes a simple coverage validator rather than a chunk-seam healer.
- Multiple instances of the same type (two different bank statements) are explicit, distinguished by `instance_label` and/or `source_institution`.

### Why Platform Events instead of polling?

- The LWC needs to know when classification finishes, when each save batch lands, and when the job is complete.
- Polling Apex every 2 seconds would burn governor limits and feel sluggish.
- `Split_Job_Update__e` publishes at every status transition. The LWC subscribes via `lightning/empApi` and gets events pushed in real time.
- Events carry `Documents_Created__c` and `Summary_JSON__c` payloads so the LWC reads progress directly from the event without an extra round-trip.
- **Cross-tab guard**: `pdfUtil.decodeJobEvent` requires the receiving LWC to have a matching `jobId`. Idle tabs and tabs that haven't started a job ignore events from other jobs.

### Why a separate Apex Queueable for the save step?

- The save phase has its own batching and chaining concerns (8 `ContentVersion` inserts per batch, then chain to the next batch).
- Mixing it into `ClassifyQueueable` would entangle two different async patterns.

### Why does the source bundle sometimes get auto-deleted?

If the AI returns exactly one segment of a known (non-OTHER) type that covers every page in the source, the new well-named output is essentially a renamed duplicate of the source. We delete the source in this narrow case so the library doesn't accumulate redundancy. The `OTHER`-segment guard means any uncertainty preserves the source.

---

## 4. Entry and exit points — stage by stage

The pipeline is six stages. Each stage has a clear entry trigger and an exit signal that hands off to the next stage.

### Stage 1 — User selects a source file

| | |
|---|---|
| **Entry** | User clicks `aiDocumentSplitterStudio` LWC, picks a PDF from the search list OR drag-and-drops a new file |
| **What happens** | LWC stores `selectedFile = {id, title, sizeLabel}` |
| **Exit** | User clicks "Split Documents" → triggers Stage 2 |

### Stage 2 — Browser branches single-call vs chunked

| | |
|---|---|
| **Entry** | `aiDocumentSplitterStudio.runSplitPipeline()` |
| **Input** | `selectedFile.id` (ContentDocument Id, `069...`) |
| **What happens** | • Apex returns the source PDF as base64 (`getFileContentBase64`)<br>• `pdf-lib` loads the bytes, reports total page count<br>• Branch: `sourcePdfBytes.length <= 12 MB` → single-call path; else chunked path<br>• Single-call: no PDF surgery needed; source is its own "chunk 0" with `pageOffset = 1`<br>• Chunked: `pdfUtil.computeChunks(totalPages, 8, 2)` returns overlapping page ranges; browser builds one sub-PDF per chunk; each chunk PDF uploaded back to Salesforce as a temporary ContentDocument (titled `bundle_chunk_N.pdf`) |
| **Output** | Job created with `chunkCount` = 1 (single-call) or N (chunked) |
| **Exit** | LWC calls `SplitJobController.startJob` → triggers Stage 3 |

### Stage 3 — Apex creates the job record

| | |
|---|---|
| **Entry** | `SplitJobController.startJob(sourceContentDocumentId, libraryId, folderId, totalPages, chunkCount)` |
| **What happens** | Delegates to `SplitJobService.startJob` which inserts a new `Split_Job__c` record with `Status='Queued'` |
| **Output** | `jobId` returned to LWC |
| **Exit** | LWC fires `enqueueChunkClassification` call(s) → triggers Stage 4 |

### Stage 4 — Async AI classification

| | |
|---|---|
| **Entry** | `SplitJobController.enqueueChunkClassification(jobId, chunkIndex, chunkContentDocumentId, pageOffset)` enqueues one `ClassifyQueueable` |
| **Runs in** | Async Apex (one job per chunk if chunked; just one job total if single-call) |
| **What happens per chunk** | 1. Invokes the `AIDocSplitClassifySpike` Flow with the ContentDocument Id<br>2. Flow runs the `AIDocSplitClassify` v4 vision prompt (bound model: `sfdc_ai__DefaultBedrockAnthropicClaude46Sonnet`)<br>3. Prompt returns JSON: `[{document_type, source_institution, named_party, instance_label, pages: [...]}, ...]`<br>4. Apex parses JSON; for chunked path, shifts page numbers by `(pageOffset - 1)` to make them absolute. Single-call path: pageOffset=1, no shift.<br>5. Appends entries to `Split_Job__c.Raw_Segments_JSON__c` under a row lock<br>6. Increments `Chunks_Completed__c`<br>7. If this is the last chunk, calls `SplitJobService.runMergeAndPrepareForSplit` |
| **Why the row lock** | If multiple ClassifyQueueables finish at the same time (chunked path), the lock serializes the "am I the last chunk?" check so we only trigger the merge once. |
| **Exit** | Last chunk publishes `Split_Job_Update__e` with `Status='Splitting'` and the merged JSON in `Summary_JSON__c` → triggers Stage 5 |

### Stage 5 — Browser splits the actual PDF

| | |
|---|---|
| **Entry** | LWC's empApi subscriber receives `Status='Splitting'` event (filtered by jobId) |
| **Input** | Merged segments JSON: list of `{documentType, sourceInstitution, namedParty, instanceLabel, pages: [...]}` entries; collectively claim every page in `[1..totalPages]` exactly once. |
| **What happens** | 1. `pdfUtil.segmentsToSaveRequests` builds filenames (type + party + index) and copies the page list through<br>2. For each segment: `pdf-lib` calls `subDoc.copyPages(sourceDoc, req.pages.map(p => p - 1))` — handles non-contiguous indices natively<br>3. Each new PDF is base64-encoded<br>4. LWC calls `SplitJobController.startSaving(jobId, requestsJson, batchSize)` |
| **Exit** | Apex enqueues the first `SplitSaveQueueable` → triggers Stage 6 |

### Stage 6 — Async save back to the library

| | |
|---|---|
| **Entry** | `SplitSaveQueueable.execute()` |
| **Runs in** | Async Apex; chains itself with the remaining list when a batch finishes |
| **What happens per batch** | 1. Insert `ContentVersion` records (8 per batch). `FirstPublishLocationId = libraryId`<br>2. Explicitly insert `ContentDocumentLink` records — one linking each new file to the library, one linking to the `Split_Job__c` (for traceable querying)<br>3. If `Target_Folder_Id__c` is set, **update** the auto-created `ContentFolderMember` (created by `FirstPublishLocationId`) to point at the target folder — inserting a duplicate would fail on the uniqueness constraint<br>4. Increment `Documents_Created__c`, tally types into `typeCountsSoFar`<br>5. Publish `Saving` progress event with the running count<br>6. If more remaining → chain another `SplitSaveQueueable`<br>7. If last batch → call `SplitJobService.finalizeJob` |
| **Finalize step** | Sets `Status='Complete'`, writes `Type_Breakdown_JSON__c`, cleans up temp chunk files (only the chunked path created them), evaluates `shouldReplaceSource` and deletes the source bundle if the output is a 1:1 replacement, publishes Complete event with `Documents_Created__c` populated |
| **Exit** | LWC receives Complete event, calls `getJobOutputFiles` (which queries `ContentDocumentLink WHERE LinkedEntityId = jobId`), renders the results table |

---

## 5. File-by-file reference

### LWC components

| Bundle | Purpose | Where it shows up |
|---|---|---|
| `aiDocumentSplitterStudio` | Standalone splitter UI: file picker + upload + progress + results table + delete actions (busy-state guard + spinner overlay) | App Page tab created in Lightning App Builder |
| `documentSplitter` | The same flow but on a ContentDocument record page | Drop on a ContentDocument Lightning Record Page |
| `pdfUtil` | Shared JS module, no UI. Exports `computeChunks`, `buildFileName`, `segmentsToSaveRequests`, `uint8ToBase64`, `base64ToUint8`, `decodeJobEvent` | Imported by the two LWCs above |
| `pdfLib` (static resource) | 525 KB bundled copy of pdf-lib 1.17.1 | Loaded once per page session via `lightning/platformResourceLoader` |

### Apex classes

| Class | Sharing | Purpose |
|---|---|---|
| `SplitJobController` | `with sharing` | Thin `@AuraEnabled` wrapper. Every LWC → Apex call lands here. `getJobOutputFiles(null)` returns `[]` rather than throwing to keep the Apex debug log clean for stale clients. |
| `SplitJobService` | `with sharing` | Orchestrator. Owns the lifecycle: `startJob`, `enqueueChunkClassification`, `recordChunkCompletion`, `runMergeAndPrepareForSplit`, `startSaving`, `markSaving`, `recordSaveProgress`, `finalizeJob`, `failJob`, `cleanupTempChunkFiles`, `shouldReplaceSource`, `deleteSourceIfReplacedByOneFile` |
| `ClassifyQueueable` | `with sharing`, `Queueable`, `Database.AllowsCallouts` | Per-chunk (or whole-file) AI classification. Invokes the AIDocSplitClassifySpike Flow. Parses `pages` arrays and shifts page numbers by `pageOffset - 1`. |
| `SplitSaveQueueable` | `with sharing`, `Queueable` | Batched save of split PDFs back to the library + folder. Chains itself. |
| `SegmentMerger` | `public` (no DML) | Pure logic coverage validator. Sanitizes inputs, de-duplicates page claims (first claimant wins), lumps unclaimed pages into one OTHER segment. |
| `DocSegment` | DTO | One detected document instance: `documentType`, `sourceInstitution`, `namedParty`, `instanceLabel`, `pages: List<Integer>` |
| `SplitSaveRequest` | DTO | One save: `fileName`, `base64Content`, `documentType`, `sourceInstitution`, `namedParty`, `instanceLabel`, `pages` |
| `SplitJobException` | exception | Custom exception for input validation failures |

### Data model

| Object / event | Purpose |
|---|---|
| `Document_Type__mdt` | Custom Metadata Type — 20 active records describing the document types the AI knows about. Type Code (BANK_STATEMENT, DRIVERS_LICENSE...), Classification Hints, Sort Order, Is Fallback. |
| `Split_Job__c` | Audit record for one split run. Status pipeline: Queued → Detecting → Merging → Splitting → Saving → Complete (or Error). Holds raw + merged segments JSON, page count, chunk count, completed counter, target folder Id, type breakdown JSON. |
| `Split_Job_Update__e` | Platform Event. Fired at every status transition. Payload: Job Id, Status, Documents Created, Summary JSON, Message. The LWC subscribes via empApi. |
| `AIDocSplitClassify` (prompt template) | Vision-capable Prompt Builder template. Active version v4 with the page-list output contract, bound to Claude Sonnet 4.6 on Amazon. Takes `Input:File` (a ContentDocument) and returns the JSON segment array. |
| `AIDocSplitClassifySpike` | Subflow that wraps the prompt invocation so Apex can call it via `Flow.Interview` API. |

---

## 6. Lifecycle of a Split_Job__c

Status transitions are the contract between async stages. Here's the full state machine.

```
   Queued     (created by startJob, before any classify)
     │
     ▼  ──── first enqueueChunkClassification call
   Detecting  (one or more chunks classifying — usually just one in single-call path)
     │
     ▼  ──── last chunk completes classification
   Merging    (SegmentMerger runs — fast, no async wait)
     │
     ▼  ──── merge done
   Splitting  (LWC notified, browser is now cutting the PDF)
     │
     ▼  ──── LWC calls startSaving
   Saving     (SplitSaveQueueable chain in progress)
     │
     ▼  ──── last save batch finishes
   Complete

   ─── at ANY point, on exception ───
   Error      (Error_Detail__c populated, Complete event fires)
```

---

## 7. How to verify everything is working

A clean end-to-end test against a typical 14-page mixed bundle should produce:

- **N new ContentDocuments** in the same folder as the source (one per detected document instance, where N matches what the model actually found — usually 5–10 for a realistic loan packet)
- **Filenames matching pattern** `TypeLabel[_Source]_[PartyName].pdf` (with `_2`, `_3` suffix if more than one of the same type+source+party combination)
- **OTHER files numbered**: `Other_1.pdf`, `Other_2.pdf` — party/source name stripped because the AI's extraction on unrecognized pages is unreliable
- **Zero `bundle_chunk_*.pdf` leftovers** if the chunked path ran (only the chunked path creates them; the single-call path doesn't)
- **Source bundle untouched** in the multi-doc case; **source auto-deleted** in the single-confidently-typed-doc case (e.g. uploaded just a bank statement)
- **`Split_Job__c.Status__c = Complete`** with a populated `Type_Breakdown_JSON__c` like `[{"type":"BANK_STATEMENT","count":2},{"type":"DRIVERS_LICENSE","count":1},...]`
- **`Documents_Created__c`** matches the actual output file count
- **`Split_Job_Update__e` event stream** ends with a Complete event whose payload's `Documents_Created__c` matches the file count (and the success toast reads the right number)

For the unsorted-bundle case (license front + back on non-adjacent pages, two interleaved bank statements), expect:
- One DriversLicense_*.pdf containing the two scattered pages in natural reading order (front then back)
- Two BankStatement_*.pdf files distinguished by `source_institution` in the filename
- All unrecognized pages combined into a single `Other_1.pdf` (not split per gap)

---

## 8. Known limits and trade-offs

| Limit | Where it hits | What to do if you need more |
|---|---|---|
| **Salesforce Prompt Builder file input cap (15 MB)** | The single-call path. Threshold set at 12 MB to leave envelope buffer. | Chunked path takes over above 12 MB. For the >15 MB case it's already mitigated. |
| **Claude Sonnet 4.6 native cap (32 MB)** | Not the binding constraint here — Salesforce wrapper enforces 15 MB regardless. | If Salesforce raises the wrapper limit, raise the 12 MB threshold accordingly. |
| Apex async heap (12 MB) | Source PDF download for the LWC. Practical cap ~8 MB raw. Doesn't constrain pdf-lib (which runs in the browser). | For larger source files, switch to streaming via REST API + CSP Trusted Site. |
| Apex inbound payload (~5 MB) | Chunk PDFs uploaded via `@AuraEnabled` base64. Each chunk usually < 500 KB. | Larger chunks → multi-part REST upload. |
| 50 enqueued Queueables per transaction | Affects bundles > 400 pages at 8 pages/chunk. | Throttle via a coordinator queue. |
| 32 KB on `Raw_Segments_JSON__c` accumulator | At ~5 KB/chunk, ~6 chunks safely. Single-call path uses one allocation. | Promote to a child `Chunk_Result__c` object if chunked paths exceed budget. |
| `lightning/empApi` requires open browser tab | User closing the tab mid-split misses live events. | The `Split_Job__c` record persists state; re-opening the studio refetches. |

---

## 9. Why the two LWCs exist

- **`documentSplitter`** — the original record-page LWC. Drop it on a ContentDocument record page; runs against `recordId` (the file you're viewing).
- **`aiDocumentSplitterStudio`** — the standalone "tool" LWC. Lives on an App Page; user picks any file from search or uploads a new one.

Both go through the same Apex pipeline. The studio is the better UX for general use; the record-page version is handy if you want the splitter button to appear inline on every file. Both implement the same single-call vs chunked branching at 12 MB.

---

## 10. Where to look when something goes wrong

| Symptom | Where to start |
|---|---|
| LWC shows "Failed to fetch" / "Could not load file" | Check the user has `AIDocAccess` permset assigned; verify the ContentDocument exists. |
| LWC stuck on "Classifying" forever | Setup → Apex Jobs — look for failed `ClassifyQueueable` runs. Often a prompt activation issue (verify `AIDocSplitClassify` has v4 active in Prompt Builder). |
| Success toast says "Split into 0 files" but files DID save | Event payload missing `Documents_Created__c`. Confirm `SplitJobService.publishUpdate` is passing the count on Saving + Complete events (and check the LWC bundle isn't browser-cached pre-fix — hard refresh). |
| All output is one big OTHER file | Prompt template active version is using the wrong output contract. `AIDocSplitClassify` must have v4 (with `pages` array) active, not v3 (with `start_page`/`end_page`). Check `<activeVersionIdentifier>` in the org. |
| Output count says 10 but only 1 visible in results table | `getJobOutputFiles` querying by `ContentDocumentLink LinkedEntityId=jobId`. If links weren't created, you'll hit this. The current code creates them explicitly in `SplitSaveQueueable.saveBatch`. |
| Files saved at library root instead of source folder | `SplitSaveQueueable` updates the auto-created `ContentFolderMember` rather than inserting a duplicate. If a deploy regressed to INSERT, the uniqueness constraint silently swallows the failure. Check the query result for existing memberships of the new ContentDocumentIds. |
| Temp `bundle_chunk_*.pdf` files piling up | Means the chunked path hit an error before `finalizeJob`. Run `scripts/apex/cleanup_temp_chunks.apex` to sweep. (Single-call path never creates these.) |
| Stale error toasts in tabs that didn't start a job | Pre-fix `pdfUtil.decodeJobEvent` allowed events through when `expectedJobId` was falsy. Verify current `pdfUtil.js` rejects events when `expectedJobId` is empty. |
| pdf-lib "pdf must be of type string/Uint8Array/ArrayBuffer, was undefined" | Stale Splitting event arrived in an LWC instance whose `sourcePdfBytes` wasn't cached. Current code returns silently in this case; if the error reappears, a deploy regressed the defensive guard in `splitAndSave`. |
| Status=Error | Read `Split_Job__c.Error_Detail__c` — format is `[Stage] ExceptionType: message`. |

---

## 11. Architecture notes worth remembering

- **The bytes never leave Salesforce.** pdf-lib runs in the user's authenticated browser session, on hardware the customer already paid for. No external service, no third-party endpoint, no callout, no data egress. The Einstein Trust Layer wraps the LLM call. Stronger compliance posture than any AppExchange splitter (which all proxy bytes to vendor clouds).
- **The LLM does the brain work; pdf-lib does the hands work.** The model identifies which pages belong to which document — it returns metadata, not files. pdf-lib slices the bytes deterministically using that metadata. Asking the LLM to "produce the split files" is a category error; LLMs don't emit binary PDFs.
- **Page lists, not page ranges.** Documents can be scattered through a bundle. The page-list model lets one driver's-license entry span pages [1, 10], and two distinct bank statements coexist as separate entries with the same `document_type`.
- **`SegmentMerger` is a coverage validator, not a chunk-seam healer.** With the page-list model and the single-call default path, the merger's only jobs are sanitizing bad inputs and lumping orphan pages into OTHER. The old "merge adjacent same-type / split conflicting overlaps at midpoint" logic existed only because chunks emitted overlapping ranges — gone.
- **Salesforce Prompt Builder treats Published templateVersions as immutable.** Editing `<content>` in the XML for an existing published version is silently dropped at deploy. To change a prompt, add a new `<templateVersions>` block (Draft), deploy, then manually create the new version in Prompt Builder UI (the metadata version doesn't surface in the UI's version selector) and activate.

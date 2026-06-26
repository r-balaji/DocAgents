# AI Document Splitter — End-to-End Walkthrough

This document explains the AI Document Splitter the way you'd explain it to a teammate at a whiteboard. It covers what happens when a user clicks the button, why each piece exists, and what every Apex class / LWC / record acts as the entry and exit for.

If you only read one thing, read **Section 2 — The Big Picture**.

---

## 1. What the feature does (in plain English)

A borrower or loan officer uploads a single multi-page PDF "bundle" to Salesforce Files. The bundle contains many different documents stitched together — a driver's license, a W-2, three bank statements, an articles of incorporation, etc.

Today this bundle is useless for downstream automation because Salesforce sees it as one big file. The AI Document Splitter:

1. Looks at the bundle one page at a time using an AI vision prompt
2. Identifies where each document starts and ends, and what type it is
3. Pulls the named party (e.g. "John Smith", "Vance Electric LLC") off each document
4. Cuts the bundle into one new PDF per detected document
5. Names each new file by type + party (`BankStatement_Chase_John_Smith.pdf`)
6. Drops each new file into the *same folder* as the source bundle

The whole thing takes about 30–60 seconds for a 14-page bundle, mostly waiting on the AI.

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
   │   - slices bundle into 8-page chunks  │
   │     (each chunk overlaps by 2 pages)  │
   │   - uploads each chunk back to        │
   │     Salesforce as a temp PDF          │
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
   │ For each chunk: SplitJobController.enqueueChunkClassification()               │
   │   → enqueues ONE ClassifyQueueable per chunk (parallel async)                 │
   └──────────────────────┬────────────────────────────────────────────────────────┘
                          │
                          ▼ (each runs in its own Apex transaction)
   ┌─────────────────────────────────────────────────────────────────────────────┐
   │ ClassifyQueueable.execute()                                                  │
   │   1. invokes the AIDocSplitClassifySpike Flow                                │
   │      ↳ Flow calls the AIDocSplitClassify vision prompt template              │
   │      ↳ Prompt reads the chunk PDF and returns JSON segments                  │
   │   2. parses the JSON, shifts page numbers to absolute                        │
   │   3. appends segments to Split_Job__c.Raw_Segments_JSON__c (row-locked)      │
   │   4. increments Chunks_Completed__c                                          │
   │   5. if I'm the LAST chunk → run SegmentMerger and publish "Splitting"       │
   └──────────────────────┬───────────────────────────────────────────────────────┘
                          │
                          ▼
   ┌─────────────────────────────────────────────────────────────────────────────┐
   │ SegmentMerger.mergeSegments()  (pure logic, no DML)                          │
   │   collapses overlapping chunk results, heals seam-straddling docs            │
   │   splits conflicting overlaps at midpoint, fills gaps with OTHER             │
   │   merges same-type-same-party segments, keeps different parties separate     │
   │   produces final segment list with absolute page numbers                     │
   └──────────────────────┬───────────────────────────────────────────────────────┘
                          │
                          ▼ (Platform Event published)
   ┌─────────────────────────────────────────────────────────────────────────────┐
   │ Split_Job_Update__e   Status=Splitting   payload=merged segments JSON        │
   └──────────────────────┬───────────────────────────────────────────────────────┘
                          │
                          ▼ (LWC subscribed via empApi)
   ┌─────────────────────────────────────────────────────────────────────────────┐
   │ aiDocumentSplitterStudio.splitAndSave()                                       │
   │   1. uses pdf-lib in the browser to extract each segment's page range        │
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
   │   3. inserts ContentFolderMember records if the source lived in a folder     │
   │   4. publishes "Saving" progress event                                       │
   │   5. when remaining list empty → calls finalizeJob, which:                   │
   │      - sets Status=Complete, writes Type_Breakdown_JSON__c                   │
   │      - deletes the temp chunk PDFs (bundle_chunk_*.pdf)                      │
   │      - publishes the Complete event                                          │
   └──────────────────────┬───────────────────────────────────────────────────────┘
                          │
                          ▼ (LWC receives Complete event)
   ┌─────────────────────────────────────────────────────────────────────────────┐
   │ User sees: 10 split files in a results table, sorted by type + party,        │
   │ each clickable to preview, with Delete Selected / Delete All buttons         │
   └─────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Why we built it this way (key constraints)

### Why split into 8-page chunks instead of sending the whole bundle to the AI?

- **Apex heap limit**: A 17 MB bundle would not fit in Apex memory (6 MB sync / 12 MB async). So Apex never touches the binary — `pdf-lib` runs in the browser.
- **AI input limit**: Even if Apex could hold the bundle, vision prompts have a per-call page/file size cap. Chunking keeps every AI call within limits.
- **Parallelism**: Each chunk is its own Queueable, so they run in parallel rather than serially. 14 pages classify in ~10–15 s instead of ~60 s.

### Why does each chunk overlap by 2 pages?

- A real document might span the seam — pages 7–10, with the chunk boundary at page 8.
- If the chunks don't overlap, chunk A sees pages 7–8 of a bank statement and chunk B sees pages 9–10; both might classify them as two separate documents.
- With overlap, both chunks see all of pages 7–10 and report the same boundaries. `SegmentMerger` then collapses the duplicates into one segment. This is the "seam healing" behavior.

### Why is the LWC doing the PDF cutting instead of Apex?

- Same heap-limit reason. `pdf-lib` is a JavaScript library that runs in the browser; it slices PDF bytes natively without going through Apex at all.
- Apex's only PDF interaction is fetching/saving binary blobs via `ContentVersion.VersionData`, which is the platform's native binary channel.

### Why Platform Events instead of polling?

- The LWC needs to know when classification finishes and when each batch saves.
- Polling Apex every 2 s would burn governor limits and feel sluggish.
- `Split_Job_Update__e` is a Platform Event that publishes at every stage transition. The LWC subscribes via `lightning/empApi` and gets events pushed in real time.

### Why a separate Apex Queueable for the save step?

- The "save" phase has its own batching and chaining concerns (8 ContentVersion inserts per batch, then chain).
- Mixing it into ClassifyQueueable would entangle two different async patterns.

---

## 4. Entry and exit points — stage by stage

The pipeline is six stages. Each stage has a clear entry trigger and an exit signal that hands off to the next stage.

### Stage 1 — User selects a source file

| | |
|---|---|
| **Entry** | User clicks `aiDocumentSplitterStudio` LWC, picks a PDF from the search list OR drag-and-drops a new file |
| **What happens** | LWC stores `selectedFile = {id, title, sizeLabel}` |
| **Exit** | User clicks "Split Documents" → triggers Stage 2 |

### Stage 2 — Browser prepares the chunks

| | |
|---|---|
| **Entry** | `aiDocumentSplitterStudio.runSplitPipeline()` |
| **Input** | `selectedFile.id` (ContentDocument Id, `069...`) |
| **What happens** | • Apex returns the source PDF as base64 (`getFileContentBase64`)<br>• `pdf-lib` loads the bytes, reports total page count<br>• `pdfUtil.computeChunks(totalPages, 8, 2)` returns overlapping page ranges<br>• Browser builds one sub-PDF per chunk<br>• Each chunk PDF uploaded back to Salesforce as a temporary ContentDocument (titled `bundle_chunk_N.pdf`) |
| **Output** | List of `{chunkIndex, chunkContentDocumentId, pageOffset, startPage, endPage}` |
| **Exit** | LWC calls `SplitJobController.startJob` → triggers Stage 3 |

### Stage 3 — Apex creates the job record

| | |
|---|---|
| **Entry** | `SplitJobController.startJob(sourceContentDocumentId, libraryId, folderId, totalPages, chunkCount)` |
| **What happens** | Delegates to `SplitJobService.startJob` which inserts a new `Split_Job__c` record with `Status='Queued'` |
| **Output** | `jobId` returned to LWC |
| **Exit** | LWC immediately fires N `enqueueChunkClassification` calls → triggers Stage 4 (N times in parallel) |

### Stage 4 — Async AI classification

| | |
|---|---|
| **Entry** | `SplitJobController.enqueueChunkClassification(jobId, chunkIndex, chunkContentDocumentId, pageOffset)` enqueues one `ClassifyQueueable` |
| **Runs in** | Async Apex (one job per chunk, runs in parallel) |
| **What happens per chunk** | 1. Invokes the `AIDocSplitClassifySpike` Flow with the chunk ContentDocument Id<br>2. Flow runs the `AIDocSplitClassify` vision prompt template<br>3. Prompt returns JSON: `[{document_type, source_institution, named_party, start_page, end_page}, ...]` (page numbers within the chunk)<br>4. Apex parses JSON, shifts page numbers by `pageOffset` to make them absolute<br>5. Appends segments to `Split_Job__c.Raw_Segments_JSON__c` under a row lock<br>6. Increments `Chunks_Completed__c`<br>7. If this is the last chunk, calls `SplitJobService.runMergeAndPrepareForSplit` |
| **Why the row lock** | Multiple ClassifyQueueables can finish at the same time. The lock serializes the "am I the last chunk?" check so we only trigger the merge once. |
| **Exit** | Last chunk publishes `Split_Job_Update__e` with `Status='Splitting'` and the merged JSON in `Summary_JSON__c` → triggers Stage 5 |

### Stage 5 — Browser splits the actual PDF

| | |
|---|---|
| **Entry** | LWC's empApi subscriber receives `Status='Splitting'` event |
| **Input** | Merged segments JSON: list of final, non-overlapping segments |
| **What happens** | 1. `pdfUtil.segmentsToSaveRequests` builds filenames (type + party + index)<br>2. For each segment: `pdf-lib` extracts the page range from the source PDF and saves it as a new PDF blob<br>3. Each new PDF is base64-encoded<br>4. LWC calls `SplitJobController.startSaving(jobId, requestsJson, batchSize)` |
| **Exit** | Apex enqueues the first `SplitSaveQueueable` → triggers Stage 6 |

### Stage 6 — Async save back to the library

| | |
|---|---|
| **Entry** | `SplitSaveQueueable.execute()` |
| **Runs in** | Async Apex; chains itself with the remaining list when a batch finishes |
| **What happens per batch** | 1. Insert `ContentVersion` records (8 per batch). `FirstPublishLocationId = libraryId`<br>2. Explicitly insert `ContentDocumentLink` records — one linking each new file to the library, one linking to the `Split_Job__c` (for traceable querying)<br>3. If `Target_Folder_Id__c` is set, insert `ContentFolderMember` to put each file in the same folder as the source<br>4. Increment `Documents_Created__c`, tally types into `typeCountsSoFar`<br>5. Publish `Saving` progress event<br>6. If more remaining → chain another `SplitSaveQueueable`<br>7. If last batch → call `SplitJobService.finalizeJob` |
| **Finalize step** | Sets `Status='Complete'`, writes `Type_Breakdown_JSON__c`, deletes temp chunk files (`bundle_chunk_*.pdf`), publishes Complete event |
| **Exit** | LWC receives Complete event, fetches output file list via `SplitJobController.getJobOutputFiles`, renders the results table |

---

## 5. File-by-file reference

### LWC components

| Bundle | Purpose | Where it shows up |
|---|---|---|
| `aiDocumentSplitterStudio` | Standalone splitter UI: file picker + upload + progress + results table + delete actions | An App Page tab created in Lightning App Builder |
| `documentSplitter` | The same flow but on a ContentDocument record page | Drop on a ContentDocument Lightning Record Page |
| `pdfUtil` | Shared JS module — no UI. Exports `computeChunks`, `buildFileName`, `segmentsToSaveRequests`, `uint8ToBase64`, `base64ToUint8`, `decodeJobEvent` | Imported by the two LWCs above |
| `pdfLib` (static resource) | 525 KB bundled copy of pdf-lib 1.17.1 | Loaded once per page session via `lightning/platformResourceLoader` |

### Apex classes

| Class | Sharing | Purpose |
|---|---|---|
| `SplitJobController` | `with sharing` | Thin `@AuraEnabled` wrapper. Every LWC → Apex call lands here. Methods: `getLatestContentVersionId`, `getFileContentBase64`, `getLibraryIdForFile`, `getFolderIdForFile`, `uploadChunkPdf`, `startJob`, `enqueueChunkClassification`, `startSaving`, `getJobOutputFiles`, `deleteFiles`, `searchFiles` |
| `SplitJobService` | `with sharing` | Orchestrator. Owns the lifecycle: `startJob`, `enqueueChunkClassification`, `recordChunkCompletion`, `runMergeAndPrepareForSplit`, `startSaving`, `markSaving`, `recordSaveProgress`, `finalizeJob`, `failJob`, `cleanupTempChunkFiles` |
| `ClassifyQueueable` | `with sharing`, `Queueable`, `Database.AllowsCallouts` | Per-chunk AI classification. Invokes the AIDocSplitClassifySpike Flow. |
| `SplitSaveQueueable` | `with sharing`, `Queueable` | Batched save of split PDFs back to the library + folder. Chains itself. |
| `SegmentMerger` | `public` (no DML) | Pure logic. Coalesces overlapping/seam-straddling segments, splits conflicting overlaps, fills gaps. |
| `DocSegment` | DTO | One segment: `documentType`, `sourceInstitution`, `namedParty`, `startPage`, `endPage` |
| `SplitSaveRequest` | DTO | One save: `fileName`, `base64Content`, `documentType`, `sourceInstitution`, `namedParty`, `startPage`, `endPage` |
| `SplitJobException` | exception | Custom exception for input validation failures |

### Data model

| Object / event | Purpose |
|---|---|
| `Document_Type__mdt` | Custom Metadata Type — 20 active records describing the document types the AI knows about. Type Code (BANK_STATEMENT, DRIVERS_LICENSE...), Classification Hints, Sort Order, Is Fallback. |
| `Split_Job__c` | Audit record for one split run. Status pipeline: Queued → Detecting → Merging → Splitting → Saving → Complete (or Error). Holds raw + merged segments JSON, page count, chunk count, completed counter, target folder Id, type breakdown JSON. |
| `Split_Job_Update__e` | Platform Event. Fired at every status transition. Payload includes Job Id, Status, Documents Created, Summary JSON, Message. The LWC subscribes via empApi. |
| `AIDocSplitClassify` | Prompt template (Prompt Builder). Vision-capable; takes `Input:File` (a ContentDocument) and returns the JSON segment array. |
| `AIDocSplitClassifySpike` | Subflow that wraps the prompt invocation so Apex can call it via `Flow.Interview` API. |

---

## 6. Lifecycle of a Split_Job__c

Status transitions are the contract between async stages. Here's the full state machine.

```
   Queued     (created by startJob, before any classify)
     │
     ▼  ──── first enqueueChunkClassification call
   Detecting  (one or more chunks classifying)
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

A clean end-to-end test against a 14-page mixed bundle should produce:

- **10 new ContentDocuments** in the same folder as the source (one per detected segment)
- **Filenames matching pattern** `TypeLabel[_Source]_[PartyName].pdf` (with `_2`, `_3` suffix if more than one of the same)
- **Zero `bundle_chunk_*.pdf` leftovers** — the finalize step deletes them
- **Source bundle untouched** — every delete pathway protects it
- **`Split_Job__c.Status__c = Complete`** with a populated `Type_Breakdown_JSON__c` like `[{"type":"BANK_STATEMENT","count":2},{"type":"DRIVERS_LICENSE","count":1},...]`
- **`Documents_Created__c = 10`** matches the actual file count
- **`Split_Job_Update__e` event stream** ends with a Complete event whose payload's segment count matches the file count

---

## 8. Known limits and trade-offs

| Limit | Where it hits | What to do if you need more |
|---|---|---|
| Apex async heap (12 MB) | Source PDF download via `getFileContentBase64`. Practical cap ~8 MB raw. | For larger files, switch to streaming via REST API + CSP Trusted Site; not needed for typical loan docs. |
| Apex inbound payload (~5 MB) | Chunk PDFs are base64-encoded and uploaded via `@AuraEnabled`. Each chunk usually < 500 KB so no issue. | Larger chunks → multi-part REST upload. |
| 50 enqueued Queueables per transaction | Affects bundles > 400 pages at 8 pages/chunk. | Throttle via a coordinator queue. Not needed for typical loan docs. |
| 32 KB on `Raw_Segments_JSON__c` accumulator | At ~5 KB/chunk this is ~6 chunks safely, ~10 with terse output. | Promote to a child `Chunk_Result__c` object. |
| `lightning/empApi` requires open browser tab | User closing the tab mid-split misses events | The `Split_Job__c` record persists state; re-opening the page can fetch via SOQL. |

---

## 9. Why the two LWCs exist

- **`documentSplitter`** — the original record-page LWC. Drop it on a ContentDocument record page; runs against `recordId` (the file you're viewing).
- **`aiDocumentSplitterStudio`** — the standalone "tool" LWC. Lives on an App Page; user picks any file from search or uploads a new one.

Both go through the same Apex pipeline. The studio is the better UX for general use; the record-page version is handy if you want the splitter button to appear inline on every file.

---

## 10. Where to look when something goes wrong

| Symptom | Where to start |
|---|---|
| LWC shows "Failed to fetch" / "Could not load file" | Check the user has `AIDocAccess` permset assigned; verify the ContentDocument exists. |
| LWC stuck on "Classifying" forever | Setup → Apex Jobs — look for failed `ClassifyQueueable` runs. Often a prompt activation issue (verify `AIDocSplitClassify` is Active in Prompt Builder). |
| Output count says 10 but only 1 visible in results table | `getJobOutputFiles` querying by `ContentDocumentLink LinkedEntityId=jobId`. If links weren't created (older deploy), you'll hit this. The current code creates them explicitly in `SplitSaveQueueable.saveBatch`. |
| Files saved at library root instead of source folder | Check `Split_Job__c.Target_Folder_Id__c` — should be populated. If null, the LWC didn't call `getFolderIdForFile` (older deploy). |
| Temp `bundle_chunk_*.pdf` files piling up | Means the last few jobs hit an error before `finalizeJob`. Run `scripts/apex/cleanup_temp_chunks.apex` to sweep. |
| Status=Error | Read `Split_Job__c.Error_Detail__c` — format is `[Stage] ExceptionType: message`. |

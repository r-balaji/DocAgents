# Technical Build Specification: AI Document Splitter (Slice 1)

**Feature:** Content Library button that classifies and splits a multi-page PDF into individual, typed documents and stores them back in the library.
**Target implementer:** Claude Code (VS Code, org-connected via Salesforce Extensions / SF CLI).
**Platform:** Salesforce Core + Agentforce/Einstein (Prompt Builder, vision-capable model). No external services, no AppExchange managed packages, no Data Cloud OCR dependency.
**Scope of this slice:** Document already exists in a Content Library (`ContentWorkspace`). Trigger = button. Output = split typed PDFs back in the same library + live progress + audit record. Extraction of field-level data is a LATER slice and is explicitly out of scope here.

---

## 1. Summary of Behavior

1. User clicks **Split Documents** on a `ContentDocument` inside a Content Library.
2. System reads the PDF client-side, chunks pages into overlapping batches.
3. Each batch is sent to a **vision prompt template** that returns page-range segments classified into a metadata-defined document type (incl. source bank for Bank Statements).
4. Apex **merges** the per-batch segments, healing documents that straddle chunk seams.
5. The LWC splits the original PDF (using `pdf-lib`) into one PDF per final segment.
6. Split PDFs are **bulk-saved** back into the same Content Library via chained Queueables.
7. Progress and the final type breakdown stream to the UI via **Platform Events**, and a durable **`Split_Job__c`** audit record is written.

---

## 2. Architecture Decisions (locked)

| Concern | Decision | Rationale |
|---|---|---|
| OCR / scanned PDFs | Vision prompt template (file input), not text extraction | Scanned PDFs have no text layer; model reads pixels |
| Large bundles | Chunk pages into **overlapping** batches, AI per batch, merge ranges | Stays under prompt file/page caps; overlap heals seams |
| PDF splitting | Client-side `pdf-lib` in the LWC | Zero Apex CPU/heap cost for binary manipulation |
| Async model | **Queueable** chain | Chaining + complex inputs + isolates long AI calls |
| Live result | **Platform Event** (`Split_Job_Update__e`) | Near-real-time progress in the LWC |
| Audit | **`Split_Job__c`** record | Origination needs a durable trail |
| Doc taxonomy | **Custom Metadata** (`Document_Type__mdt`) | Admin adds types without code change |

---

## 3. Governor Limit Strategy

This is the design's central constraint. Each operation is isolated to keep within limits.

- **AI calls** run in their own async transactions (one Queueable per chunk, or a coordinator). Never block a synchronous transaction on a prompt invocation (10s sync CPU/callout envelope).
- **PDF binary manipulation** happens in the **browser**, never in Apex — eliminates heap (6MB sync / 12MB async) and CPU pressure from blob handling.
- **Original file content** is fetched by the LWC directly (via UI API / `getRecord` content or a lightweight Apex returning a download path), so the raw blob never inflates Apex heap.
- **Saving split files**: bulkify `ContentVersion` inserts; **chunk** saves across chained Queueables (recommended batch size 5–10 files per Queueable, tune by avg file size) to respect heap + DML row limits.
- **Library linking** (`ContentDocumentLink` / workspace membership) bulkified in the same Queueable as the save.
- **Platform Events** publish on commit; each stage publishes only after its work commits. Failures publish an explicit `Error` event (catch → publish → optionally rethrow for retry).

---

## 4. Data Model

### 4.1 Custom Metadata Type: `Document_Type__mdt`

Drives classification and is assembled into the prompt at runtime.

| Field | API Name | Type | Notes |
|---|---|---|---|
| Label | `MasterLabel` | — | e.g. "Bank Statement" |
| Type Code | `Type_Code__c` | Text(80) | Stable key, e.g. `BANK_STATEMENT` |
| Classification Hints | `Classification_Hints__c` | Long Text | Cues the model uses (keywords, layout signals) |
| Capture Source Institution | `Capture_Source__c` | Checkbox | True for Bank Statement → model returns issuing bank |
| Sort Order | `Sort_Order__c` | Number | Order in prompt + priority on ties |
| Is Fallback | `Is_Fallback__c` | Checkbox | Exactly one record = the "Other/Unclassified" bucket |
| Active | `Is_Active__c` | Checkbox | Only active types injected into the prompt |

**Seed records (20):** Driver's License, Bank Statement (Capture Source = true), Pay Stub, W-2, Personal Tax Return 1040, Voided Check / ACH Authorization, Passport, Business Tax Return, Profit & Loss Statement, Balance Sheet, Personal Financial Statement, Articles of Incorporation/Organization, EIN Letter, Business License/Registration, Operating Agreement/Bylaws, Debt Schedule, Property Appraisal/Valuation, Title/Deed/UCC Filing, Insurance Certificate (COI), Other/Unclassified (Is Fallback = true).

### 4.2 Custom Object: `Split_Job__c`

| Field | API Name | Type | Notes |
|---|---|---|---|
| Source Document | `Source_ContentDocument_Id__c` | Text(18) | The original `ContentDocument` |
| Library | `Library_Id__c` | Text(18) | Target `ContentWorkspace` |
| Status | `Status__c` | Picklist | Queued, Detecting, Merging, Splitting, Saving, Complete, Error |
| Total Pages | `Total_Pages__c` | Number | |
| Chunk Count | `Chunk_Count__c` | Number | |
| Documents Created | `Documents_Created__c` | Number | Final count |
| Type Breakdown | `Type_Breakdown_JSON__c` | Long Text | `[{type, count}]` |
| Error Detail | `Error_Detail__c` | Long Text | |
| Started By | `Started_By__c` | Lookup(User) | |

### 4.3 Platform Event: `Split_Job_Update__e`

| Field | API Name | Type |
|---|---|---|
| Job Id | `Job_Id__c` | Text(18) |
| Status | `Status__c` | Text |
| Documents Created | `Documents_Created__c` | Number |
| Summary JSON | `Summary_JSON__c` | Long Text |
| Message | `Message__c` | Text(255) |

---

## 5. Component Inventory (what Claude Code builds)

### 5.1 LWC: `documentSplitter`
- Surfaced as a **Content Library / ContentDocument quick action or list-view button** ("Split Documents").
- Responsibilities:
  - Fetch original PDF bytes client-side.
  - Load `pdf-lib` from a **static resource** (no external CDN — bundle it).
  - Read page count; compute **overlapping chunks** (default size 8 pages, overlap 2 — both configurable).
  - For each chunk: render/extract that page subset as a sub-PDF (in-memory) and send to Apex → prompt.
  - Receive merged final segments from Apex.
  - Split original into N child PDFs by final ranges.
  - Upload child PDFs to Apex for saving.
  - Subscribe to `Split_Job_Update__e` via `lightning/empApi`; render live progress + final breakdown.

### 5.2 Apex: `DocumentSplitController`
- `@AuraEnabled` entry: accepts source `ContentDocumentId` + library Id, creates `Split_Job__c` (Status=Queued), returns Job Id.
- `@AuraEnabled` per-chunk classify method: accepts chunk PDF (base64) + chunk page offset + Job Id → invokes the boundary-detection prompt template → returns offset-corrected segments. (May enqueue async instead of synchronous, depending on prompt latency — see §6.)
- `@AuraEnabled` save method: accepts list of {fileName, base64, type, sourceBank?, startPage, endPage} → enqueues `SplitSaveQueueable`.

### 5.3 Apex: `SegmentMerger` (utility)
- Pure logic, unit-testable without DML.
- Input: all per-chunk segments with absolute page numbers.
- Output: coalesced final segments. Rules:
  - Sort by start page.
  - Merge adjacent/overlapping segments of the **same type** into one.
  - On overlap with **conflicting types**, treat as a real boundary (split at overlap midpoint or per hint priority via `Sort_Order__c`).
  - Guarantee full page coverage; unclassified pages → fallback type.

### 5.4 Apex: `SplitSaveQueueable`
- Chunks the file list into safe batches (default 8), inserts `ContentVersion` records bulk, links to library via `ContentDocumentLink`, chains next batch.
- Updates `Split_Job__c` progress + publishes `Split_Job_Update__e` per batch.
- Final batch: sets Status=Complete, writes `Documents_Created__c` + `Type_Breakdown_JSON__c`, publishes Complete event.
- Try/catch around each batch → Status=Error + Error event on failure.

### 5.5 Prompt Template (Prompt Builder — config, not code, but specced here)
- **Type:** Flex.
- **Inputs:** File (the chunk PDF, as ContentDocument/File object) + Free Text (the assembled type list w/ hints) + chunk page offset.
- **Model:** a vision/image-capable model (verify image+PDF support in the Model Limitations panel of the org).
- **Output:** strict JSON, no markdown fences (see §7).

---

## 6. AI Invocation Note

Prompt invocation latency means synchronous `@AuraEnabled` per-chunk calls risk the sync envelope on slow responses. Two acceptable patterns — implementer picks based on measured latency:
- **A (simpler):** LWC calls classify per chunk synchronously, sequentially; acceptable if each call returns within a few seconds.
- **B (robust):** LWC kicks off all chunks; Apex enqueues a `ClassifyQueueable` per chunk that invokes the prompt and writes results to a staging field/record; LWC polls/listens; merge runs when all chunks report in.
Default to **B** for bundles > 1 chunk.

---

## 7. Prompt Contract

Developer instruction (assembled at runtime; `{{TYPE_LIST}}` injected from active `Document_Type__mdt`):

> You are a document classification and boundary-detection agent. You are given the page images of a contiguous slice of a larger document bundle. The first page of this slice is absolute page number {{PAGE_OFFSET}}. Identify contiguous segments where a single document type runs, and classify each using ONLY the allowed types below. For Bank Statements, also return the issuing institution name. If a segment matches no type, use the fallback type. Return absolute page numbers. Return a strict JSON array and nothing else — no markdown, no prose.
>
> Allowed types: {{TYPE_LIST}}

Output schema:
```json
[
  {"document_type": "BANK_STATEMENT", "source_institution": "Chase", "start_page": 9, "end_page": 12},
  {"document_type": "DRIVERS_LICENSE", "source_institution": null, "start_page": 13, "end_page": 13}
]
```

---

## 8. Acceptance Criteria

1. Button visible on a `ContentDocument` in a Content Library; click creates a `Split_Job__c`.
2. A 40-page mixed scanned bundle splits into correctly typed PDFs with no fragment at chunk seams.
3. Each split PDF saved to the **same** library, named `{TypeLabel}_{n}.pdf` (Bank Statement includes bank: `BankStatement_Chase_1.pdf`).
4. LWC shows live progress and a final breakdown ("7 documents: 1 Driver's License, 2 Bank Statement (Chase, Wells Fargo), …").
5. Unclassified pages land in the fallback type, never lost.
6. No synchronous transaction exceeds limits on a 40-page bundle (verify via debug logs).
7. Adding a new active `Document_Type__mdt` record changes classification with **no code deploy**.
8. A forced failure mid-save sets Status=Error and the LWC shows the error (no infinite spinner).

---

## 9. Out of Scope (later slices)

- Field-level data extraction (names, doc numbers, dates).
- Auto-association to a loan/opportunity record.
- Product-specific (SMB/Commercial/Personal) type gating.
- Human-in-the-loop review/correction UI.
- Duplicate detection across bundles.

---

## 10. Build Order (suggested for Claude Code)

1. Custom Metadata Type + 20 seed records.
2. `Split_Job__c` object + `Split_Job_Update__e` platform event.
3. `SegmentMerger` + its unit tests (pure logic first — cheapest to verify).
4. Prompt template (manual config in org) + a thin Apex wrapper to invoke it.
5. `DocumentSplitController` (classify + save entry points).
6. `SplitSaveQueueable` (bulk save + chaining + events).
7. `documentSplitter` LWC (pdf-lib static resource, chunking, empApi subscription).
8. Wire button/quick action; end-to-end test against acceptance criteria.

---

## 11. Test Notes

- Mock the prompt invocation in Apex tests; assert `SegmentMerger` independently with crafted overlapping inputs.
- Test seam-healing explicitly: a document spanning pages 7–10 with chunk boundary at 8.
- Bulk test save path with 20+ split files to confirm chunking stays under limits.
- Negative test: oversized single page / unreadable PDF → graceful Error event.

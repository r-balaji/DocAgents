import { LightningElement, api, track } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import { subscribe, unsubscribe, onError } from 'lightning/empApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import PDF_LIB_RESOURCE from '@salesforce/resourceUrl/pdfLib';

import getLatestContentVersionId from '@salesforce/apex/SplitJobController.getLatestContentVersionId';
import getFileContentBase64 from '@salesforce/apex/SplitJobController.getFileContentBase64';
import getLibraryIdForFile from '@salesforce/apex/SplitJobController.getLibraryIdForFile';
import getFolderIdForFile from '@salesforce/apex/SplitJobController.getFolderIdForFile';
import uploadChunkPdf from '@salesforce/apex/SplitJobController.uploadChunkPdf';
import startJob from '@salesforce/apex/SplitJobController.startJob';
import enqueueChunkClassifications from '@salesforce/apex/SplitJobController.enqueueChunkClassifications';
import saveSplitBatch from '@salesforce/apex/SplitJobController.saveSplitBatch';
import markJobFailed from '@salesforce/apex/SplitJobController.markJobFailed';

import {
    buildPdfChunksBySize,
    buildBrowserSaveRequests,
    buildTypeBreakdownJson,
    estimateJsonChars,
    fetchContentVersionBytes,
    segmentsToSaveRequests,
    uint8ToBase64,
    base64ToUint8,
    decodeJobEvent
} from 'c/pdfUtil';

const EVENT_CHANNEL = '/event/Split_Job_Update__e';

// UI mode moves PDF bytes through Apex/LWC/browser memory. The source document
// can use a larger direct classification call, but browser-created temporary
// PDFs are uploaded through Aura/Apex as base64 and need a smaller cap.
const SINGLE_CALL_THRESHOLD_BYTES = 7.5 * 1024 * 1024;
const BROWSER_CHUNK_TARGET_BYTES = 2 * 1024 * 1024;
const BROWSER_OUTPUT_TARGET_BYTES = 2 * 1024 * 1024;
const MAX_SAVE_APEX_PAYLOAD_CHARS = 3 * 1024 * 1024;

export default class DocumentSplitter extends LightningElement {
    @api recordId;                              // ContentDocumentId (quick-action context)
    @api libraryId;                             // Optional override; auto-detected from source if blank
    @api chunkSize = 8;                         // deprecated App Builder property; ignored by size-based chunking
    @api chunkOverlap = 0;                      // legacy App Builder property; overlap is disabled

    resolvedLibraryId;                          // populated at click-time from @api libraryId OR Apex auto-detect

    @track status = 'idle';
    @track statusMessage = '';
    @track documentsCreated = 0;
    @track totalChunks = 0;
    @track typeBreakdown = [];                  // for the final summary panel
    @track errorMessage = '';

    pdfLibReady = false;
    subscription;
    jobId;
    sourcePdfBytes;                             // cached for the split-after-merge step

    // ----- Lifecycle -----------------------------------------------------

    async connectedCallback() {
        try {
            await loadScript(this, PDF_LIB_RESOURCE);
            this.pdfLibReady = true;
        } catch (e) {
            this.fail('Could not load pdf-lib: ' + e.message);
        }

        this.subscription = await subscribe(EVENT_CHANNEL, -1, (event) => this.handleJobEvent(event));
        onError((err) => {
            // eslint-disable-next-line no-console
            console.error('empApi error', err);
        });
    }

    disconnectedCallback() {
        if (this.subscription) {
            unsubscribe(this.subscription);
            this.subscription = null;
        }
    }

    // ----- Click handler -----------------------------------------------------

    async handleSplitClick() {
        if (!this.pdfLibReady) {
            this.toast('Not ready', 'pdf-lib is still loading. Try again in a moment.', 'warning');
            return;
        }
        try {
            await this.runSplitPipeline();
        } catch (e) {
            this.fail(e.message);
        }
    }

    async runSplitPipeline() {
        this.status = 'preparing';
        this.statusMessage = 'Resolving target library...';
        this.errorMessage = '';

        // 0. Resolve the target library. Use the configured libraryId only if it
        // looks like a ContentWorkspace Id (starts with 058). Otherwise auto-detect
        // — this guards against an admin accidentally pasting a ContentDocument Id
        // or another Salesforce Id into the property.
        const configuredLooksValid = this.libraryId
            && typeof this.libraryId === 'string'
            && this.libraryId.startsWith('058')
            && (this.libraryId.length === 15 || this.libraryId.length === 18);
        this.resolvedLibraryId = configuredLooksValid
            ? this.libraryId
            : await getLibraryIdForFile({ sourceContentDocumentId: this.recordId });
        this.resolvedFolderId = await getFolderIdForFile({ sourceContentDocumentId: this.recordId });

        // 1. Get the latest ContentVersion Id for the source document.
        this.statusMessage = 'Loading source PDF...';
        const cvId = await getLatestContentVersionId({ contentDocumentId: this.recordId });

        // 2. Download the source PDF. Direct file servlet download avoids
        // @AuraEnabled base64 response limits; Apex remains as a small-file fallback.
        this.sourcePdfBytes = await this.loadSourcePdfBytes(cvId);

        // 3. Load the PDF in pdf-lib and read page count.
        const { PDFDocument } = window.PDFLib;
        const sourceDoc = await PDFDocument.load(this.sourcePdfBytes);
        const totalPages = sourceDoc.getPageCount();
        if (totalPages < 1) {
            throw new Error('Source PDF has no pages.');
        }

        // 4. Branch: single-call (<= 7.5 MB) vs size-based chunking.
        const useSingleCall = this.sourcePdfBytes.length <= SINGLE_CALL_THRESHOLD_BYTES;

        if (useSingleCall) {
            this.totalChunks = 1;
            this.statusMessage = `Classifying ${totalPages} pages in a single call...`;

            this.jobId = await startJob({
                sourceContentDocumentId: this.recordId,
                libraryId: this.resolvedLibraryId,
                folderId: this.resolvedFolderId,
                totalPages,
                chunkCount: 1
            });
            this.status = 'classifying';

            // Whole source acts as "chunk 0" with absolute page numbers (offset=1).
            await enqueueChunkClassifications({
                jobId: this.jobId,
                chunksJson: JSON.stringify([{
                    chunkIndex: 0,
                    chunkContentDocumentId: this.recordId,
                    pageOffset: 1
                }])
            });
            return;
        }

        // 5. Chunked path (files > 7.5 MB).
        const chunks = await buildPdfChunksBySize(
            PDFDocument,
            sourceDoc,
            BROWSER_CHUNK_TARGET_BYTES,
            0
        );
        this.totalChunks = chunks.length;
        this.statusMessage = `Preparing ${chunks.length} browser-safe chunks (${totalPages} pages total)...`;

        const chunkUploads = [];
        for (const chunk of chunks) {
            const base64 = uint8ToBase64(chunk.bytes);
            const fileName = `bundle_chunk_${chunk.chunkIndex}.pdf`;
            // eslint-disable-next-line no-await-in-loop
            const chunkCdId = await uploadChunkPdf({
                fileName,
                base64Content: base64,
                libraryId: this.resolvedLibraryId
            });
            chunkUploads.push({ ...chunk, chunkContentDocumentId: chunkCdId });
            this.statusMessage = `Uploaded chunk ${chunk.chunkIndex + 1} of ${chunks.length}...`;
        }

        this.jobId = await startJob({
            sourceContentDocumentId: this.recordId,
            libraryId: this.resolvedLibraryId,
            folderId: this.resolvedFolderId,
            totalPages,
            chunkCount: chunks.length
        });
        this.status = 'classifying';
        this.statusMessage = `Classifying ${chunks.length} chunks...`;

        await enqueueChunkClassifications({
            jobId: this.jobId,
            chunksJson: JSON.stringify(chunkUploads.map((upload) => ({
                chunkIndex: upload.chunkIndex,
                chunkContentDocumentId: upload.chunkContentDocumentId,
                pageOffset: upload.startPage
            })))
        });
    }

    // ----- empApi event handling --------------------------------------------

    async handleJobEvent(event) {
        const decoded = decodeJobEvent(event, this.jobId);
        if (!decoded) return;

        this.statusMessage = decoded.message || decoded.status;

        if (decoded.status === 'Detecting' || decoded.status === 'Merging') {
            this.status = 'classifying';
            return;
        }
        if (decoded.status === 'Splitting' && decoded.summaryJson) {
            this.status = 'splitting';
            try {
                await this.splitAndSave(decoded.summaryJson);
            } catch (e) {
                this.fail(e.message);
            }
            return;
        }
        if (decoded.status === 'Saving') {
            this.status = 'saving';
            this.documentsCreated = decoded.documentsCreated;
            return;
        }
        if (decoded.status === 'Complete') {
            this.status = 'complete';
            this.documentsCreated = decoded.documentsCreated;
            this.typeBreakdown = decoded.summaryJson ? JSON.parse(decoded.summaryJson) : [];
            this.toast('Done', `Split into ${this.documentsCreated} files.`, 'success');
            return;
        }
        if (decoded.status === 'Error') {
            this.fail(decoded.message || 'Unknown error', false);
        }
    }

    async splitAndSave(mergedSegmentsJson) {
        const segments = JSON.parse(mergedSegmentsJson);
        if (!segments || segments.length === 0) {
            await this.saveSplitRequestBatch([], 0, '[]', true);
            return;
        }
        if (!this.sourcePdfBytes) {
            // Stale event (LWC re-mounted after pipeline started in a prior
            // instance). The Apex finalizer will still complete the job;
            // nothing for this instance to do here.
            return;
        }

        const { PDFDocument } = window.PDFLib;
        const sourceDoc = await PDFDocument.load(this.sourcePdfBytes);
        const requests = await buildBrowserSaveRequests(
            PDFDocument,
            sourceDoc,
            segmentsToSaveRequests(segments),
            BROWSER_OUTPUT_TARGET_BYTES,
            MAX_SAVE_APEX_PAYLOAD_CHARS
        );
        const typeBreakdownJson = buildTypeBreakdownJson(requests);
        let pending = [];
        let documentsSaved = 0;

        for (const outputRequest of requests) {
            if (estimateJsonChars([outputRequest]) > MAX_SAVE_APEX_PAYLOAD_CHARS) {
                throw new Error(`Split output ${outputRequest.fileName} is too large for browser save. Use Web/headless mode for this file.`);
            }

            if (pending.length > 0
                && estimateJsonChars([...pending, outputRequest]) > MAX_SAVE_APEX_PAYLOAD_CHARS) {
                // eslint-disable-next-line no-await-in-loop
                documentsSaved = await this.saveSplitRequestBatch(pending, documentsSaved, typeBreakdownJson, false);
                pending = [];
            }
            pending.push(outputRequest);
        }

        this.statusMessage = `Saving ${requests.length} files...`;
        await this.saveSplitRequestBatch(pending, documentsSaved, typeBreakdownJson, true);
    }

    async loadSourcePdfBytes(contentVersionId) {
        try {
            return await fetchContentVersionBytes(contentVersionId);
        } catch (downloadError) {
            this.statusMessage = downloadError && downloadError.message
                ? 'Direct file download failed; loading through Apex fallback...'
                : 'Loading source PDF through Apex fallback...';
            const base64 = await getFileContentBase64({ contentVersionId });
            return base64ToUint8(base64);
        }
    }

    async saveSplitRequestBatch(requests, documentsSavedSoFar, typeBreakdownJson, isFinalBatch) {
        const result = await saveSplitBatch({
            jobId: this.jobId,
            requestsJson: JSON.stringify(requests),
            documentsSavedSoFar,
            typeBreakdownJson,
            isFinalBatch
        });
        this.documentsCreated = result && result.documentsSaved ? result.documentsSaved : documentsSavedSoFar;
        return this.documentsCreated;
    }

    // ----- UI helpers ---------------------------------------------------------

    get progressLabel() {
        switch (this.status) {
            case 'preparing':
                return 'Preparing...';
            case 'classifying':
                return 'Classifying documents...';
            case 'splitting':
                return 'Splitting bundle...';
            case 'saving':
                return `Saving (${this.documentsCreated} so far)...`;
            case 'complete':
                return `Complete - ${this.documentsCreated} files saved.`;
            case 'error':
                return 'Error';
            default:
                return 'Ready';
        }
    }

    get isBusy() {
        return this.status !== 'idle' && this.status !== 'complete' && this.status !== 'error';
    }

    get isComplete() {
        return this.status === 'complete';
    }

    get isError() {
        return this.status === 'error';
    }

    get buttonDisabled() {
        return !this.pdfLibReady || this.isBusy;
    }

    get breakdownLines() {
        return (this.typeBreakdown || []).map((row, i) => ({
            key: `br-${i}`,
            label: `${row.count} ${row.type}`
        }));
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    fail(message, reportToServer = true) {
        const failedStatus = this.status || 'Browser split';
        this.status = 'error';
        this.errorMessage = message;
        this.toast('Error', message, 'error');
        if (reportToServer) {
            this.reportJobFailure(message, failedStatus);
        }
    }

    reportJobFailure(message, failedStatus) {
        if (!this.jobId) {
            return;
        }
        markJobFailed({
            jobId: this.jobId,
            stage: failedStatus || 'Browser split',
            errorDetail: message
        }).catch(() => {
            // Keep the original browser error visible; failure reporting is best effort.
        });
    }
}

import { LightningElement, api, track } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import { subscribe, unsubscribe, onError } from 'lightning/empApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import PDF_LIB_RESOURCE from '@salesforce/resourceUrl/pdfLib';

import getLatestContentVersionId from '@salesforce/apex/SplitJobController.getLatestContentVersionId';
import uploadChunkPdf from '@salesforce/apex/SplitJobController.uploadChunkPdf';
import startJob from '@salesforce/apex/SplitJobController.startJob';
import enqueueChunkClassification from '@salesforce/apex/SplitJobController.enqueueChunkClassification';
import startSaving from '@salesforce/apex/SplitJobController.startSaving';

import { computeChunks, segmentsToSaveRequests, uint8ToBase64, decodeJobEvent } from './pdfLibUtil';

const EVENT_CHANNEL = '/event/Split_Job_Update__e';

export default class DocumentSplitter extends LightningElement {
    @api recordId;                              // ContentDocumentId (quick-action context)
    @api libraryId;                             // FlexiPage attribute — required
    @api chunkSize = 8;                         // configurable in App Builder
    @api chunkOverlap = 2;

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
        if (!this.libraryId) {
            this.toast('Missing library', 'Library Id is not configured on this page. Ask an admin.', 'error');
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
        this.statusMessage = 'Loading source PDF...';
        this.errorMessage = '';

        // 1. Get the latest ContentVersion Id for the source document.
        const cvId = await getLatestContentVersionId({ contentDocumentId: this.recordId });

        // 2. Download the source PDF bytes via the shepherd URL (session cookie auth).
        const downloadUrl = `/sfc/servlet.shepherd/version/download/${cvId}`;
        const resp = await fetch(downloadUrl, { credentials: 'include' });
        if (!resp.ok) {
            throw new Error(`Source PDF download failed (HTTP ${resp.status})`);
        }
        this.sourcePdfBytes = new Uint8Array(await resp.arrayBuffer());

        // 3. Load the PDF in pdf-lib and read page count.
        const { PDFDocument } = window.PDFLib;
        const sourceDoc = await PDFDocument.load(this.sourcePdfBytes);
        const totalPages = sourceDoc.getPageCount();

        // 4. Compute overlapping chunks.
        const chunks = computeChunks(totalPages, this.chunkSize, this.chunkOverlap);
        if (chunks.length === 0) {
            throw new Error('Source PDF has no pages.');
        }
        this.totalChunks = chunks.length;
        this.statusMessage = `Preparing ${chunks.length} chunks (${totalPages} pages total)...`;

        // 5. Build sub-PDFs for each chunk and upload them.
        const chunkUploads = [];
        for (const chunk of chunks) {
            const subDoc = await PDFDocument.create();
            const pageIndices = [];
            for (let p = chunk.startPage - 1; p <= chunk.endPage - 1; p++) {
                pageIndices.push(p);
            }
            const copied = await subDoc.copyPages(sourceDoc, pageIndices);
            copied.forEach((page) => subDoc.addPage(page));
            const subBytes = await subDoc.save();
            const base64 = uint8ToBase64(subBytes);
            const fileName = `bundle_chunk_${chunk.chunkIndex}.pdf`;
            // eslint-disable-next-line no-await-in-loop
            const chunkCdId = await uploadChunkPdf({
                fileName,
                base64Content: base64,
                libraryId: this.libraryId
            });
            chunkUploads.push({ ...chunk, chunkContentDocumentId: chunkCdId });
            this.statusMessage = `Uploaded chunk ${chunk.chunkIndex + 1} of ${chunks.length}...`;
        }

        // 6. Create the Split_Job__c.
        this.jobId = await startJob({
            sourceContentDocumentId: this.recordId,
            libraryId: this.libraryId,
            totalPages,
            chunkCount: chunks.length
        });
        this.status = 'classifying';
        this.statusMessage = `Classifying ${chunks.length} chunks...`;

        // 7. Enqueue one classify per chunk.
        for (const upload of chunkUploads) {
            // eslint-disable-next-line no-await-in-loop
            await enqueueChunkClassification({
                jobId: this.jobId,
                chunkIndex: upload.chunkIndex,
                chunkContentDocumentId: upload.chunkContentDocumentId,
                pageOffset: upload.startPage
            });
        }
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
            this.fail(decoded.message || 'Unknown error');
        }
    }

    async splitAndSave(mergedSegmentsJson) {
        const segments = JSON.parse(mergedSegmentsJson);
        if (!segments || segments.length === 0) {
            await startSaving({ jobId: this.jobId, requestsJson: '[]', batchSize: 8 });
            return;
        }
        if (!this.sourcePdfBytes) {
            throw new Error('Source PDF bytes were not cached for the split step.');
        }

        const { PDFDocument } = window.PDFLib;
        const sourceDoc = await PDFDocument.load(this.sourcePdfBytes);
        const requests = segmentsToSaveRequests(segments);

        for (const req of requests) {
            const subDoc = await PDFDocument.create();
            const pageIndices = [];
            for (let p = req.startPage - 1; p <= req.endPage - 1; p++) {
                pageIndices.push(p);
            }
            // eslint-disable-next-line no-await-in-loop
            const copied = await subDoc.copyPages(sourceDoc, pageIndices);
            copied.forEach((page) => subDoc.addPage(page));
            // eslint-disable-next-line no-await-in-loop
            const bytes = await subDoc.save();
            req.base64Content = uint8ToBase64(bytes);
        }

        this.statusMessage = `Saving ${requests.length} files...`;
        await startSaving({
            jobId: this.jobId,
            requestsJson: JSON.stringify(requests),
            batchSize: 8
        });
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

    fail(message) {
        this.status = 'error';
        this.errorMessage = message;
        this.toast('Error', message, 'error');
    }
}

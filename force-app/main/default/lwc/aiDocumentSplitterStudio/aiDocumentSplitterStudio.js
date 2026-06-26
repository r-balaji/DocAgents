import { LightningElement, api, track } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import { subscribe, unsubscribe, onError } from 'lightning/empApi';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import PDF_LIB_RESOURCE from '@salesforce/resourceUrl/pdfLib';

import getLatestContentVersionId from '@salesforce/apex/SplitJobController.getLatestContentVersionId';
import getFileContentBase64 from '@salesforce/apex/SplitJobController.getFileContentBase64';
import getLibraryIdForFile from '@salesforce/apex/SplitJobController.getLibraryIdForFile';
import getFolderIdForFile from '@salesforce/apex/SplitJobController.getFolderIdForFile';
import uploadChunkPdf from '@salesforce/apex/SplitJobController.uploadChunkPdf';
import startJob from '@salesforce/apex/SplitJobController.startJob';
import enqueueChunkClassification from '@salesforce/apex/SplitJobController.enqueueChunkClassification';
import startSaving from '@salesforce/apex/SplitJobController.startSaving';
import searchFiles from '@salesforce/apex/SplitJobController.searchFiles';
import getJobOutputFiles from '@salesforce/apex/SplitJobController.getJobOutputFiles';
import deleteFiles from '@salesforce/apex/SplitJobController.deleteFiles';

import {
    computeChunks,
    segmentsToSaveRequests,
    uint8ToBase64,
    base64ToUint8,
    decodeJobEvent
} from 'c/pdfUtil';

const EVENT_CHANNEL = '/event/Split_Job_Update__e';

export default class AiDocumentSplitterStudio extends NavigationMixin(LightningElement) {
    @api chunkSize = 8;
    @api chunkOverlap = 2;

    @track searchTerm = '';
    @track searchResults = [];
    @track selectedFile;                            // {id, title, fileType, size, latestVersionId}
    @track stage = 'idle';                          // idle | preparing | classifying | splitting | saving | complete | error
    @track statusMessage = '';
    @track progressPercent = 0;
    @track errorMessage = '';
    @track outputFiles = [];                        // [{id, title, ...}]
    @track selectedOutputIds = new Set();
    @track typeBreakdown = [];
    @track isDeleting = false;

    pdfLibReady = false;
    subscription;
    jobId;
    sourcePdfBytes;
    resolvedLibraryId;
    totalChunksForProgress = 1;

    // ---- Lifecycle ----------------------------------------------------------

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
        // Default search shows recent PDFs.
        await this.runSearch('');
    }

    disconnectedCallback() {
        if (this.subscription) {
            unsubscribe(this.subscription);
            this.subscription = null;
        }
    }

    // ---- File picker --------------------------------------------------------

    handleSearchChange(event) {
        this.searchTerm = event.target.value;
        // Debounce slightly so we don't query on every keystroke.
        clearTimeout(this._searchDebounce);
        this._searchDebounce = setTimeout(() => this.runSearch(this.searchTerm), 250);
    }

    async runSearch(term) {
        try {
            const results = await searchFiles({ searchTerm: term });
            this.searchResults = results.map((r) => ({
                ...r,
                sizeLabel: this.formatSize(r.size),
                isSelected: this.selectedFile && this.selectedFile.id === r.id
            }));
        } catch (e) {
            this.toast('Search error', e.body ? e.body.message : e.message, 'error');
        }
    }

    handlePickFile(event) {
        const id = event.currentTarget.dataset.id;
        const picked = this.searchResults.find((f) => f.id === id);
        if (picked) {
            this.selectedFile = picked;
            this.searchResults = this.searchResults.map((r) => ({ ...r, isSelected: r.id === id }));
            this.stage = 'idle';
            this.outputFiles = [];
            this.errorMessage = '';
        }
    }

    handleClearSelection() {
        this.selectedFile = null;
        this.searchResults = this.searchResults.map((r) => ({ ...r, isSelected: false }));
    }

    // ---- File upload --------------------------------------------------------

    get acceptedFormats() {
        return ['.pdf'];
    }

    async handleUploadFinished(event) {
        const uploaded = event.detail.files;
        if (!uploaded || uploaded.length === 0) return;
        const file = uploaded[0];
        // The uploaded file is a ContentDocument. Refresh search so it shows up
        // and auto-select it.
        await this.runSearch('');
        const picked = this.searchResults.find((f) => f.id === file.documentId);
        if (picked) {
            this.selectedFile = picked;
            this.searchResults = this.searchResults.map((r) => ({ ...r, isSelected: r.id === picked.id }));
        }
        this.toast('Uploaded', `${file.name} is ready to split.`, 'success');
    }

    // ---- Split orchestration ------------------------------------------------

    get canSplit() {
        return this.pdfLibReady && this.selectedFile && !this.isBusy;
    }

    async handleSplitClick() {
        if (!this.canSplit) return;
        try {
            await this.runSplitPipeline();
        } catch (e) {
            this.fail(e.body && e.body.message ? e.body.message : e.message);
        }
    }

    async runSplitPipeline() {
        this.stage = 'preparing';
        this.statusMessage = 'Resolving target library...';
        this.errorMessage = '';
        this.outputFiles = [];
        this.progressPercent = 5;

        this.resolvedLibraryId = await getLibraryIdForFile({ sourceContentDocumentId: this.selectedFile.id });
        this.resolvedFolderId = await getFolderIdForFile({ sourceContentDocumentId: this.selectedFile.id });

        this.statusMessage = 'Loading source PDF...';
        this.progressPercent = 15;
        const cvId = await getLatestContentVersionId({ contentDocumentId: this.selectedFile.id });
        const base64 = await getFileContentBase64({ contentVersionId: cvId });
        this.sourcePdfBytes = base64ToUint8(base64);

        const { PDFDocument } = window.PDFLib;
        const sourceDoc = await PDFDocument.load(this.sourcePdfBytes);
        const totalPages = sourceDoc.getPageCount();
        const chunks = computeChunks(totalPages, this.chunkSize, this.chunkOverlap);
        if (chunks.length === 0) {
            throw new Error('Source PDF has no pages.');
        }
        this.totalChunksForProgress = chunks.length;

        this.statusMessage = `Preparing ${chunks.length} chunks (${totalPages} pages)...`;
        this.progressPercent = 25;

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
            const b64 = uint8ToBase64(subBytes);
            const fileName = `bundle_chunk_${chunk.chunkIndex}.pdf`;
            // eslint-disable-next-line no-await-in-loop
            const chunkCdId = await uploadChunkPdf({
                fileName,
                base64Content: b64,
                libraryId: this.resolvedLibraryId
            });
            chunkUploads.push({ ...chunk, chunkContentDocumentId: chunkCdId });
        }

        this.jobId = await startJob({
            sourceContentDocumentId: this.selectedFile.id,
            libraryId: this.resolvedLibraryId,
            folderId: this.resolvedFolderId,
            totalPages,
            chunkCount: chunks.length
        });
        this.stage = 'classifying';
        this.statusMessage = `Classifying ${chunks.length} chunks...`;
        this.progressPercent = 40;

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

    // ---- empApi event handling ----------------------------------------------

    async handleJobEvent(event) {
        const decoded = decodeJobEvent(event, this.jobId);
        if (!decoded) return;

        this.statusMessage = decoded.message || decoded.status;

        if (decoded.status === 'Detecting' || decoded.status === 'Merging') {
            this.stage = 'classifying';
            // Bump progress proportional to classified chunks.
            this.progressPercent = Math.min(70, 40 + (30 * 0.5));
            return;
        }
        if (decoded.status === 'Splitting' && decoded.summaryJson) {
            this.stage = 'splitting';
            this.progressPercent = 75;
            try {
                await this.splitAndSave(decoded.summaryJson);
            } catch (e) {
                this.fail(e.message);
            }
            return;
        }
        if (decoded.status === 'Saving') {
            this.stage = 'saving';
            this.progressPercent = 85;
            return;
        }
        if (decoded.status === 'Complete') {
            this.stage = 'complete';
            this.progressPercent = 100;
            this.typeBreakdown = decoded.summaryJson ? JSON.parse(decoded.summaryJson) : [];
            this.toast('Done', `Split into ${decoded.documentsCreated} files.`, 'success');
            await this.loadOutputFiles();
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
            // Stale Splitting event from a previous job in this tab, or this LWC
            // instance was re-mounted after the pipeline started. Backend already
            // produced the merged JSON; we just can't drive the binary split
            // here. The save phase happened on the prior instance — nothing for
            // us to do beyond logging.
            return;
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
        await startSaving({
            jobId: this.jobId,
            requestsJson: JSON.stringify(requests),
            batchSize: 8
        });
    }

    async loadOutputFiles() {
        if (!this.jobId) return;
        try {
            const files = await getJobOutputFiles({ jobId: this.jobId });
            this.outputFiles = files.map((f) => ({
                ...f,
                sizeLabel: this.formatSize(f.size),
                isSelected: false
            }));
            this.selectedOutputIds = new Set();
        } catch (e) {
            this.toast('Could not load splits', e.body ? e.body.message : e.message, 'warning');
        }
    }

    // ---- Output file actions ------------------------------------------------

    handleOutputRowToggle(event) {
        const id = event.target.dataset.id;
        const checked = event.target.checked;
        const next = new Set(this.selectedOutputIds);
        if (checked) {
            next.add(id);
        } else {
            next.delete(id);
        }
        this.selectedOutputIds = next;
        this.outputFiles = this.outputFiles.map((f) => ({ ...f, isSelected: next.has(f.id) }));
    }

    handleSelectAll(event) {
        const checked = event.target.checked;
        const next = checked ? new Set(this.outputFiles.map((f) => f.id)) : new Set();
        this.selectedOutputIds = next;
        this.outputFiles = this.outputFiles.map((f) => ({ ...f, isSelected: next.has(f.id) }));
    }

    async handleDeleteSelected() {
        if (this.selectedOutputIds.size === 0) {
            this.toast('Nothing selected', 'Tick the rows you want to delete first.', 'info');
            return;
        }
        await this.deleteByIds(Array.from(this.selectedOutputIds));
    }

    async handleDeleteAll() {
        if (this.outputFiles.length === 0) return;
        await this.deleteByIds(this.outputFiles.map((f) => f.id));
    }

    async deleteByIds(ids) {
        if (this.isDeleting) return;   // ignore double-clicks
        this.isDeleting = true;
        try {
            const count = await deleteFiles({
                contentDocumentIds: ids,
                protectedSourceId: this.selectedFile ? this.selectedFile.id : null
            });
            this.toast('Deleted', `${count} file(s) removed. Source bundle is safe.`, 'success');
            await this.loadOutputFiles();
        } catch (e) {
            this.toast('Delete failed', e.body ? e.body.message : e.message, 'error');
        } finally {
            this.isDeleting = false;
        }
    }

    handleOpenFile(event) {
        const versionId = event.currentTarget.dataset.versionId;
        if (!versionId) return;
        this[NavigationMixin.Navigate]({
            type: 'standard__namedPage',
            attributes: { pageName: 'filePreview' },
            state: { selectedRecordId: event.currentTarget.dataset.id }
        });
    }

    handleReset() {
        this.stage = 'idle';
        this.statusMessage = '';
        this.progressPercent = 0;
        this.outputFiles = [];
        this.errorMessage = '';
        this.selectedFile = null;
        this.jobId = null;
    }

    // ---- UI helpers ---------------------------------------------------------

    get isIdle() { return this.stage === 'idle'; }
    get isBusy() { return ['preparing', 'classifying', 'splitting', 'saving'].includes(this.stage); }
    get isComplete() { return this.stage === 'complete'; }
    get isError() { return this.stage === 'error'; }

    get progressLabel() {
        switch (this.stage) {
            case 'preparing':   return 'Preparing PDF';
            case 'classifying': return 'Classifying with AI';
            case 'splitting':   return 'Splitting bundle';
            case 'saving':      return 'Saving files';
            case 'complete':    return 'Complete';
            case 'error':       return 'Error';
            default:            return 'Ready';
        }
    }

    get progressPercentStyle() {
        return `width: ${this.progressPercent}%`;
    }

    get selectedCountLabel() {
        const n = this.selectedOutputIds.size;
        return n === 0 ? '' : `${n} selected`;
    }

    get breakdownLines() {
        return (this.typeBreakdown || []).map((row, i) => ({
            key: `br-${i}`,
            label: `${row.count} ${row.type}`
        }));
    }

    formatSize(bytes) {
        if (!bytes && bytes !== 0) return '';
        if (bytes < 1024) return `${bytes} B`;
        if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
        return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    fail(message) {
        this.stage = 'error';
        this.errorMessage = message;
        this.toast('Error', message, 'error');
    }
}

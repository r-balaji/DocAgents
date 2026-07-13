/**
 * Shared pure-function helpers for the document splitter LWCs.
 *
 * This LWC bundle exists only to expose JS exports. It has no template / class,
 * so it's not surfaceable in the App Builder — `isExposed=false` in the meta xml.
 * Both `documentSplitter` (record-page LWC) and `aiDocumentSplitterStudio`
 * (app-page LWC) import from here.
 */

/**
 * Download a ContentVersion directly through Salesforce's file servlet.
 *
 * This avoids routing large PDF bytes through an @AuraEnabled Apex return
 * value, where base64 expansion plus the Aura envelope can fail before useful
 * server logs are produced.
 */
export async function fetchContentVersionBytes(contentVersionId) {
    if (!contentVersionId) {
        throw new Error('contentVersionId is required.');
    }
    const response = await fetch(`/sfc/servlet.shepherd/version/download/${encodeURIComponent(contentVersionId)}`, {
        credentials: 'same-origin'
    });
    if (!response.ok) {
        throw new Error(`File download failed (${response.status}).`);
    }
    return new Uint8Array(await response.arrayBuffer());
}

/**
 * Build chunks by saved PDF byte size instead of a fixed page count.
 *
 * The returned `bytes` are ready to upload as each temporary bundle_chunk_N.pdf.
 * If one source page alone exceeds maxBytes, that page is still emitted as a
 * single-page chunk so the pipeline can continue and surface the provider error.
 */
export async function buildPdfChunksBySize(PDFDocument, sourceDoc, maxBytes, overlap = 0) {
    const totalPages = sourceDoc && typeof sourceDoc.getPageCount === 'function'
        ? sourceDoc.getPageCount()
        : 0;
    if (!PDFDocument || !sourceDoc || !Number.isInteger(totalPages) || totalPages < 1) {
        return [];
    }

    const targetBytes = Number.isFinite(maxBytes) && maxBytes > 0
        ? maxBytes
        : Number.MAX_SAFE_INTEGER;
    const requestedOverlap = Number.isInteger(overlap) && overlap > 0 ? overlap : 0;
    return buildChunksRecursive(PDFDocument, sourceDoc, totalPages, targetBytes, requestedOverlap, 1, 0, []);
}

async function buildChunksRecursive(PDFDocument, sourceDoc, totalPages, targetBytes, overlap, startPage, chunkIndex, chunks) {
    if (startPage > totalPages) {
        return chunks;
    }

    const best = await findLargestChunkWithinTarget(
        PDFDocument,
        sourceDoc,
        totalPages,
        targetBytes,
        startPage,
        startPage,
        startPage,
        null
    );

    chunks.push({
        chunkIndex,
        startPage,
        endPage: best.endPage,
        bytes: best.bytes
    });

    if (best.endPage >= totalPages) {
        return chunks;
    }

    const pagesInChunk = best.endPage - startPage + 1;
    const safeOverlap = Math.min(overlap, Math.max(0, pagesInChunk - 1));
    return buildChunksRecursive(
        PDFDocument,
        sourceDoc,
        totalPages,
        targetBytes,
        overlap,
        best.endPage - safeOverlap + 1,
        chunkIndex + 1,
        chunks
    );
}

async function findLargestChunkWithinTarget(
    PDFDocument,
    sourceDoc,
    totalPages,
    targetBytes,
    startPage,
    endPage,
    bestEndPage,
    bestBytes
) {
    if (endPage > totalPages) {
        return { endPage: bestEndPage, bytes: bestBytes };
    }

    const candidateBytes = await copyPageRangeAsBytes(PDFDocument, sourceDoc, startPage, endPage);
    const candidateTooLarge = candidateBytes.length > targetBytes;
    if (candidateTooLarge && endPage > startPage) {
        return { endPage: bestEndPage, bytes: bestBytes };
    }

    if (candidateTooLarge) {
        return { endPage, bytes: candidateBytes };
    }

    return findLargestChunkWithinTarget(
        PDFDocument,
        sourceDoc,
        totalPages,
        targetBytes,
        startPage,
        endPage + 1,
        endPage,
        candidateBytes
    );
}

async function copyPageRangeAsBytes(PDFDocument, sourceDoc, startPage, endPage) {
    const subDoc = await PDFDocument.create();
    const pageIndices = [];
    for (let p = startPage - 1; p <= endPage - 1; p += 1) {
        pageIndices.push(p);
    }
    const copied = await subDoc.copyPages(sourceDoc, pageIndices);
    copied.forEach((page) => subDoc.addPage(page));
    return subDoc.save();
}

/**
 * Build a filesystem-safe filename matching the Apex SplitSaveRequest.buildFileName.
 *
 * Two patterns:
 *  - Known types (BANK_STATEMENT, DRIVERS_LICENSE, ...) — include the source
 *    institution and named party so the loan officer can identify whose doc this is.
 *    e.g. BankStatement_Chase_John_Smith.pdf, BankStatement_Chase_John_Smith_2.pdf
 *  - OTHER (fallback) — strip the party/source entirely and use one catch-all
 *    output. The AI's party extraction on unrecognized pages is unreliable, so the
 *    extracted name is more noise than signal.
 *    e.g. Other.pdf
 */
export function buildFileName(documentType, sourceInstitution, namedParty, index) {
    if (documentType === 'OTHER') {
        return 'Other.pdf';
    }
    const parts = [toTitleCase(documentType)];
    if (sourceInstitution && sourceInstitution.trim()) {
        parts.push(sanitize(sourceInstitution));
    }
    if (namedParty && namedParty.trim()) {
        parts.push(sanitize(namedParty));
    }
    if (index && index > 1) {
        parts.push(String(index));
    }
    return `${parts.join('_')}.pdf`;
}

/**
 * Re-key the merged segments into save requests. Known types get a
 * per-(type,party,source) index so multiple files of the same kind don't collide.
 * OTHER pages are bundled into one catch-all output because they are not useful
 * as separate split documents.
 */
export function segmentsToSaveRequests(segments) {
    const counts = new Map();
    const requests = [];
    const otherPages = [];

    for (const seg of segments || []) {
        if (!seg) {
            continue;
        }
        const type = seg.documentType || 'OTHER';
        const pages = Array.isArray(seg.pages) ? [...seg.pages] : [];
        if (type === 'OTHER') {
            otherPages.push(...pages);
            continue;
        }

        // For known types we group by (type, source, party) so two Chase
        // statements for John get _1 and _2 while a Wells Fargo statement for
        // John starts fresh at _1.
        const key = [type, seg.sourceInstitution || '', seg.namedParty || ''].join('|');
        const nextIndex = (counts.get(key) || 0) + 1;
        counts.set(key, nextIndex);
        requests.push({
            fileName: buildFileName(type, seg.sourceInstitution, seg.namedParty, nextIndex),
            documentType: type,
            sourceInstitution: seg.sourceInstitution || null,
            namedParty: seg.namedParty || null,
            instanceLabel: seg.instanceLabel || null,
            pages
        });
    }

    const normalizedOtherPages = uniqueSortedPositiveIntegers(otherPages);
    if (normalizedOtherPages.length > 0) {
        requests.push({
            fileName: buildFileName('OTHER', null, null, 1),
            documentType: 'OTHER',
            sourceInstitution: null,
            namedParty: null,
            instanceLabel: null,
            pages: normalizedOtherPages
        });
    }

    return requests;
}

/**
 * Build the final Split_Job__c.Type_Breakdown_JSON__c payload from save
 * requests without needing Apex to keep cross-request browser state.
 */
export function buildTypeBreakdownJson(requests) {
    const counts = new Map();
    for (const req of requests || []) {
        const key = req && req.documentType ? req.documentType : 'OTHER';
        counts.set(key, (counts.get(key) || 0) + 1);
    }
    return JSON.stringify(Array.from(counts.keys()).sort().map((type) => ({
        type,
        count: counts.get(type)
    })));
}

/**
 * Build browser-save payloads from logical split requests.
 *
 * The UI splits any oversized logical output into numbered files using a raw
 * PDF byte cap before sending base64 through Apex. Headless/service paths do
 * not use this helper, so their grouped outputs stay as one logical file.
 */
export async function buildBrowserSaveRequests(PDFDocument, sourceDoc, requests, maxRawBytes, maxJsonChars) {
    const outputRequests = [];
    for (const req of requests || []) {
        if (!req) {
            continue;
        }

        const output = await buildOutputCandidate(PDFDocument, sourceDoc, req, req.pages, req.fileName);
        if (fitsBrowserSave(output, maxRawBytes, maxJsonChars)) {
            outputRequests.push(output.request);
            continue;
        }

        const splitRequests = await splitRequestForBrowserSave(
            PDFDocument,
            sourceDoc,
            req,
            maxRawBytes,
            maxJsonChars
        );
        outputRequests.push(...splitRequests);
    }
    return outputRequests;
}

async function splitRequestForBrowserSave(PDFDocument, sourceDoc, req, maxRawBytes, maxJsonChars) {
    const pages = Array.isArray(req.pages) ? req.pages : [];
    const outputRequests = [];
    let currentPages = [];
    let currentOutput = null;

    for (const page of pages) {
        const candidatePages = [...currentPages, page];
        const candidateFileName = numberedPartFileName(req.fileName, outputRequests.length + 1);
        const candidateOutput = await buildOutputCandidate(
            PDFDocument,
            sourceDoc,
            req,
            candidatePages,
            candidateFileName
        );

        if (fitsBrowserSave(candidateOutput, maxRawBytes, maxJsonChars)) {
            currentPages = candidatePages;
            currentOutput = candidateOutput;
            continue;
        }

        if (currentPages.length === 0) {
            throw new Error(`Split output ${candidateFileName} is too large for browser save. Use Web/headless mode for this file.`);
        }

        outputRequests.push(currentOutput.request);
        currentPages = [page];
        currentOutput = await buildOutputCandidate(
            PDFDocument,
            sourceDoc,
            req,
            currentPages,
            numberedPartFileName(req.fileName, outputRequests.length + 1)
        );

        if (!fitsBrowserSave(currentOutput, maxRawBytes, maxJsonChars)) {
            throw new Error(`Split output ${currentOutput.request.fileName} is too large for browser save. Use Web/headless mode for this file.`);
        }
    }

    if (currentOutput) {
        outputRequests.push(currentOutput.request);
    }
    return outputRequests;
}

function numberedPartFileName(fileName, partNumber) {
    const safeFileName = fileName || 'Document.pdf';
    const extensionIndex = safeFileName.lastIndexOf('.');
    if (extensionIndex <= 0) {
        return `${safeFileName}_${partNumber}`;
    }
    return `${safeFileName.substring(0, extensionIndex)}_${partNumber}${safeFileName.substring(extensionIndex)}`;
}

async function buildOutputCandidate(PDFDocument, sourceDoc, req, pages, fileName) {
    const subDoc = await PDFDocument.create();
    const pageIndices = (Array.isArray(pages) ? pages : []).map((p) => p - 1);
    const copied = await subDoc.copyPages(sourceDoc, pageIndices);
    copied.forEach((page) => subDoc.addPage(page));
    const bytes = await subDoc.save();
    return {
        byteLength: bytes.length,
        request: {
            ...req,
            fileName,
            pages: Array.isArray(pages) ? [...pages] : [],
            base64Content: uint8ToBase64(bytes)
        }
    };
}

function fitsBrowserSave(output, maxRawBytes, maxJsonChars) {
    if (!output || !output.request) {
        return false;
    }
    const rawLimit = Number.isFinite(maxRawBytes) && maxRawBytes > 0
        ? maxRawBytes
        : Number.MAX_SAFE_INTEGER;
    const jsonLimit = Number.isFinite(maxJsonChars) && maxJsonChars > 0
        ? maxJsonChars
        : Number.MAX_SAFE_INTEGER;
    return output.byteLength <= rawLimit && estimateJsonChars([output.request]) <= jsonLimit;
}

/**
 * Estimate the serialized request size sent over an imperative Apex action.
 * String length is the useful guard here because the heavy field is base64.
 */
export function estimateJsonChars(value) {
    return JSON.stringify(value || null).length;
}

/**
 * Uint8Array -> base64 string. Chunked to avoid fromCharCode argument-list limits.
 */
export function uint8ToBase64(bytes) {
    let binary = '';
    const sliceSize = 0x8000;
    for (let i = 0; i < bytes.length; i += sliceSize) {
        const slice = bytes.subarray(i, i + sliceSize);
        binary += String.fromCharCode.apply(null, slice);
    }
    return btoa(binary);
}

/**
 * base64 -> Uint8Array for feeding to pdf-lib.
 */
export function base64ToUint8(base64) {
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
        bytes[i] = binary.charCodeAt(i);
    }
    return bytes;
}

/**
 * Decode a Split_Job_Update__e event payload, filtering by expectedJobId.
 *
 * empApi subscriptions are channel-wide, so every LWC instance (every tab,
 * every user) receives every event. An instance that hasn't started a job
 * must ignore ALL events — otherwise it tries to act on someone else's job
 * with an undefined this.jobId, hitting downstream "jobId is required" /
 * pdf-undefined errors. So expectedJobId is required, not optional.
 */
export function decodeJobEvent(event, expectedJobId) {
    if (!expectedJobId) return null;
    const payload = event && event.data && event.data.payload;
    if (!payload) return null;
    if (payload.Job_Id__c !== expectedJobId) return null;
    return {
        jobId: payload.Job_Id__c,
        status: payload.Status__c,
        documentsCreated: payload.Documents_Created__c || 0,
        summaryJson: payload.Summary_JSON__c || null,
        message: payload.Message__c || null
    };
}

// ----- Internal helpers --------------------------------------------------

function toTitleCase(typeCode) {
    if (!typeCode) return 'Document';
    return typeCode
        .toLowerCase()
        .split('_')
        .map((w) => (w.length ? w.charAt(0).toUpperCase() + w.slice(1) : ''))
        .join('');
}

function sanitize(s) {
    if (!s) return '';
    return s.replace(/[^A-Za-z0-9]+/g, '_').replace(/^_+|_+$/g, '');
}

function uniqueSortedPositiveIntegers(values) {
    return Array.from(new Set((values || [])
        .filter((value) => Number.isInteger(value) && value > 0)))
        .sort((a, b) => a - b);
}

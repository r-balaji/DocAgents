/**
 * Shared pure-function helpers for the document splitter LWCs.
 *
 * This LWC bundle exists only to expose JS exports. It has no template / class,
 * so it's not surfaceable in the App Builder — `isExposed=false` in the meta xml.
 * Both `documentSplitter` (record-page LWC) and `aiDocumentSplitterStudio`
 * (app-page LWC) import from here.
 */

/**
 * Compute overlapping chunks for a given page count.
 */
export function computeChunks(totalPages, chunkSize = 8, overlap = 2) {
    if (!Number.isInteger(totalPages) || totalPages < 1) {
        return [];
    }
    if (chunkSize < 1) chunkSize = 1;
    if (overlap < 0) overlap = 0;
    if (overlap >= chunkSize) overlap = chunkSize - 1;

    const stride = chunkSize - overlap;
    const chunks = [];
    let chunkIndex = 0;
    let startPage = 1;
    while (startPage <= totalPages) {
        const endPage = Math.min(startPage + chunkSize - 1, totalPages);
        chunks.push({ chunkIndex, startPage, endPage });
        if (endPage >= totalPages) break;
        startPage += stride;
        chunkIndex += 1;
    }
    return chunks;
}

/**
 * Build a filesystem-safe filename matching the Apex SplitSaveRequest.buildFileName.
 */
export function buildFileName(documentType, sourceInstitution, namedParty, index) {
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
 * Re-key the merged segments into save requests, assigning per-(type,party,source)
 * index so multiple files of the same kind don't collide.
 */
export function segmentsToSaveRequests(segments) {
    const counts = new Map();
    const requests = [];
    for (const seg of segments) {
        const key = [seg.documentType, seg.sourceInstitution || '', seg.namedParty || ''].join('|');
        const nextIndex = (counts.get(key) || 0) + 1;
        counts.set(key, nextIndex);
        requests.push({
            fileName: buildFileName(seg.documentType, seg.sourceInstitution, seg.namedParty, nextIndex),
            documentType: seg.documentType,
            sourceInstitution: seg.sourceInstitution || null,
            namedParty: seg.namedParty || null,
            startPage: seg.startPage,
            endPage: seg.endPage
        });
    }
    return requests;
}

/**
 * Uint8Array -> base64 string. Chunked to avoid fromCharCode argument-list limits.
 */
export function uint8ToBase64(bytes) {
    let binary = '';
    const chunkSize = 0x8000;
    for (let i = 0; i < bytes.length; i += chunkSize) {
        const slice = bytes.subarray(i, i + chunkSize);
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
 */
export function decodeJobEvent(event, expectedJobId) {
    const payload = event && event.data && event.data.payload;
    if (!payload) return null;
    if (expectedJobId && payload.Job_Id__c !== expectedJobId) return null;
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

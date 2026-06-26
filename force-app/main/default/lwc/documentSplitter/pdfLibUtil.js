/**
 * Pure-function helpers for the documentSplitter LWC.
 *
 * Keeping these out of the main component file makes them straightforward to
 * Jest-test without mocking the platform or pdf-lib's runtime behavior.
 *
 * pdf-lib operations themselves still happen in the main component because they
 * touch the global window.PDFLib injected by platformResourceLoader. The helpers
 * here cover: chunk math, filename construction, segment grouping for save, and
 * blob <-> base64 conversion.
 */

/**
 * Compute overlapping chunks for a given page count.
 * @param {number} totalPages
 * @param {number} chunkSize default 8
 * @param {number} overlap default 2 (each chunk except the first re-includes
 *                              this many pages from the end of the previous)
 * @returns {Array<{chunkIndex: number, startPage: number, endPage: number}>}
 *          1-based page numbers, inclusive endPage.
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
 * Build a human-readable, filesystem-safe filename for a split output.
 * Mirrors the Apex SplitSaveRequest.buildFileName helper so the LWC can
 * produce identical names client-side.
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
 * Re-key the merged segments into save requests, applying buildFileName and
 * incrementing per-(type,party,source) index so multiple files of the same
 * kind don't collide. Returns input ready for the Apex SplitJobController.startSaving.
 *
 * @param {Array<{documentType, sourceInstitution, namedParty, startPage, endPage}>} segments
 * @returns {Array<{fileName, documentType, sourceInstitution, namedParty, startPage, endPage}>}
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
 * Convert a Uint8Array (from pdf-lib.save()) to a base64 string ready to send
 * to Apex. Uses a chunked loop to avoid the "argument list too long" issue
 * String.fromCharCode hits with very large byte arrays.
 */
export function uint8ToBase64(bytes) {
    let binary = '';
    const chunkSize = 0x8000; // 32 KB per chunk
    for (let i = 0; i < bytes.length; i += chunkSize) {
        const slice = bytes.subarray(i, i + chunkSize);
        binary += String.fromCharCode.apply(null, slice);
    }
    return btoa(binary);
}

/**
 * Decode the Split_Job_Update__e payload into a normalized shape.
 * Returns null if the event isn't for our job.
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

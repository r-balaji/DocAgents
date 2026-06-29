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
 *
 * Two patterns:
 *  - Known types (BANK_STATEMENT, DRIVERS_LICENSE, ...) — include the source
 *    institution and named party so the loan officer can identify whose doc this is.
 *    e.g. BankStatement_Chase_John_Smith.pdf, BankStatement_Chase_John_Smith_2.pdf
 *  - OTHER (fallback) — strip the party/source entirely and use a clean sequential
 *    suffix. The AI's party extraction on unrecognized pages is unreliable, so the
 *    extracted name is more noise than signal.
 *    e.g. Other_1.pdf, Other_2.pdf
 */
export function buildFileName(documentType, sourceInstitution, namedParty, index) {
    if (documentType === 'OTHER') {
        return `Other_${index || 1}.pdf`;
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
 * Re-key the merged segments into save requests, assigning per-(type,party,source)
 * index so multiple files of the same kind don't collide.
 */
export function segmentsToSaveRequests(segments) {
    const counts = new Map();
    const requests = [];
    for (const seg of segments) {
        // OTHER segments share one counter regardless of party/source — every
        // unrecognized page gets the next Other_N number. For known types we
        // group by (type, source, party) so two Chase statements for John get
        // _1 and _2 while a Wells Fargo statement for John starts fresh at _1.
        const key = seg.documentType === 'OTHER'
            ? 'OTHER'
            : [seg.documentType, seg.sourceInstitution || '', seg.namedParty || ''].join('|');
        const nextIndex = (counts.get(key) || 0) + 1;
        counts.set(key, nextIndex);
        requests.push({
            fileName: buildFileName(seg.documentType, seg.sourceInstitution, seg.namedParty, nextIndex),
            documentType: seg.documentType,
            sourceInstitution: seg.sourceInstitution || null,
            namedParty: seg.namedParty || null,
            instanceLabel: seg.instanceLabel || null,
            pages: Array.isArray(seg.pages) ? [...seg.pages] : []
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

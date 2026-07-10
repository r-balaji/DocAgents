import {
    buildBrowserSaveRequests,
    buildPdfChunksBySize,
    buildTypeBreakdownJson,
    buildFileName,
    estimateJsonChars,
    segmentsToSaveRequests,
    uint8ToBase64,
    decodeJobEvent
} from '../pdfUtil';

function fakePdfEnv(pageSizes) {
    const sourceDoc = {
        getPageCount: () => pageSizes.length
    };
    const PDFDocument = {
        create: jest.fn(async () => {
            const pages = [];
            return {
                copyPages: jest.fn(async (_source, pageIndices) => pageIndices.map((index) => ({
                    byteSize: pageSizes[index]
                }))),
                addPage: jest.fn((page) => pages.push(page)),
                save: jest.fn(async () => {
                    const byteLength = pages.reduce((total, page) => total + page.byteSize, 0);
                    return new Uint8Array(byteLength);
                })
            };
        })
    };
    return { PDFDocument, sourceDoc };
}

describe('buildPdfChunksBySize', () => {
    it('builds chunks that stay under the byte target', async () => {
        const { PDFDocument, sourceDoc } = fakePdfEnv([4, 4, 4, 4]);

        const chunks = await buildPdfChunksBySize(PDFDocument, sourceDoc, 10, 0);

        expect(chunks.map(({ chunkIndex, startPage, endPage, bytes }) => ({
            chunkIndex,
            startPage,
            endPage,
            byteLength: bytes.length
        }))).toEqual([
            { chunkIndex: 0, startPage: 1, endPage: 2, byteLength: 8 },
            { chunkIndex: 1, startPage: 3, endPage: 4, byteLength: 8 }
        ]);
    });

    it('keeps overlap while still progressing', async () => {
        const { PDFDocument, sourceDoc } = fakePdfEnv([4, 4, 4, 4]);

        const chunks = await buildPdfChunksBySize(PDFDocument, sourceDoc, 10, 1);

        expect(chunks.map(({ chunkIndex, startPage, endPage }) => ({
            chunkIndex,
            startPage,
            endPage
        }))).toEqual([
            { chunkIndex: 0, startPage: 1, endPage: 2 },
            { chunkIndex: 1, startPage: 2, endPage: 3 },
            { chunkIndex: 2, startPage: 3, endPage: 4 }
        ]);
    });

    it('emits a single oversized page when one page exceeds the target', async () => {
        const { PDFDocument, sourceDoc } = fakePdfEnv([12, 3]);

        const chunks = await buildPdfChunksBySize(PDFDocument, sourceDoc, 10, 0);

        expect(chunks.map(({ startPage, endPage, bytes }) => ({
            startPage,
            endPage,
            byteLength: bytes.length
        }))).toEqual([
            { startPage: 1, endPage: 1, byteLength: 12 },
            { startPage: 2, endPage: 2, byteLength: 3 }
        ]);
    });
});

describe('buildBrowserSaveRequests', () => {
    it('keeps a small OTHER request as Other.pdf', async () => {
        const { PDFDocument, sourceDoc } = fakePdfEnv([5, 5]);
        const requests = await buildBrowserSaveRequests(PDFDocument, sourceDoc, [{
            fileName: 'Other.pdf',
            documentType: 'OTHER',
            sourceInstitution: null,
            namedParty: null,
            instanceLabel: null,
            pages: [1, 2]
        }], 10000, 10000);

        expect(requests).toHaveLength(1);
        expect(requests[0].fileName).toBe('Other.pdf');
        expect(requests[0].pages).toEqual([1, 2]);
        expect(requests[0].base64Content).toBeTruthy();
    });

    it('splits oversized OTHER output into numbered files', async () => {
        const { PDFDocument, sourceDoc } = fakePdfEnv([100, 100, 100]);
        const requests = await buildBrowserSaveRequests(PDFDocument, sourceDoc, [{
            fileName: 'Other.pdf',
            documentType: 'OTHER',
            sourceInstitution: null,
            namedParty: null,
            instanceLabel: null,
            pages: [1, 2, 3]
        }], 150, 10000);

        expect(requests.map((req) => ({
            fileName: req.fileName,
            documentType: req.documentType,
            pages: req.pages
        }))).toEqual([
            { fileName: 'Other_1.pdf', documentType: 'OTHER', pages: [1] },
            { fileName: 'Other_2.pdf', documentType: 'OTHER', pages: [2] },
            { fileName: 'Other_3.pdf', documentType: 'OTHER', pages: [3] }
        ]);
    });

    it('throws when a known document output is too large', async () => {
        const { PDFDocument, sourceDoc } = fakePdfEnv([100]);

        await expect(buildBrowserSaveRequests(PDFDocument, sourceDoc, [{
            fileName: 'BankStatement_Chase.pdf',
            documentType: 'BANK_STATEMENT',
            sourceInstitution: 'Chase',
            namedParty: null,
            instanceLabel: null,
            pages: [1]
        }], 10, 10000)).rejects.toThrow('BankStatement_Chase.pdf is too large');
    });
});

describe('buildFileName', () => {
    it('builds with all parts present', () => {
        expect(buildFileName('BANK_STATEMENT', 'Bank of America', 'John Smith', 1))
            .toBe('BankStatement_Bank_of_America_John_Smith.pdf');
    });

    it('omits source when blank', () => {
        expect(buildFileName('DRIVERS_LICENSE', null, 'Jane Doe', 1))
            .toBe('DriversLicense_Jane_Doe.pdf');
    });

    it('uses one catch-all file for OTHER', () => {
        expect(buildFileName('OTHER', null, null, 2)).toBe('Other.pdf');
    });

    it('omits index when 1', () => {
        expect(buildFileName('PASSPORT', null, 'Jane', 1)).toBe('Passport_Jane.pdf');
    });

    it('handles multi-word type codes', () => {
        expect(buildFileName('PERSONAL_TAX_RETURN_1040', null, null, 1))
            .toBe('PersonalTaxReturn1040.pdf');
    });

    it('falls back to Document for blank type', () => {
        expect(buildFileName(null, null, null, 1)).toBe('Document.pdf');
        expect(buildFileName('', null, null, 1)).toBe('Document.pdf');
    });

    it('sanitizes party names with punctuation', () => {
        expect(buildFileName('ARTICLES_OF_INCORPORATION', null, 'Synthetic Holdings, Inc.', 1))
            .toBe('ArticlesOfIncorporation_Synthetic_Holdings_Inc.pdf');
    });
});

describe('segmentsToSaveRequests', () => {
    it('assigns index 1 to first of kind, increments for duplicates', () => {
        const segments = [
            { documentType: 'BANK_STATEMENT', sourceInstitution: 'Chase', namedParty: 'John', startPage: 1, endPage: 2 },
            { documentType: 'BANK_STATEMENT', sourceInstitution: 'Chase', namedParty: 'John', startPage: 5, endPage: 7 },
            { documentType: 'BANK_STATEMENT', sourceInstitution: 'Wells', namedParty: 'John', startPage: 8, endPage: 9 }
        ];
        const reqs = segmentsToSaveRequests(segments);
        expect(reqs[0].fileName).toBe('BankStatement_Chase_John.pdf');
        expect(reqs[1].fileName).toBe('BankStatement_Chase_John_2.pdf');
        expect(reqs[2].fileName).toBe('BankStatement_Wells_John.pdf');
    });

    it('preserves page ranges and types', () => {
        const segments = [
            { documentType: 'DRIVERS_LICENSE', sourceInstitution: null, namedParty: 'John', pages: [1, 4] }
        ];
        const reqs = segmentsToSaveRequests(segments);
        expect(reqs[0]).toMatchObject({
            documentType: 'DRIVERS_LICENSE',
            namedParty: 'John',
            pages: [1, 4]
        });
    });

    it('normalizes blank source/party to null', () => {
        const segments = [
            { documentType: 'OTHER', sourceInstitution: '', namedParty: '', pages: [1] }
        ];
        const reqs = segmentsToSaveRequests(segments);
        expect(reqs[0].sourceInstitution).toBeNull();
        expect(reqs[0].namedParty).toBeNull();
    });

    it('combines all OTHER pages into one catch-all request', () => {
        const segments = [
            { documentType: 'OTHER', sourceInstitution: null, namedParty: 'Noise', pages: [9, 1] },
            { documentType: 'BANK_STATEMENT', sourceInstitution: 'Chase', namedParty: 'John', pages: [2, 3] },
            { documentType: 'OTHER', sourceInstitution: 'Unknown', namedParty: null, pages: [4, 1] }
        ];
        const reqs = segmentsToSaveRequests(segments);
        expect(reqs).toHaveLength(2);
        expect(reqs[0].fileName).toBe('BankStatement_Chase_John.pdf');
        expect(reqs[1]).toMatchObject({
            fileName: 'Other.pdf',
            documentType: 'OTHER',
            sourceInstitution: null,
            namedParty: null,
            pages: [1, 4, 9]
        });
    });
});

describe('buildTypeBreakdownJson', () => {
    it('builds sorted type counts', () => {
        const json = buildTypeBreakdownJson([
            { documentType: 'W2' },
            { documentType: 'BANK_STATEMENT' },
            { documentType: 'BANK_STATEMENT' },
            { documentType: null }
        ]);

        expect(JSON.parse(json)).toEqual([
            { type: 'BANK_STATEMENT', count: 2 },
            { type: 'OTHER', count: 1 },
            { type: 'W2', count: 1 }
        ]);
    });
});

describe('estimateJsonChars', () => {
    it('returns the serialized JSON character count', () => {
        const payload = [{ fileName: 'a.pdf', base64Content: 'YWJj' }];
        expect(estimateJsonChars(payload)).toBe(JSON.stringify(payload).length);
    });
});

describe('uint8ToBase64', () => {
    it('round-trips a small byte array', () => {
        const input = new Uint8Array([72, 101, 108, 108, 111]); // "Hello"
        expect(uint8ToBase64(input)).toBe('SGVsbG8=');
    });

    it('handles a larger array via the chunked loop without throwing', () => {
        const big = new Uint8Array(100000).fill(65); // 100KB of 'A'
        const out = uint8ToBase64(big);
        expect(out.length).toBeGreaterThan(0);
        // 100KB base64-encoded is ~133KB.
        expect(out.length).toBeGreaterThan(130000);
    });
});

describe('decodeJobEvent', () => {
    const buildEvent = (payload) => ({ data: { payload } });

    it('returns null for missing payload', () => {
        expect(decodeJobEvent({}, 'a01')).toBeNull();
        expect(decodeJobEvent({ data: {} }, 'a01')).toBeNull();
    });

    it('filters out events for other jobs', () => {
        const evt = buildEvent({ Job_Id__c: 'a01XXX', Status__c: 'Saving' });
        expect(decodeJobEvent(evt, 'a01YYY')).toBeNull();
    });

    it('decodes a Saving event for my job', () => {
        const evt = buildEvent({
            Job_Id__c: 'a01XXX',
            Status__c: 'Saving',
            Documents_Created__c: 3,
            Summary_JSON__c: null,
            Message__c: 'Saved 3 files so far.'
        });
        const decoded = decodeJobEvent(evt, 'a01XXX');
        expect(decoded).toEqual({
            jobId: 'a01XXX',
            status: 'Saving',
            documentsCreated: 3,
            summaryJson: null,
            message: 'Saved 3 files so far.'
        });
    });

    it('decodes a Complete event with summary JSON', () => {
        const evt = buildEvent({
            Job_Id__c: 'a01XXX',
            Status__c: 'Complete',
            Documents_Created__c: 7,
            Summary_JSON__c: '[{"type":"BANK_STATEMENT","count":2}]'
        });
        const decoded = decodeJobEvent(evt, 'a01XXX');
        expect(decoded.status).toBe('Complete');
        expect(decoded.documentsCreated).toBe(7);
        expect(JSON.parse(decoded.summaryJson)[0].type).toBe('BANK_STATEMENT');
    });

    it('ignores events without a jobId filter', () => {
        const evt = buildEvent({ Job_Id__c: 'a01XXX', Status__c: 'Detecting' });
        const decoded = decodeJobEvent(evt, null);
        expect(decoded).toBeNull();
    });
});

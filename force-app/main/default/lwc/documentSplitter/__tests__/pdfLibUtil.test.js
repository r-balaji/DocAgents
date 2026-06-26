import {
    computeChunks,
    buildFileName,
    segmentsToSaveRequests,
    uint8ToBase64,
    decodeJobEvent
} from '../pdfLibUtil';

describe('computeChunks', () => {
    it('returns empty for invalid input', () => {
        expect(computeChunks(0)).toEqual([]);
        expect(computeChunks(-5)).toEqual([]);
        expect(computeChunks(null)).toEqual([]);
        expect(computeChunks('foo')).toEqual([]);
    });

    it('returns one chunk when totalPages <= chunkSize', () => {
        const chunks = computeChunks(5, 8, 2);
        expect(chunks).toEqual([{ chunkIndex: 0, startPage: 1, endPage: 5 }]);
    });

    it('produces overlapping chunks for a 14-page bundle (default 8/2)', () => {
        const chunks = computeChunks(14, 8, 2);
        // Stride = 6. Chunks: 1-8, 7-14.
        expect(chunks).toEqual([
            { chunkIndex: 0, startPage: 1, endPage: 8 },
            { chunkIndex: 1, startPage: 7, endPage: 14 }
        ]);
    });

    it('covers every page with overlap', () => {
        // 20 pages, chunk 8, overlap 2 → stride 6. 1-8, 7-14, 13-20.
        const chunks = computeChunks(20, 8, 2);
        expect(chunks).toEqual([
            { chunkIndex: 0, startPage: 1, endPage: 8 },
            { chunkIndex: 1, startPage: 7, endPage: 14 },
            { chunkIndex: 2, startPage: 13, endPage: 20 }
        ]);
    });

    it('clamps a too-large overlap to chunkSize-1', () => {
        // overlap 10 with chunkSize 4 → effective overlap 3, stride 1.
        const chunks = computeChunks(6, 4, 10);
        // 1-4, 2-5, 3-6.
        expect(chunks[0]).toEqual({ chunkIndex: 0, startPage: 1, endPage: 4 });
        expect(chunks[chunks.length - 1].endPage).toBe(6);
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

    it('omits party when blank', () => {
        expect(buildFileName('OTHER', null, null, 2)).toBe('Other_2.pdf');
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
            { documentType: 'DRIVERS_LICENSE', sourceInstitution: null, namedParty: 'John', startPage: 1, endPage: 1 }
        ];
        const reqs = segmentsToSaveRequests(segments);
        expect(reqs[0]).toMatchObject({
            documentType: 'DRIVERS_LICENSE',
            namedParty: 'John',
            startPage: 1,
            endPage: 1
        });
    });

    it('normalizes blank source/party to null', () => {
        const segments = [
            { documentType: 'OTHER', sourceInstitution: '', namedParty: '', startPage: 1, endPage: 1 }
        ];
        const reqs = segmentsToSaveRequests(segments);
        expect(reqs[0].sourceInstitution).toBeNull();
        expect(reqs[0].namedParty).toBeNull();
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

    it('accepts events without a jobId filter', () => {
        const evt = buildEvent({ Job_Id__c: 'a01XXX', Status__c: 'Detecting' });
        const decoded = decodeJobEvent(evt, null);
        expect(decoded.jobId).toBe('a01XXX');
    });
});

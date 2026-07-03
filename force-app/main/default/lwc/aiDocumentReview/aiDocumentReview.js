import { LightningElement, api } from 'lwc';
import {
    FlowNavigationFinishEvent,
    FlowNavigationNextEvent
} from 'lightning/flowSupport';

export default class AiDocumentReview extends LightningElement {
    @api coverageJson;
    @api classificationJson;
    @api sanityJson;
    @api availableActions = [];

    get coverage() {
        // Apex shape: { totals: { total, filled, missing }, filledCategoryNames: [], missingCategoryNames: [] }
        const raw = this.safeParse(this.coverageJson, {});
        const totals = raw.totals || {};
        return {
            requiredCount:     totals.total   ?? 0,
            onFileCount:       totals.filled  ?? 0,
            missingCount:      totals.missing ?? 0,
            providedDocuments: raw.filledCategoryNames  || [],
            missingDocuments:  raw.missingCategoryNames || []
        };
    }

    get classificationItems() {
        const parsed = this.safeParse(this.classificationJson, { items: [] });
        return (parsed.items || []).map((item, index) => {
            const status = (item.classificationStatus || item.typeStatus || item.status || 'UNKNOWN').trim();
            return {
                key: `cls-${index}`,
                documentName: item.documentName || item.category || 'Document',
                category: item.category || '',
                status,
                pillClass: this.classifyPill(status, item.severity)
            };
        });
    }

    get sanityItems() {
        const parsed = this.safeParse(this.sanityJson, { items: [] });

        return (parsed.items || []).map((item, index) => {
            const status = item.status || 'REVIEW';
            const rawDetail = (item.detail || item.finding || '').replace(/\s+/g, ' ').trim();
            const summary = item.summary
                ? item.summary.replace(/\s+/g, ' ').trim()
                : this.createSummary(rawDetail);

            // Only expose detail if it adds info beyond the summary
            const hasMoreInDetail = rawDetail && rawDetail.length > summary.length;
            const detail = hasMoreInDetail ? rawDetail : '';

            const severity = this.getFindingSeverity(item);

            return {
                key: `sanity-${index}`,
                documentName: item.documentName || 'Document',
                status,
                summary,
                detail,
                rowClass: `finding finding-${severity}`,
                statusClass: `finding-status finding-status-${severity}`
            };
        });
    }

    getFindingSeverity(item) {
        const status = (item.status || '').trim().toUpperCase();
        const severity = (item.severity || '').toLowerCase();

        if (this.isErrorStatus(status)) {
            return 'error';
        }
        if (this.isWarningStatus(status)) {
            return 'warning';
        }
        if (this.isSuccessStatus(status)) {
            return 'success';
        }

        if (severity === 'error') return 'error';
        if (severity === 'warning') return 'warning';
        if (severity === 'success') return 'success';

        return 'warning';
    }

    createSummary(text) {
        if (!text) {
            return '';
        }

        const cleaned = text.replace(/\s+/g, ' ').trim();

        if (cleaned.length <= 180) {
            return cleaned;
        }

        return `${cleaned.substring(0, 180).trim()}...`;
    }

    get providedDocuments() {
        return (this.coverage.providedDocuments || []).map((name, i) => ({ key: `p-${i}`, name }));
    }

    get missingDocuments() {
        return (this.coverage.missingDocuments || []).map((name, i) => ({ key: `m-${i}`, name }));
    }

    get noProvidedDocs() { return !this.providedDocuments.length; }
    get noMissingDocs()  { return !this.missingDocuments.length; }

    safeParse(value, fallback) {
        try { return value ? JSON.parse(value) : fallback; }
        catch { return fallback; }
    }

    classifyPill(status, severity) {
        const s = (status || '').toUpperCase();
        if (this.isSuccessStatus(s)) {
            return 'pill pill-success';
        }
        if (this.isErrorStatus(s)) {
            return 'pill pill-error';
        }
        if (this.isWarningStatus(s)) {
            return 'pill pill-warning';
        }

        const sev = (severity || '').toLowerCase();
        if (sev === 'success') return 'pill pill-success';
        if (sev === 'error') return 'pill pill-error';
        if (sev === 'warning') return 'pill pill-warning';

        return 'pill pill-warning';
    }

    isSuccessStatus(status) {
        return ['OK', 'PASS', 'CORRECT', 'ACCEPTABLE'].includes(status);
    }

    isWarningStatus(status) {
        return ['INCOMPLETE', 'STALE', 'EXPIRING_SOON'].includes(status);
    }

    isErrorStatus(status) {
        return (
            status.includes('WRONG') ||
            status.includes('MISMATCH') ||
            ['UNREADABLE', 'UNACCEPTABLE', 'EXPIRED'].includes(status)
        );
    }

    handleFinish() {
        if (this.availableActions.includes('FINISH')) {
            this.dispatchEvent(new FlowNavigationFinishEvent());
        } else if (this.availableActions.includes('NEXT')) {
            this.dispatchEvent(new FlowNavigationNextEvent());
        } else {
            this.dispatchEvent(new CustomEvent('finish'));
        }
    }
}

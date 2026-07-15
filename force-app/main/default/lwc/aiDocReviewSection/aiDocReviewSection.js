import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue, notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import EMAIL_TEMPLATE_FIELD from '@salesforce/schema/genesis__Applications__c.Email_Template__c';
import acceptApplicationUpload from '@salesforce/apex/AIDocIntakeService.acceptApplicationUpload';

const FALLBACK_SUBJECT = 'Loan Application — Documents Needed';

export default class AiDocReviewSection extends LightningElement {
    @api recordId;
    @api toAddress;

    showFullModal = false;
    showUploadModal = false;
    isStartingIntake = false;
    isExpanded = false;

    @wire(getRecord, { recordId: '$recordId', fields: [EMAIL_TEMPLATE_FIELD] })
    application;

    get rawEmail() {
        return getFieldValue(this.application.data, EMAIL_TEMPLATE_FIELD) || '';
    }

    get hasEmail() {
        return this.rawEmail.trim().length > 0;
    }

    get hasEmailDisabled() {
        return !this.hasEmail;
    }

    get acceptedUploadFormats() {
        return ['.pdf'];
    }

    get emailStatusLabel() {
        return this.hasEmail ? 'Draft ready' : 'No draft';
    }

    get emailStatusClass() {
        return this.hasEmail ? 'review-status review-status_ready' : 'review-status';
    }

    get toggleIconName() {
        return this.isExpanded ? 'utility:chevronup' : 'utility:chevrondown';
    }

    get toggleTitle() {
        return this.isExpanded ? 'Collapse document review' : 'Expand document review';
    }

    get parsed() {
        const raw = this.rawEmail;
        if (!raw) return { subject: '', body: '' };
        const match = raw.match(/^\s*Subject:\s*(.+?)\r?\n\s*\r?\n([\s\S]+)$/i);
        if (match) {
            return { subject: match[1].trim(), body: match[2].trim() };
        }
        // Backward compat: prompt may not yet emit a Subject line.
        return { subject: FALLBACK_SUBJECT, body: raw.trim() };
    }

    get subject() {
        return this.parsed.subject;
    }

    get bodyParagraphs() {
        const body = this.parsed.body;
        if (!body) return [];
        return body
            .split(/\r?\n\s*\r?\n/)
            .map((text, i) => ({ key: `p-${i}`, text }));
    }

    get previewText() {
        const body = this.parsed.body;
        if (!body) return '';
        const firstPara = body.split(/\r?\n\s*\r?\n/)[0] || '';
        const oneLine = firstPara.replace(/\s+/g, ' ').trim();
        return oneLine.length > 180 ? `${oneLine.slice(0, 180)}…` : oneLine;
    }

    handleToggle() {
        this.isExpanded = !this.isExpanded;
    }

    handleShowFull() {
        if (this.hasEmail) {
            this.showFullModal = true;
        }
    }

    handleCloseModal() {
        this.showFullModal = false;
    }

    handleOpenUpload() {
        this.showUploadModal = true;
    }

    handleCloseUpload() {
        if (!this.isStartingIntake) {
            this.showUploadModal = false;
        }
    }

    async handleUploadFinished(event) {
        const uploadedFile = event.detail.files?.[0];
        if (!uploadedFile?.documentId) {
            this.showToast('Upload failed', 'Salesforce did not return the uploaded file Id.', 'error');
            return;
        }

        this.isStartingIntake = true;
        try {
            await acceptApplicationUpload({
                applicationId: this.recordId,
                contentDocumentId: uploadedFile.documentId
            });
            this.showUploadModal = false;
            this.showToast(
                'Document intake started',
                `${uploadedFile.name} will be split, categorized, and reviewed in the background.`,
                'success'
            );
            notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
        } catch (error) {
            this.showToast('Document intake failed', this.reduceError(error), 'error');
        } finally {
            this.isStartingIntake = false;
        }
    }

    async handleCopy() {
        if (!this.hasEmail) return;
        const text = `Subject: ${this.subject}\n\n${this.parsed.body}`;
        try {
            await navigator.clipboard.writeText(text);
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Copied',
                    message: 'Subject and body copied to clipboard.',
                    variant: 'success'
                })
            );
        } catch (e) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Copy failed',
                    message: e.message,
                    variant: 'error'
                })
            );
        }
    }

    handleFlowFinished() {
        notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    reduceError(error) {
        return error?.body?.message || error?.message || 'Unexpected error.';
    }
}

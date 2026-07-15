import { LightningElement, api } from 'lwc';
import LightningConfirm from 'lightning/confirm';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getLaunchState from '@salesforce/apex/AIDocReviewLaunchController.getLaunchState';
import clearReview from '@salesforce/apex/AIDocReviewLaunchController.clearReview';

export default class AiDoc1ReviewButton extends LightningElement {
    @api recordId;
    @api buttonLabel = 'AI Document Review';
    @api buttonVariant = 'brand';
    @api compact = false;

    flowApiName = 'AIDocCoverageReview';
    showFlow = false;
    showCachedReview = false;
    isChecking = false;
    isClearing = false;
    includeFallbackCategory = false;
    cachedReview;

    get flowInputVariables() {
        return [
            { name: 'recordId', type: 'String', value: this.recordId },
            {
                name: 'includeFallbackCategory',
                type: 'Boolean',
                value: this.includeFallbackCategory
            }
        ];
    }

    get isBusy() {
        return this.isChecking || this.isClearing;
    }

    get controlClass() {
        return this.compact ? 'review-controls review-controls_compact' : 'review-controls';
    }

    get reviewButtonLabel() {
        return this.isChecking ? 'Checking Review' : this.buttonLabel;
    }

    get clearButtonLabel() {
        return this.isClearing ? 'Clearing Review' : 'Clear AI Review';
    }

    get showModal() {
        return this.showFlow || this.showCachedReview;
    }

    get cachedCoverageJson() {
        return this.cachedReview?.coverageJson || '';
    }

    get cachedClassificationJson() {
        return this.cachedReview?.classificationJson || '';
    }

    get cachedSanityJson() {
        return this.cachedReview?.sanityJson || '';
    }

    async handleClick() {
        this.isChecking = true;
        try {
            const state = await getLaunchState({
                applicationId: this.recordId,
                includeFallbackCategory: this.includeFallbackCategory
            });
            this.cachedReview = state;
            if (state?.canShowCachedReview) {
                this.showCachedReview = true;
                this.showFlow = false;
            } else {
                this.showCachedReview = false;
                this.showFlow = true;
            }
        } catch (error) {
            this.showToast('AI review unavailable', this.reduceError(error), 'error');
        } finally {
            this.isChecking = false;
        }
    }

    handleIncludeFallbackChange(event) {
        this.includeFallbackCategory = event.target.checked;
    }

    async handleClearReview() {
        const confirmed = await LightningConfirm.open({
            label: 'Clear AI Review',
            message: 'Clear stored AI review results for this application?',
            theme: 'warning'
        });
        if (!confirmed) {
            return;
        }

        this.isClearing = true;
        try {
            const result = await clearReview({ applicationId: this.recordId });
            if (!result?.success) {
                throw new Error(result?.errorMessage || 'AI review could not be cleared.');
            }
            this.cachedReview = null;
            this.showFlow = false;
            this.showCachedReview = false;
            this.showToast(
                'AI review cleared',
                `${result.clearedCount || 0} document categories reset.`,
                'success'
            );
            this.dispatchStatusChange('CLEARED');
        } catch (error) {
            this.showToast('Clear failed', this.reduceError(error), 'error');
        } finally {
            this.isClearing = false;
        }
    }

    handleClose() {
        this.showFlow = false;
        this.showCachedReview = false;
    }

    handleFlowStatusChange(event) {
        const status = event.detail.status;
        if (status === 'FINISHED' || status === 'FINISHED_SCREEN') {
            this.handleClose();
            this.dispatchStatusChange(status);
        }
    }

    dispatchStatusChange(status) {
        // Bubble so a parent component can refresh any review-derived fields.
        this.dispatchEvent(
            new CustomEvent('statuschange', { detail: { status }, bubbles: true })
        );
    }

    showToast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({
                title,
                message,
                variant
            })
        );
    }

    reduceError(error) {
        if (error?.body?.message) {
            return error.body.message;
        }
        if (error?.message) {
            return error.message;
        }
        return 'Unexpected error.';
    }
}

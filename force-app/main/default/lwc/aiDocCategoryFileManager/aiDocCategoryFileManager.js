import { LightningElement, api } from 'lwc';
import LightningConfirm from 'lightning/confirm';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import clearCategoryFileReferences from '@salesforce/apex/AIDocCategoryFileController.clearCategoryFileReferences';

export default class AiDocCategoryFileManager extends LightningElement {
    @api recordId;
    @api buttonLabel = 'Clear Category Files';

    isClearing = false;

    async handleClearFiles() {
        if (!this.recordId) {
            this.showToast('Clear unavailable', 'Application Id is required.', 'error');
            return;
        }

        const confirmed = await LightningConfirm.open({
            label: 'Clear Category Files',
            message: 'Remove category file references for this application? Files are not deleted.',
            theme: 'warning'
        });
        if (!confirmed) {
            return;
        }

        this.isClearing = true;
        try {
            const result = await clearCategoryFileReferences({ applicationId: this.recordId });
            if (!result?.success) {
                throw new Error(result?.errorMessage || 'Category file references could not be cleared.');
            }
            this.showToast(
                'Category files cleared',
                `${result.associationsRemoved || 0} associations and ${result.contentLinksRemoved || 0} file links removed.`,
                'success'
            );
            this.dispatchEvent(new CustomEvent('categoryfilescleared', { bubbles: true }));
        } catch (error) {
            this.showToast('Clear failed', this.reduceError(error), 'error');
        } finally {
            this.isClearing = false;
        }
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

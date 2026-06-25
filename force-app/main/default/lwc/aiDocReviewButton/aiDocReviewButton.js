import { LightningElement, api } from 'lwc';

export default class AiDoc1ReviewButton extends LightningElement {
    @api recordId;
    @api buttonLabel = 'AI Document Review';
    @api buttonVariant = 'brand';

    flowApiName = 'AIDocCoverageReview';
    showFlow = false;

    get flowInputVariables() {
        return [{ name: 'recordId', type: 'String', value: this.recordId }];
    }

    handleClick() {
        this.showFlow = true;
    }

    handleClose() {
        this.showFlow = false;
    }

    handleFlowStatusChange(event) {
        const status = event.detail.status;
        if (status === 'FINISHED' || status === 'FINISHED_SCREEN') {
            this.showFlow = false;
            // Bubble a 'statuschange' event so a parent component can refresh
            // (e.g. re-fetch the Email_Template__c field after the flow writes it).
            this.dispatchEvent(
                new CustomEvent('statuschange', { detail: { status }, bubbles: true })
            );
        }
    }
}

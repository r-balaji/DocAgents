trigger CategoryAttachmentAssociationTrigger on clcommon__Category_Attachment_Association__c (
    after insert,
    after update,
    after delete,
    after undelete
) {
    List<clcommon__Category_Attachment_Association__c> newAssociations =
        Trigger.isDelete ? null : Trigger.new;
    List<clcommon__Category_Attachment_Association__c> oldAssociations =
        (Trigger.isUpdate || Trigger.isDelete) ? Trigger.old : null;

    AIDocReviewResultStore.recalculateForCategoryAttachmentAssociations(
        newAssociations,
        oldAssociations
    );
}

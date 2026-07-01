trigger ContentDocumentLinkTrigger on ContentDocumentLink (
    after insert,
    after delete,
    after undelete
) {
    if (Trigger.isAfter && (Trigger.isInsert || Trigger.isUndelete)) {
        AIDocReviewResultStore.recalculateForContentDocumentLinks(Trigger.new);
    } else if (Trigger.isAfter && Trigger.isDelete) {
        AIDocReviewResultStore.recalculateForContentDocumentLinks(Trigger.old);
    }
}

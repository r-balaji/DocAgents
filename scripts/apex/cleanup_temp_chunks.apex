// One-shot cleanup: delete leftover temp chunk PDFs from previous splitter runs.
//
// The chunks are titled `bundle_chunk_N.pdf` and were uploaded as ContentDocuments
// during pre-classification but never cleaned up because the old code didn't have
// a finalize step. We only delete chunks NOT linked to a currently-running job
// (Status = Queued / Detecting / Merging / Splitting / Saving), so any in-flight
// split keeps its files.

Set<Id> activeJobIds = new Set<Id>();
for (Split_Job__c job : [SELECT Id FROM Split_Job__c
                         WHERE Status__c IN ('Queued', 'Detecting', 'Merging', 'Splitting', 'Saving')]) {
    activeJobIds.add(job.Id);
}

// Find chunk-titled files linked to a running job — skip those.
Set<Id> protectedDocIds = new Set<Id>();
if (!activeJobIds.isEmpty()) {
    for (ContentDocumentLink l : [SELECT ContentDocumentId
                                  FROM ContentDocumentLink
                                  WHERE LinkedEntityId IN :activeJobIds]) {
        protectedDocIds.add(l.ContentDocumentId);
    }
}

List<ContentDocument> chunkDocs = [SELECT Id, Title
                                   FROM ContentDocument
                                   WHERE Title LIKE 'bundle_chunk_%'];

List<ContentDocument> toDelete = new List<ContentDocument>();
for (ContentDocument d : chunkDocs) {
    if (!protectedDocIds.contains(d.Id)) {
        toDelete.add(d);
    }
}

System.debug('Total chunk-titled docs found: ' + chunkDocs.size());
System.debug('Protected (in-flight job): ' + protectedDocIds.size());
System.debug('To delete: ' + toDelete.size());

if (!toDelete.isEmpty()) {
    Database.DeleteResult[] results = Database.delete(toDelete, false);
    Integer successCount = 0;
    Integer errorCount = 0;
    for (Integer i = 0; i < results.size(); i++) {
        if (results[i].isSuccess()) {
            successCount++;
        } else {
            errorCount++;
            System.debug('Delete failed: ' + toDelete[i].Title + ' — ' + results[i].getErrors());
        }
    }
    System.debug('Cleanup complete. Deleted: ' + successCount + ', Failed: ' + errorCount);
}

/**
 * Thin @AuraEnabled controller exposing SplitJobService to the documentSplitter LWC.
 *
 * Each method wraps the underlying service call in AuraHandledException so the LWC
 * gets user-friendly errors and we never leak internal stack traces.
 */
public with sharing class SplitJobController {

    /**
     * Look up the latest ContentVersion Id for a ContentDocument. The LWC uses
     * this to fetch the source PDF binary via getFileContentBase64.
     */
    @AuraEnabled(cacheable=true)
    public static Id getLatestContentVersionId(Id contentDocumentId) {
        try {
            ContentVersion cv = [SELECT Id FROM ContentVersion
                                 WHERE ContentDocumentId = :contentDocumentId
                                   AND IsLatest = true
                                 WITH USER_MODE
                                 LIMIT 1];
            return cv.Id;
        } catch (QueryException e) {
            throw new AuraHandledException('No file found for ContentDocument ' + contentDocumentId);
        } catch (Exception e) {
            throw new AuraHandledException('Could not load file: ' + e.getMessage());
        }
    }

    /**
     * Detect the folder (if any) that contains the source file. Returns the
     * ContentFolder Id, or null if the file lives at the library root. The LWC
     * passes this through to startJob so the save Queueable can drop the splits
     * into the same folder as the source.
     */
    @AuraEnabled(cacheable=true)
    public static Id getFolderIdForFile(Id sourceContentDocumentId) {
        if (sourceContentDocumentId == null) {
            return null;
        }
        try {
            List<ContentFolderMember> memberships = [
                SELECT ParentContentFolderId
                FROM ContentFolderMember
                WHERE ChildRecordId = :sourceContentDocumentId
                WITH USER_MODE
                LIMIT 1
            ];
            return memberships.isEmpty() ? null : memberships[0].ParentContentFolderId;
        } catch (Exception e) {
            // Folder detection is best-effort — if it fails, fall back to root.
            return null;
        }
    }

    /**
     * Auto-detect which library (ContentWorkspace) the source file lives in.
     * Used by the LWC so the user doesn't have to configure a library Id —
     * splits are saved back to the same library as the source bundle.
     *
     * Falls back to any library the running user can write to if the source
     * isn't directly linked to a library (e.g., it was attached to a record
     * via Files Connect rather than uploaded to a library).
     *
     * Throws AuraHandledException if no writable library can be found.
     */
    @AuraEnabled(cacheable=true)
    public static Id getLibraryIdForFile(Id sourceContentDocumentId) {
        if (sourceContentDocumentId == null) {
            throw new AuraHandledException('sourceContentDocumentId is required.');
        }
        try {
            // First choice: the library the source file is directly published to.
            List<ContentWorkspaceDoc> directMembership = [
                SELECT ContentWorkspaceId
                FROM ContentWorkspaceDoc
                WHERE ContentDocumentId = :sourceContentDocumentId
                WITH USER_MODE
                LIMIT 1
            ];
            if (!directMembership.isEmpty()) {
                return directMembership[0].ContentWorkspaceId;
            }

            // Fallback: any library the current user is a member of (with add-content rights).
            List<ContentWorkspaceMember> memberships = [
                SELECT ContentWorkspaceId
                FROM ContentWorkspaceMember
                WHERE MemberId = :UserInfo.getUserId()
                WITH USER_MODE
                LIMIT 1
            ];
            if (!memberships.isEmpty()) {
                return memberships[0].ContentWorkspaceId;
            }

            throw new AuraHandledException(
                'No library found for this file. Add the file to a Library, or have an admin grant you access to one.');
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Could not determine target library: ' + e.getMessage());
        }
    }

    /**
     * Return the binary content of a ContentVersion as a base64-encoded string.
     *
     * Used by the LWC to fetch the source PDF without hitting CSP/CORS issues
     * that block direct fetch() to the file servlet from the lightning.force.com
     * iframe.
     *
     * Practical file-size limit: ~8 MB raw (12 MB base64 fits the 12 MB async
     * Apex heap with room for overhead). For larger files we'd need a streaming
     * download approach (CSP Trusted Site + fetch, or REST API with range
     * headers). Most loan-doc bundles fall under this limit.
     */
    @AuraEnabled
    public static String getFileContentBase64(Id contentVersionId) {
        if (contentVersionId == null) {
            throw new AuraHandledException('contentVersionId is required.');
        }
        try {
            ContentVersion cv = [SELECT VersionData FROM ContentVersion
                                 WHERE Id = :contentVersionId
                                 WITH USER_MODE
                                 LIMIT 1];
            if (cv.VersionData == null) {
                throw new AuraHandledException('File has no content.');
            }
            return EncodingUtil.base64Encode(cv.VersionData);
        } catch (QueryException e) {
            throw new AuraHandledException('File not found or not accessible.');
        } catch (Exception e) {
            throw new AuraHandledException('Could not read file: ' + e.getMessage());
        }
    }

    /**
     * Upload a chunk PDF (base64) back to Salesforce as a temporary ContentVersion.
     * The LWC slices the source bundle in-browser and calls this once per chunk.
     * Returns the chunk's new ContentDocumentId, which the LWC passes back in
     * enqueueChunkClassification so the AI prompt has a file to read from.
     *
     * The library Id is stored on the resulting ContentVersion so the chunk is
     * visible to the splitter pipeline, but the LWC could also choose to upload
     * to a per-job workspace if isolation matters later.
     */
    @AuraEnabled
    public static Id uploadChunkPdf(String fileName, String base64Content, Id libraryId) {
        if (String.isBlank(fileName)) {
            throw new AuraHandledException('fileName is required.');
        }
        if (String.isBlank(base64Content)) {
            throw new AuraHandledException('base64Content is required.');
        }
        if (libraryId == null) {
            throw new AuraHandledException('libraryId is required.');
        }
        try {
            ContentVersion cv = new ContentVersion(
                Title = fileName,
                PathOnClient = fileName,
                VersionData = EncodingUtil.base64Decode(base64Content),
                FirstPublishLocationId = libraryId
            );
            Database.insert(cv, AccessLevel.USER_MODE);
            ContentVersion saved = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id WITH USER_MODE LIMIT 1];
            return saved.ContentDocumentId;
        } catch (Exception e) {
            throw new AuraHandledException('Chunk upload failed: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static Id startJob(Id sourceContentDocumentId, Id libraryId, Id folderId, Integer totalPages, Integer chunkCount) {
        try {
            return SplitJobService.startJob(sourceContentDocumentId, libraryId, folderId, totalPages, chunkCount);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static void enqueueChunkClassification(Id jobId, Integer chunkIndex, Id chunkContentDocumentId, Integer pageOffset) {
        try {
            SplitJobService.enqueueChunkClassification(jobId, chunkIndex, chunkContentDocumentId, pageOffset);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * Kick off the save phase. The LWC passes a JSON-serialized List<SplitSaveRequest>
     * built from pdf-lib's split output. Returns immediately after enqueueing the first
     * SplitSaveQueueable; progress comes back via Split_Job_Update__e events.
     */
    @AuraEnabled
    public static void startSaving(Id jobId, String requestsJson, Integer batchSize) {
        try {
            List<SplitSaveRequest> requests = parseSaveRequests(requestsJson);
            SplitJobService.startSaving(jobId, requests, batchSize);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * Return the split files produced by a job, plus their library membership
     * so the studio LWC can render them in a results table.
     *
     * "Split files" = ContentDocuments saved to the same library as the source,
     * created on or after the job's start time, with titles starting with the
     * job's first batch run. Identifying them precisely without an explicit
     * link table is heuristic — we filter to ContentDocuments in the job's
     * library with CreatedDate >= the job's CreatedDate and exclude the source.
     */
    @AuraEnabled(cacheable=false)
    public static List<JobOutputFile> getJobOutputFiles(Id jobId) {
        if (jobId == null) {
            throw new AuraHandledException('jobId is required.');
        }
        try {
            // The save Queueable creates ContentDocumentLink records with
            // LinkedEntityId = jobId for every output file. Querying that gives
            // us a reliable, exact list (not a time-based heuristic that can
            // miss files or include unrelated ones).
            List<ContentDocumentLink> links = [SELECT ContentDocumentId
                                               FROM ContentDocumentLink
                                               WHERE LinkedEntityId = :jobId
                                               WITH USER_MODE];
            Set<Id> docIds = new Set<Id>();
            for (ContentDocumentLink link : links) {
                docIds.add(link.ContentDocumentId);
            }
            if (docIds.isEmpty()) {
                return new List<JobOutputFile>();
            }

            List<ContentDocument> docs = [SELECT Id, Title, ContentSize, FileType,
                                                 LatestPublishedVersionId, CreatedDate
                                          FROM ContentDocument
                                          WHERE Id IN :docIds
                                          WITH USER_MODE
                                          ORDER BY CreatedDate DESC];

            List<JobOutputFile> out = new List<JobOutputFile>();
            for (ContentDocument d : docs) {
                JobOutputFile f = new JobOutputFile();
                f.id = d.Id;
                f.title = d.Title;
                f.fileType = d.FileType;
                f.size = d.ContentSize;
                f.latestVersionId = d.LatestPublishedVersionId;
                f.createdDate = d.CreatedDate;
                out.add(f);
            }
            return out;
        } catch (Exception e) {
            throw new AuraHandledException('Could not load output files: ' + e.getMessage());
        }
    }

    /**
     * Delete a set of ContentDocuments. Safety: refuses to delete any Id that
     * matches the protectedSourceId argument (so the source bundle is never
     * accidentally wiped by a "Delete All Splits" button).
     */
    @AuraEnabled
    public static Integer deleteFiles(List<Id> contentDocumentIds, Id protectedSourceId) {
        if (contentDocumentIds == null || contentDocumentIds.isEmpty()) {
            return 0;
        }
        try {
            List<ContentDocument> toDelete = new List<ContentDocument>();
            for (Id cdId : contentDocumentIds) {
                if (cdId == null || cdId == protectedSourceId) {
                    continue;
                }
                toDelete.add(new ContentDocument(Id = cdId));
            }
            if (toDelete.isEmpty()) {
                return 0;
            }
            Database.delete(toDelete, AccessLevel.USER_MODE);
            return toDelete.size();
        } catch (Exception e) {
            throw new AuraHandledException('Delete failed: ' + e.getMessage());
        }
    }

    /**
     * Search for files the running user has access to. Used by the studio LWC's
     * file picker. Returns a small page of the most-recently-modified PDF files
     * matching the search term.
     */
    @AuraEnabled(cacheable=true)
    public static List<JobOutputFile> searchFiles(String searchTerm) {
        try {
            String pattern = String.isBlank(searchTerm) ? '%' : '%' + searchTerm + '%';
            List<ContentDocument> docs = [SELECT Id, Title, FileType, ContentSize,
                                                 LatestPublishedVersionId, CreatedDate
                                          FROM ContentDocument
                                          WHERE Title LIKE :pattern
                                            AND FileType = 'PDF'
                                          WITH USER_MODE
                                          ORDER BY CreatedDate DESC
                                          LIMIT 20];
            List<JobOutputFile> out = new List<JobOutputFile>();
            for (ContentDocument d : docs) {
                JobOutputFile f = new JobOutputFile();
                f.id = d.Id;
                f.title = d.Title;
                f.fileType = d.FileType;
                f.size = d.ContentSize;
                f.latestVersionId = d.LatestPublishedVersionId;
                f.createdDate = d.CreatedDate;
                out.add(f);
            }
            return out;
        } catch (Exception e) {
            throw new AuraHandledException('Search failed: ' + e.getMessage());
        }
    }

    /**
     * DTO returned by getJobOutputFiles and searchFiles. Public + AuraEnabled
     * so it serializes correctly to the LWC.
     */
    public class JobOutputFile {
        @AuraEnabled public Id id;
        @AuraEnabled public String title;
        @AuraEnabled public String fileType;
        @AuraEnabled public Integer size;
        @AuraEnabled public Id latestVersionId;
        @AuraEnabled public Datetime createdDate;
    }

    @TestVisible
    private static List<SplitSaveRequest> parseSaveRequests(String requestsJson) {
        if (String.isBlank(requestsJson)) {
            return new List<SplitSaveRequest>();
        }
        return (List<SplitSaveRequest>) JSON.deserialize(requestsJson, List<SplitSaveRequest>.class);
    }
}

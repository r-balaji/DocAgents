/**
 * Maps split output files to existing application document categories with an LLM prompt.
 */
@SuppressWarnings('PMD.CognitiveComplexity,PMD.CyclomaticComplexity,PMD.NcssCount,PMD.ExcessiveParameterList')
public with sharing class AIDocIntakeCategoryMappingService {
    @TestVisible
    private static final String MAPPING_FLOW_NAME = 'AIDocIntakeCategoryMap';

    private static final String FALLBACK_DOCUMENT_TYPE = 'OTHER';
    private static final String DEFAULT_FALLBACK_PARENT_NAME = 'Uncategorized';
    private static final String DEFAULT_FALLBACK_CHILD_NAME = 'Others';
    private static final String APPLICATION_DOCUMENTS_ROOT_NAME = 'Application Documents';

    @TestVisible
    private static String testStubMappingResponse;

    /**
     * Maps and places all output files linked to a completed split job.
     * @param splitJobId Split job that produced output ContentDocuments.
     */
    public static void mapSplitOutputs(Id splitJobId) {
        if (splitJobId == null) {
            return;
        }

        MappingWork work = loadMappingWork(splitJobId);
        if (work.fileItems.isEmpty()) {
            return;
        }

        try {
            List<OutputFile> outputFiles = loadOutputFiles(work);
            if (outputFiles.isEmpty()) {
                completeWithSourceFallback(work, 'No split output files were available for category mapping.');
                return;
            }

            ensureFallbackCategoryIfConfigured(work);
            List<CategoryCandidate> candidates = loadCategoryCandidates(work.applicationId);
            List<PartyCandidate> parties = loadApplicationParties(work.applicationId);
            String filesJson = JSON.serialize(outputFiles);
            String categoriesJson = JSON.serialize(new Map<String, Object>{
                'categories' => candidates,
                'parties' => parties
            });
            String promptError;
            String rawMappingJson;
            try {
                rawMappingJson = invokeMappingFlow(filesJson, categoriesJson);
            } catch (Exception e) {
                promptError = e.getTypeName() + ': ' + e.getMessage();
                rawMappingJson = null;
            }

            Map<Id, MappingDecision> decisionsByContentDocumentId =
                parseValidatedMappings(rawMappingJson, outputFiles, candidates);
            completeWithOutputPlacement(work, outputFiles, candidates, decisionsByContentDocumentId, rawMappingJson, promptError);
        } catch (Exception e) {
            failMapping(work, e.getTypeName() + ': ' + e.getMessage());
        }
    }

    @TestVisible
    private static String invokeMappingFlow(String filesJson, String categoriesJson) {
        if (Test.isRunningTest() && testStubMappingResponse != null) {
            return testStubMappingResponse;
        }
        Map<String, Object> inputs = new Map<String, Object>{
            'filesJson' => filesJson,
            'categoriesJson' => categoriesJson
        };
        Flow.Interview interview = Flow.Interview.createInterview(MAPPING_FLOW_NAME, inputs);
        interview.start();
        String response = (String) interview.getVariableValue('mappingJson');
        return response == null ? '' : response;
    }

    private static MappingWork loadMappingWork(Id splitJobId) {
        MappingWork work = new MappingWork();
        work.splitJob = [
            SELECT Id, Source_ContentDocument_Id__c, Documents_Created__c, Merged_Segments_JSON__c
            FROM Split_Job__c
            WHERE Id = :splitJobId
            WITH USER_MODE
            LIMIT 1
        ];
        work.fileItems = [
            SELECT Id, Intake_Job__c, Intake_Job__r.Application__c, Intake_Job__r.Source__c,
                   ContentDocument_Id__c
            FROM Document_Intake_File__c
            WHERE Split_Job__c = :splitJobId
            WITH USER_MODE
        ];
        if (!work.fileItems.isEmpty()) {
            Document_Intake_File__c first = work.fileItems[0];
            work.applicationId = first.Intake_Job__r.Application__c;
            work.source = first.Intake_Job__r.Source__c;
            for (Document_Intake_File__c fileItem : work.fileItems) {
                work.intakeJobIds.add(fileItem.Intake_Job__c);
            }
        }
        return work;
    }

    private static List<OutputFile> loadOutputFiles(MappingWork work) {
        Map<Id, OutputFile> filesByContentDocumentId = new Map<Id, OutputFile>();
        Map<String, OutputSegment> segmentsByFileName =
            outputSegmentsByFileName(work.splitJob.Merged_Segments_JSON__c);
        Id sourceFileItemId = work.fileItems.isEmpty() ? null : work.fileItems[0].Id;
        Id splitJobId = work.splitJob.Id;
        for (ContentDocumentLink link : [
            SELECT ContentDocumentId, ContentDocument.Title, ContentDocument.FileExtension
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :splitJobId
            WITH USER_MODE
            ORDER BY Id ASC
        ]) {
            if (filesByContentDocumentId.containsKey(link.ContentDocumentId)) {
                continue;
            }
            OutputFile file = new OutputFile();
            file.fileItemId = sourceFileItemId;
            file.contentDocumentId = link.ContentDocumentId;
            file.fileName = fileNameFromDocument(link.ContentDocument.Title, link.ContentDocument.FileExtension);
            enrichOutputFile(file, segmentsByFileName.get(fileNameKey(file.fileName)));
            filesByContentDocumentId.put(file.contentDocumentId, file);
        }
        return filesByContentDocumentId.values();
    }

    private static String fileNameFromDocument(String title, String extension) {
        String safeTitle = String.isBlank(title) ? 'Untitled' : title;
        if (String.isBlank(extension)) {
            return safeTitle;
        }
        return safeTitle + '.' + extension;
    }

    private static void enrichOutputFile(OutputFile file, OutputSegment segment) {
        if (file == null || segment == null) {
            return;
        }
        file.documentType = segment.documentType;
        file.sourceInstitution = segment.sourceInstitution;
        file.namedParty = segment.namedParty;
        file.instanceLabel = segment.instanceLabel;
        file.pages = segment.pages;
    }

    private static Map<String, OutputSegment> outputSegmentsByFileName(String mergedJson) {
        Map<String, OutputSegment> segmentsByFileName = new Map<String, OutputSegment>();
        if (String.isBlank(mergedJson)) {
            return segmentsByFileName;
        }
        try {
            for (PdfServiceClient.SegmentInput segment : PdfServiceSplitQueueable.buildSegmentInputs(mergedJson)) {
                if (segment == null || String.isBlank(segment.fileName)) {
                    continue;
                }
                OutputSegment output = new OutputSegment();
                output.documentType = segment.documentType;
                output.sourceInstitution = segment.sourceInstitution;
                output.namedParty = segment.namedParty;
                output.instanceLabel = segment.instanceLabel;
                output.pages = segment.pages;
                segmentsByFileName.put(fileNameKey(segment.fileName), output);
            }
        } catch (Exception e) {
            return new Map<String, OutputSegment>();
        }
        return segmentsByFileName;
    }

    private static String fileNameKey(String fileName) {
        return String.isBlank(fileName) ? '' : fileName.trim().toLowerCase();
    }

    private static List<CategoryCandidate> loadCategoryCandidates(Id applicationId) {
        List<clcommon__Document_Category__c> categories = [
            SELECT Id, clcommon__Category_Name__c, clcommon__Parent_Document_Category__c,
                   clcommon__Account__c, clcommon__Document_Definition__r.Name
            FROM clcommon__Document_Category__c
            WHERE genesis__Application__c = :applicationId
            WITH USER_MODE
            ORDER BY CreatedDate ASC
        ];

        Map<Id, clcommon__Document_Category__c> categoriesById =
            new Map<Id, clcommon__Document_Category__c>(categories);
        AIDocReviewPartyResolver.PartyIndex partyIndex =
            AIDocReviewPartyResolver.load(new Set<Id>{ applicationId });
        Set<Id> parentIds = new Set<Id>();
        for (clcommon__Document_Category__c category : categories) {
            if (category.clcommon__Parent_Document_Category__c != null) {
                parentIds.add(category.clcommon__Parent_Document_Category__c);
            }
        }

        List<CategoryCandidate> candidates = new List<CategoryCandidate>();
        for (clcommon__Document_Category__c category : categories) {
            if (parentIds.contains(category.Id)) {
                continue;
            }
            CategoryCandidate candidate = new CategoryCandidate();
            clcommon__Document_Category__c root = findRootCategory(category, categoriesById);
            AIDocReviewPartyResolver.PartyContext party =
                AIDocReviewPartyResolver.resolvePartyForCategory(
                    category,
                    categoriesById,
                    partyIndex.partyByAccountId
                );
            candidate.documentCategoryId = category.Id;
            candidate.categoryName = category.clcommon__Category_Name__c;
            candidate.categoryPath = buildCategoryPath(category, categoriesById);
            candidate.rootCategoryName = root == null ? null : root.clcommon__Category_Name__c;
            candidate.parentCategoryName = parentCategoryName(category, categoriesById);
            candidate.partyName = party.partyName;
            candidate.partyType = party.partyType;
            candidate.scope = categoryScope(candidate);
            candidate.isApplicationLevel = candidate.scope == 'APPLICATION';
            candidate.isFallback = candidate.scope == 'FALLBACK';
            candidate.documentDefinitionName = category.clcommon__Document_Definition__r == null
                ? null
                : category.clcommon__Document_Definition__r.Name;
            candidates.add(candidate);
        }
        return candidates;
    }

    private static List<PartyCandidate> loadApplicationParties(Id applicationId) {
        List<PartyCandidate> parties = new List<PartyCandidate>();
        if (applicationId == null) {
            return parties;
        }

        AIDocReviewPartyResolver.PartyIndex partyIndex =
            AIDocReviewPartyResolver.load(new Set<Id>{ applicationId });
        Set<String> includedKeys = new Set<String>();
        for (Id accountId : partyIndex.partyByAccountId.keySet()) {
            AIDocReviewPartyResolver.PartyContext ctx = partyIndex.partyByAccountId.get(accountId);
            PartyCandidate party = partyCandidate(accountId, ctx.partyName, ctx.partyType);
            if (includeParty(parties, includedKeys, party)) {
                continue;
            }
        }

        Map<String, List<String>> partiesByType = partyIndex.partiesByApp.get(applicationId);
        if (partiesByType == null) {
            return parties;
        }
        List<String> partyTypes = new List<String>(partiesByType.keySet());
        partyTypes.sort();
        for (String partyType : partyTypes) {
            List<String> partyNames = partiesByType.get(partyType);
            if (partyNames == null) {
                continue;
            }
            partyNames.sort();
            for (String partyName : partyNames) {
                includeParty(parties, includedKeys, partyCandidate(null, partyName, partyType));
            }
        }
        return parties;
    }

    private static PartyCandidate partyCandidate(Id accountId, String partyName, String partyType) {
        PartyCandidate party = new PartyCandidate();
        party.accountId = accountId;
        party.partyName = partyName;
        party.partyType = String.isBlank(partyType) ? 'UNSPECIFIED' : partyType;
        return party;
    }

    private static Boolean includeParty(
        List<PartyCandidate> parties,
        Set<String> includedKeys,
        PartyCandidate party
    ) {
        if (party == null || String.isBlank(party.partyName)) {
            return false;
        }
        String key = fileNameKey(party.partyName) + '|' + fileNameKey(party.partyType);
        if (includedKeys.contains(key)) {
            return true;
        }
        includedKeys.add(key);
        parties.add(party);
        return true;
    }

    private static String parentCategoryName(
        clcommon__Document_Category__c category,
        Map<Id, clcommon__Document_Category__c> categoriesById
    ) {
        if (category.clcommon__Parent_Document_Category__c == null) {
            return null;
        }
        clcommon__Document_Category__c parent =
            categoriesById.get(category.clcommon__Parent_Document_Category__c);
        return parent == null ? null : parent.clcommon__Category_Name__c;
    }

    private static clcommon__Document_Category__c findRootCategory(
        clcommon__Document_Category__c category,
        Map<Id, clcommon__Document_Category__c> categoriesById
    ) {
        clcommon__Document_Category__c current = category;
        Integer guard = 0;
        while (current != null && current.clcommon__Parent_Document_Category__c != null && guard < 20) {
            current = categoriesById.get(current.clcommon__Parent_Document_Category__c);
            guard++;
        }
        return current;
    }

    private static String categoryScope(CategoryCandidate candidate) {
        if (sameText(candidate.rootCategoryName, APPLICATION_DOCUMENTS_ROOT_NAME)) {
            return 'APPLICATION';
        }
        if (sameText(candidate.rootCategoryName, DEFAULT_FALLBACK_PARENT_NAME)
            || (sameText(candidate.parentCategoryName, DEFAULT_FALLBACK_PARENT_NAME)
                && sameText(candidate.categoryName, DEFAULT_FALLBACK_CHILD_NAME))) {
            return 'FALLBACK';
        }
        if (String.isNotBlank(candidate.partyName)) {
            return 'PARTY';
        }
        return 'CATEGORY_TREE';
    }

    private static Boolean sameText(String left, String right) {
        return left != null && right != null && left.trim().equalsIgnoreCase(right.trim());
    }

    private static String buildCategoryPath(
        clcommon__Document_Category__c category,
        Map<Id, clcommon__Document_Category__c> categoriesById
    ) {
        List<String> pathParts = new List<String>();
        Set<Id> visited = new Set<Id>();
        clcommon__Document_Category__c current = category;
        while (current != null && !visited.contains(current.Id)) {
            visited.add(current.Id);
            if (!String.isBlank(current.clcommon__Category_Name__c)) {
                pathParts.add(current.clcommon__Category_Name__c);
            }
            current = current.clcommon__Parent_Document_Category__c == null
                ? null
                : categoriesById.get(current.clcommon__Parent_Document_Category__c);
        }

        List<String> ordered = new List<String>();
        for (Integer i = pathParts.size() - 1; i >= 0; i--) {
            ordered.add(pathParts[i]);
        }
        return String.join(ordered, ' > ');
    }

    private static Map<Id, MappingDecision> parseValidatedMappings(
        String rawMappingJson,
        List<OutputFile> outputFiles,
        List<CategoryCandidate> candidates
    ) {
        Map<Id, OutputFile> outputFilesById = new Map<Id, OutputFile>();
        for (OutputFile file : outputFiles) {
            outputFilesById.put(file.contentDocumentId, file);
        }

        Map<Id, CategoryCandidate> candidatesById = new Map<Id, CategoryCandidate>();
        for (CategoryCandidate candidate : candidates) {
            candidatesById.put(candidate.documentCategoryId, candidate);
        }

        Map<Id, MappingDecision> decisionsByContentDocumentId = new Map<Id, MappingDecision>();
        if (String.isBlank(rawMappingJson)) {
            return decisionsByContentDocumentId;
        }

        Object parsed = JSON.deserializeUntyped(cleanJson(rawMappingJson));
        List<Object> rows = mappingRows(parsed);
        for (Object rowObj : rows) {
            if (!(rowObj instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> row = (Map<String, Object>) rowObj;
            Id contentDocumentId = idFrom(row.get('contentDocumentId'));
            if (contentDocumentId == null
                || !outputFilesById.containsKey(contentDocumentId)) {
                continue;
            }

            List<Id> categoryIds = validCategoryIds(row, candidatesById);
            if (categoryIds.isEmpty()) {
                continue;
            }

            MappingDecision decision = new MappingDecision();
            decision.contentDocumentId = contentDocumentId;
            decision.documentCategoryIds.addAll(categoryIds);
            decision.documentCategoryId = categoryIds[0];
            for (Id categoryId : categoryIds) {
                decision.categoryNames.add(candidatesById.get(categoryId).categoryName);
            }
            decision.categoryName = String.join(decision.categoryNames, '; ');
            decision.confidence = confidenceFrom(row.get('confidence'));
            decision.reason = stringFrom(row.get('reason'));
            decision.matchedParties.addAll(stringListFrom(row.get('matchedParties')));
            decisionsByContentDocumentId.put(contentDocumentId, decision);
        }
        return decisionsByContentDocumentId;
    }

    private static List<Id> validCategoryIds(
        Map<String, Object> row,
        Map<Id, CategoryCandidate> candidatesById
    ) {
        List<Id> ids = categoryIdsFrom(row);
        List<Id> validIds = new List<Id>();
        Set<Id> seen = new Set<Id>();
        for (Id categoryId : ids) {
            if (categoryId == null || seen.contains(categoryId) || !candidatesById.containsKey(categoryId)) {
                continue;
            }
            if (!isAllowedPromptCategory(row, candidatesById.get(categoryId))) {
                continue;
            }
            seen.add(categoryId);
            validIds.add(categoryId);
        }
        return validIds;
    }

    private static Boolean isAllowedPromptCategory(Map<String, Object> row, CategoryCandidate candidate) {
        if (candidate == null) {
            return false;
        }
        if (candidate.isFallback == true) {
            return true;
        }

        String routingClass = stringFrom(row.get('routingClass'));
        if ((sameText(routingClass, 'PARTY_OWNED') || sameText(routingClass, 'UNKNOWN'))
            && candidate.isApplicationLevel == true) {
            return false;
        }

        if (candidate.scope == 'PARTY') {
            String matchedOfficialParty = stringFrom(row.get('matchedOfficialParty'));
            return String.isNotBlank(matchedOfficialParty)
                && sameText(matchedOfficialParty, candidate.partyName);
        }

        return true;
    }

    private static List<Id> categoryIdsFrom(Map<String, Object> row) {
        List<Object> rawValues = new List<Object>();
        addCategoryIdValues(rawValues, row.get('targetCategoryIds'));
        addCategoryIdValues(rawValues, row.get('documentCategoryIds'));
        addCategoryIdValues(rawValues, row.get('targetCategoryId'));
        addCategoryIdValues(rawValues, row.get('documentCategoryId'));

        List<Id> ids = new List<Id>();
        for (Object value : rawValues) {
            Id categoryId = idFrom(value);
            if (categoryId != null) {
                ids.add(categoryId);
            }
        }
        return ids;
    }

    private static void addCategoryIdValues(List<Object> values, Object rawValue) {
        if (rawValue == null) {
            return;
        }
        if (rawValue instanceof List<Object>) {
            values.addAll((List<Object>) rawValue);
            return;
        }
        values.add(rawValue);
    }

    private static String cleanJson(String rawJson) {
        String cleaned = rawJson.trim();
        if (cleaned.startsWith('```')) {
            Integer objectStart = cleaned.indexOf('{');
            Integer objectEnd = cleaned.lastIndexOf('}');
            Integer arrayStart = cleaned.indexOf('[');
            Integer arrayEnd = cleaned.lastIndexOf(']');
            if (objectStart >= 0 && objectEnd > objectStart) {
                return cleaned.substring(objectStart, objectEnd + 1);
            }
            if (arrayStart >= 0 && arrayEnd > arrayStart) {
                return cleaned.substring(arrayStart, arrayEnd + 1);
            }
        }
        return cleaned;
    }

    private static List<Object> mappingRows(Object parsed) {
        if (parsed instanceof List<Object>) {
            return (List<Object>) parsed;
        }
        if (parsed instanceof Map<String, Object>) {
            Object mappings = ((Map<String, Object>) parsed).get('mappings');
            if (mappings instanceof List<Object>) {
                return (List<Object>) mappings;
            }
        }
        return new List<Object>();
    }

    private static void completeWithOutputPlacement(
        MappingWork work,
        List<OutputFile> outputFiles,
        List<CategoryCandidate> candidates,
        Map<Id, MappingDecision> decisionsByContentDocumentId,
        String rawMappingJson,
        String promptError
    ) {
        Id fallbackCategoryId;
        Integer fallbackCount = 0;
        List<MappingDecision> applied = new List<MappingDecision>();
        Map<Id, Set<Id>> categoryIdsByContentDocumentId = new Map<Id, Set<Id>>();
        for (OutputFile file : outputFiles) {
            MappingDecision decision = decisionsByContentDocumentId.get(file.contentDocumentId);
            if (decision == null) {
                fallbackCategoryId = fallbackCategoryId == null
                    ? ensureFallbackCategory(work)
                    : fallbackCategoryId;
                decision = fallbackDecision(file, fallbackCategoryId);
                fallbackCount++;
            }
            categoryIdsByContentDocumentId.put(
                file.contentDocumentId,
                new Set<Id>(decision.documentCategoryIds)
            );
            applied.add(decision);
        }
        AIDocIntakeCategoryService.attachDocumentsToCategories(categoryIdsByContentDocumentId);

        String detail = 'Mapped ' + outputFiles.size() + ' split output file(s) to application document categories.';
        if (fallbackCount > 0) {
            detail += ' Placed ' + fallbackCount + ' file(s) in fallback category.';
        }
        if (!String.isBlank(promptError)) {
            detail += ' Mapping prompt failed; fallback was used where needed.';
        }
        completeFileItems(work, applied, rawMappingJson, promptError, detail);
    }

    private static void completeWithSourceFallback(MappingWork work, String detail) {
        if (String.isBlank(work.splitJob.Source_ContentDocument_Id__c)) {
            failMapping(work, 'Split completed without output files and no source file was available.');
            return;
        }

        Id fallbackCategoryId = ensureFallbackCategory(work);
        Id sourceContentDocumentId = (Id) work.splitJob.Source_ContentDocument_Id__c;
        AIDocIntakeCategoryService.attachDocumentToCategory(fallbackCategoryId, sourceContentDocumentId);

        MappingDecision decision = fallbackDecision(sourceContentDocumentId, fallbackCategoryId);
        completeFileItems(
            work,
            new List<MappingDecision>{ decision },
            null,
            null,
            detail + ' Source file was placed in fallback category.'
        );
    }

    private static Id ensureFallbackCategory(MappingWork work) {
        FallbackConfig config = fallbackConfig(work.source);
        if (config.createFallback != true) {
            throw new SplitJobException('Document intake fallback category creation is disabled.');
        }
        return AIDocIntakeCategoryService.ensureFallbackCategory(
            work.applicationId,
            config.parentCategoryName,
            config.childCategoryName
        );
    }

    private static Id ensureFallbackCategoryIfConfigured(MappingWork work) {
        FallbackConfig config = fallbackConfig(work.source);
        if (config.createFallback != true) {
            return null;
        }
        return AIDocIntakeCategoryService.ensureFallbackCategory(
            work.applicationId,
            config.parentCategoryName,
            config.childCategoryName
        );
    }

    private static FallbackConfig fallbackConfig(String source) {
        Document_Intake_Config__mdt config = activeConfigForSource(source);
        FallbackConfig result = new FallbackConfig();
        result.createFallback = true;
        result.parentCategoryName = DEFAULT_FALLBACK_PARENT_NAME;
        result.childCategoryName = DEFAULT_FALLBACK_CHILD_NAME;
        if (config == null) {
            return result;
        }
        result.createFallback = config.Create_Others_Category__c == true;
        result.parentCategoryName = String.isBlank(config.Fallback_Parent_Category_Name__c)
            ? DEFAULT_FALLBACK_PARENT_NAME
            : config.Fallback_Parent_Category_Name__c;
        result.childCategoryName = String.isBlank(config.Default_Category_Name__c)
            ? DEFAULT_FALLBACK_CHILD_NAME
            : config.Default_Category_Name__c;
        return result;
    }

    private static Document_Intake_Config__mdt activeConfigForSource(String source) {
        String normalizedSource = String.isBlank(source) ? 'PORTAL' : source;
        Document_Intake_Config__mdt fallback;
        for (Document_Intake_Config__mdt config : Document_Intake_Config__mdt.getAll().values()) {
            if (config.Is_Active__c != true) {
                continue;
            }
            if (config.Source__c == normalizedSource) {
                return config;
            }
            if (fallback == null && config.Source__c == 'PORTAL') {
                fallback = config;
            }
        }
        return fallback;
    }

    private static MappingDecision fallbackDecision(OutputFile file, Id fallbackCategoryId) {
        return fallbackDecision(file.contentDocumentId, fallbackCategoryId);
    }

    private static MappingDecision fallbackDecision(Id contentDocumentId, Id fallbackCategoryId) {
        MappingDecision decision = new MappingDecision();
        decision.contentDocumentId = contentDocumentId;
        decision.documentCategoryId = fallbackCategoryId;
        decision.documentCategoryIds.add(fallbackCategoryId);
        decision.categoryName = FALLBACK_DOCUMENT_TYPE;
        decision.categoryNames.add(FALLBACK_DOCUMENT_TYPE);
        decision.confidence = 0;
        decision.reason = 'No valid LLM category mapping was returned.';
        return decision;
    }

    private static void completeFileItems(
        MappingWork work,
        List<MappingDecision> applied,
        String rawMappingJson,
        String promptError,
        String detail
    ) {
        String auditJson = buildAuditJson(applied, rawMappingJson, promptError);
        List<Document_Intake_File__c> updates = new List<Document_Intake_File__c>();
        for (Document_Intake_File__c fileItem : work.fileItems) {
            Document_Intake_File__c updateRecord = new Document_Intake_File__c(
                Id = fileItem.Id,
                Status__c = AIDocIntakeService.FILE_STATUS_REVIEWING,
                Split_Result_JSON__c = auditJson.left(32768),
                Error_Detail__c = detail.left(32768)
            );
            if (applied.size() == 1) {
                MappingDecision only = applied[0];
                updateRecord.Document_Category__c = only.documentCategoryId;
                updateRecord.Document_Type__c = String.isBlank(only.categoryName)
                    ? FALLBACK_DOCUMENT_TYPE
                    : only.categoryName.left(100);
                updateRecord.Mapping_Confidence__c = confidencePercent(only.confidence);
            } else {
                updateRecord.Document_Type__c = 'SPLIT_OUTPUTS';
            }
            updates.add(updateRecord);
        }
        Database.update(updates, false, AccessLevel.USER_MODE);
        AIDocIntakeService.recalculateIntakeStatuses(work.intakeJobIds);
        if (!Test.isRunningTest()) {
            AIDocIntakeReviewService.enqueueReview(work.intakeJobIds);
        }
    }

    private static void failMapping(MappingWork work, String errorDetail) {
        if (work == null || work.fileItems.isEmpty()) {
            return;
        }
        List<Document_Intake_File__c> updates = new List<Document_Intake_File__c>();
        for (Document_Intake_File__c fileItem : work.fileItems) {
            updates.add(new Document_Intake_File__c(
                Id = fileItem.Id,
                Status__c = AIDocIntakeService.FILE_STATUS_FAILED,
                Error_Detail__c = String.isBlank(errorDetail) ? null : errorDetail.left(32768)
            ));
        }
        Database.update(updates, false, AccessLevel.USER_MODE);
        AIDocIntakeService.recalculateIntakeStatuses(work.intakeJobIds);
    }

    private static String buildAuditJson(List<MappingDecision> applied, String rawMappingJson, String promptError) {
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        for (MappingDecision decision : applied) {
            rows.add(new Map<String, Object>{
                'contentDocumentId' => String.valueOf(decision.contentDocumentId),
                'documentCategoryId' => String.valueOf(decision.documentCategoryId),
                'targetCategoryIds' => stringIds(decision.documentCategoryIds),
                'categoryName' => decision.categoryName,
                'categoryNames' => decision.categoryNames,
                'matchedParties' => decision.matchedParties,
                'confidence' => decision.confidence,
                'reason' => decision.reason
            });
        }
        return JSON.serialize(new Map<String, Object>{
            'mappings' => rows,
            'promptResponse' => rawMappingJson,
            'promptError' => promptError
        });
    }

    private static Decimal confidencePercent(Decimal confidence) {
        if (confidence == null) {
            return null;
        }
        return confidence <= 1 ? confidence * 100 : confidence;
    }

    private static List<String> stringIds(List<Id> ids) {
        List<String> values = new List<String>();
        if (ids == null) {
            return values;
        }
        for (Id idValue : ids) {
            if (idValue != null) {
                values.add(String.valueOf(idValue));
            }
        }
        return values;
    }

    private static Id idFrom(Object value) {
        if (value == null || String.isBlank(String.valueOf(value))) {
            return null;
        }
        try {
            return (Id) String.valueOf(value);
        } catch (Exception e) {
            return null;
        }
    }

    private static Decimal decimalFrom(Object value) {
        if (value == null) {
            return null;
        }
        if (value instanceof Decimal) {
            return (Decimal) value;
        }
        if (value instanceof Integer) {
            return Decimal.valueOf((Integer) value);
        }
        try {
            return Decimal.valueOf(String.valueOf(value));
        } catch (Exception e) {
            return null;
        }
    }

    private static Decimal confidenceFrom(Object value) {
        Decimal numeric = decimalFrom(value);
        if (numeric != null) {
            return numeric;
        }
        String normalized = value == null ? '' : String.valueOf(value).trim().toUpperCase();
        if (normalized == 'HIGH') {
            return 0.95;
        }
        if (normalized == 'MEDIUM') {
            return 0.70;
        }
        if (normalized == 'LOW') {
            return 0.25;
        }
        return null;
    }

    private static String stringFrom(Object value) {
        return value == null ? null : String.valueOf(value);
    }

    private static List<String> stringListFrom(Object value) {
        List<String> values = new List<String>();
        if (!(value instanceof List<Object>)) {
            return values;
        }
        for (Object item : (List<Object>) value) {
            if (item != null && String.isNotBlank(String.valueOf(item))) {
                values.add(String.valueOf(item));
            }
        }
        return values;
    }

    private class MappingWork {
        public Split_Job__c splitJob;
        public Id applicationId;
        public String source;
        public Set<Id> intakeJobIds = new Set<Id>();
        public List<Document_Intake_File__c> fileItems = new List<Document_Intake_File__c>();
    }

    private class OutputFile {
        public Id fileItemId;
        public Id contentDocumentId;
        public String fileName;
        public String documentType;
        public String sourceInstitution;
        public String namedParty;
        public String instanceLabel;
        public List<Integer> pages;
    }

    private class OutputSegment {
        public String documentType;
        public String sourceInstitution;
        public String namedParty;
        public String instanceLabel;
        public List<Integer> pages;
    }

    private class CategoryCandidate {
        public Id documentCategoryId;
        public String categoryName;
        public String categoryPath;
        public String rootCategoryName;
        public String parentCategoryName;
        public String partyName;
        public String partyType;
        public String scope;
        public Boolean isApplicationLevel;
        public Boolean isFallback;
        public String documentDefinitionName;
    }

    private class PartyCandidate {
        public Id accountId;
        public String partyName;
        public String partyType;
    }

    private class MappingDecision {
        public Id contentDocumentId;
        public Id documentCategoryId;
        public List<Id> documentCategoryIds = new List<Id>();
        public String categoryName;
        public List<String> categoryNames = new List<String>();
        public List<String> matchedParties = new List<String>();
        public Decimal confidence;
        public String reason;
    }

    private class FallbackConfig {
        public Boolean createFallback;
        public String parentCategoryName;
        public String childCategoryName;
    }
}

/**
 * Resolves application party names and category ownership for AI Document Review.
 */
public inherited sharing class AIDocReviewPartyResolver {
    /**
     * Loads party lookup maps for the supplied applications.
     * @param applicationIds Application ids whose parties should be loaded.
     * @return Party lookup maps grouped by application and account.
     */
    public static PartyIndex load(Set<Id> applicationIds) {
        PartyIndex index = new PartyIndex();
        if (applicationIds == null || applicationIds.isEmpty()) {
            return index;
        }

        for (clcommon__Party__c party : [
            SELECT Id, genesis__Application__c, clcommon__Account__c, clcommon__Party_Types__c,
                   clcommon__isPrimary__c, clcommon__Account__r.Name,
                   clcommon__Contact__r.FirstName, clcommon__Contact__r.LastName
            FROM clcommon__Party__c
            WHERE genesis__Application__c IN :applicationIds
            WITH USER_MODE
            ORDER BY clcommon__isPrimary__c DESC NULLS LAST, Name
        ]) {
            addParty(index, party);
        }
        return index;
    }

    /**
     * Resolves the party for a leaf category by walking up to the owned root category.
     * @param leaf Leaf document category whose owner should be resolved.
     * @param categoriesById Loaded categories keyed by Id.
     * @param partyByAccountId Parties keyed by Account Id.
     * @return Party context, or blank values when ownership cannot be resolved.
     */
    public static PartyContext resolvePartyForCategory(
        clcommon__Document_Category__c leaf,
        Map<Id, clcommon__Document_Category__c> categoriesById,
        Map<Id, PartyContext> partyByAccountId
    ) {
        clcommon__Document_Category__c root = findRootCategory(leaf, categoriesById);
        if (root == null || root.clcommon__Account__c == null) {
            return new PartyContext('', '');
        }
        PartyContext ctx = partyByAccountId.get(root.clcommon__Account__c);
        return ctx == null ? new PartyContext('', '') : ctx;
    }

    private static void addParty(PartyIndex index, clcommon__Party__c party) {
        String partyName = resolvePartyName(party);
        if (String.isBlank(partyName)) {
            return;
        }

        String partyType = String.isBlank(party.clcommon__Party_Types__c)
            ? 'UNSPECIFIED'
            : party.clcommon__Party_Types__c;
        Map<String, List<String>> typeMap = partyTypeMap(index, party.genesis__Application__c);
        if (!typeMap.containsKey(partyType)) {
            typeMap.put(partyType, new List<String>());
        }
        typeMap.get(partyType).add(partyName);
        if (party.clcommon__Account__c != null) {
            index.partyByAccountId.put(party.clcommon__Account__c, new PartyContext(partyName, partyType));
        }
    }

    private static Map<String, List<String>> partyTypeMap(PartyIndex index, Id applicationId) {
        if (!index.partiesByApp.containsKey(applicationId)) {
            index.partiesByApp.put(applicationId, new Map<String, List<String>>());
        }
        return index.partiesByApp.get(applicationId);
    }

    private static String resolvePartyName(clcommon__Party__c party) {
        if (party.clcommon__Account__r != null && String.isNotBlank(party.clcommon__Account__r.Name)) {
            return party.clcommon__Account__r.Name;
        }
        if (party.clcommon__Contact__r == null) {
            return '';
        }

        String first = party.clcommon__Contact__r.FirstName;
        String last = party.clcommon__Contact__r.LastName;
        String combined = String.isBlank(first) ? '' : first;
        if (String.isNotBlank(last)) {
            combined = String.isBlank(combined) ? last : combined + ' ' + last;
        }
        return combined;
    }

    private static clcommon__Document_Category__c findRootCategory(
        clcommon__Document_Category__c leaf,
        Map<Id, clcommon__Document_Category__c> categoriesById
    ) {
        clcommon__Document_Category__c cursor = leaf;
        Integer guard = 0;
        while (cursor != null && cursor.clcommon__Parent_Document_Category__c != null && guard < 20) {
            cursor = categoriesById.get(cursor.clcommon__Parent_Document_Category__c);
            guard++;
        }
        return cursor;
    }

    public class PartyIndex {
        public Map<Id, Map<String, List<String>>> partiesByApp =
            new Map<Id, Map<String, List<String>>>();
        public Map<Id, PartyContext> partyByAccountId = new Map<Id, PartyContext>();
    }

    public class PartyContext {
        public String partyName;
        public String partyType;

        public PartyContext(String partyName, String partyType) {
            this.partyName = partyName;
            this.partyType = partyType;
        }
    }
}

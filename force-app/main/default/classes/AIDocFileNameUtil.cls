/**
 * Shared file-name formatting helpers for AI document records.
 */
public inherited sharing class AIDocFileNameUtil {
    private static final Integer ASSOCIATION_NAME_LENGTH = 80;

    /**
     * Formats a Salesforce File title and extension as a display file name.
     * @param title ContentDocument or ContentVersion title.
     * @param extension File extension without a leading period.
     * @return File name with extension when one is available.
     */
    public static String fileNameFor(String title, String extension) {
        String fileTitle = String.isBlank(title) ? 'Document' : title.trim();
        if (String.isBlank(extension)) {
            return fileTitle;
        }
        String normalizedExtension = extension.trim();
        if (fileTitle.toLowerCase().endsWith('.' + normalizedExtension.toLowerCase())) {
            return fileTitle;
        }
        return fileTitle + '.' + normalizedExtension;
    }

    /**
     * Trims a file name for clcommon__Category_Attachment_Association__c.Name.
     * @param fileName Display file name.
     * @return Name value that fits the package association field.
     */
    public static String associationNameFor(String fileName) {
        String normalized = String.isBlank(fileName) ? 'Document' : fileName.trim();
        return normalized.left(ASSOCIATION_NAME_LENGTH);
    }
}

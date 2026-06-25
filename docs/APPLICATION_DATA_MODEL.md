# Application Data Model

## Root

`genesis__Applications__c`
- Id `a9ka5000000AIrhAAG`
- Name `APP-0000000000`

## Document categories (child)

`clcommon__Document_Category__c`
- Linked to application via `genesis__Application__c`
- Self-lookup for hierarchy via `clcommon__Parent_Document_Category__c`

13 rows under this application:

| Id | Category Name | Parent |
|---|---|---|
| a1da5000009NNbSAAW | Application Documents | — |
| a1da5000009NNbTAAW | Application Submission Documents | Application Documents |
| a1da5000009NbOHAA0 | John Morris | — |
| a1da5000009Ne2nAAC | Personal Financial Statement | John Morris |
| a1da5000009Ne2oAAC | Latest Personal Tax Forms | Personal Financial Statement |
| a1da5000009Ne2qAAC | Primary Identification Document | John Morris |
| a1da5000009Ne2rAAC | Driver's License | Primary Identification Document |
| a1da5000009Ne2sAAC | Passport | Primary Identification Document |
| a1da5000009Ne2tAAC | Financial Documents | John Morris |
| a1da5000009Ne2uAAC | Bank Statement | Financial Documents |
| a1da5000009Ne2vAAC | Secondary Identification Document | John Morris |
| a1da5000009Ne2wAAC | Credit Card Statement | Secondary Identification Document |
| a1da5000009Ne2xAAC | Utility Bill | Secondary Identification Document |

## Files (attached to doc categories)

`ContentDocument` linked to `clcommon__Document_Category__c` via `ContentDocumentLink`.

| ContentDocument Id | Title | Linked DocCategory | Category Name |
|---|---|---|---|
| 069a500000G7R0gAAF | 2025 1040 Basic | a1da5000009Ne2oAAC | Latest Personal Tax Forms |
| 069a500000G7T0rAAF | vance_electric_sample_bank_statement_april_2026_test_fixture | a1da5000009Ne2uAAC | Bank Statement |

## Relationship diagram

```
genesis__Applications__c (a9ka5000000AIrhAAG)
│
└── clcommon__Document_Category__c
    │
    ├── Application Documents
    │   └── Application Submission Documents
    │
    └── John Morris
        ├── Personal Financial Statement
        │   └── Latest Personal Tax Forms ─── ContentDocumentLink ─── ContentDocument (2025 1040 Basic.pdf)
        │
        ├── Primary Identification Document
        │   ├── Driver's License
        │   └── Passport
        │
        ├── Financial Documents
        │   └── Bank Statement ─── ContentDocumentLink ─── ContentDocument (vance_electric_...bank_statement.pdf)
        │
        └── Secondary Identification Document
            ├── Credit Card Statement
            └── Utility Bill
```

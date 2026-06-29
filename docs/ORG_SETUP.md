# Bringing a Fresh Salesforce Org Online

This is the playbook for redeploying the AI Document Review + AI Document Splitter
features into a new Salesforce org. Use it whenever a trial expires or you start
with a different org.

The whole thing takes ~20 minutes if Einstein is already enabled, ~45 minutes if
you have to set Einstein up first.

---

## 1. Prerequisites — verify the org meets these before deploying

| Requirement | How to verify | If missing |
|---|---|---|
| Managed packages: `genesis__*` and `clcommon__*` | `sf data query --query "SELECT NamespacePrefix FROM ApexClass WHERE NamespacePrefix IN ('genesis','clcommon') LIMIT 1" --target-org <alias>` returns ≥1 row | Install the Q2 loan-origination managed packages first (out of scope here) |
| Einstein Generative AI / Prompt Builder enabled | `sf project deploy start --dry-run --source-dir force-app/main/default/genAiPromptTemplates --target-org <alias>` does NOT fail with `"Not available for deploy for this organization"` | Setup → Einstein Setup → Turn On Einstein. May require a paid Einstein/Agentforce license. Trial orgs created via developer.salesforce.com/agentforce typically include it. |
| API user with sufficient permissions | `sf org display --target-org <alias>` shows Connected | `sf org login web --alias <alias>` |

If the second row fails, the splitter (and the existing AI Document Review email
+ classify/sanity prompts) cannot run. You must enable Einstein before continuing.

---

## 2. Authenticate the CLI to the new org

```bash
sf org login web --alias <new-alias>
sf org list   # confirm <new-alias> appears as Connected
```

Optionally make it the default for this project:

```bash
sf config set target-org=<new-alias>
```

---

## 3. Deploy in this exact order

The order matters — flows depend on activated prompts, prompts depend on the
custom objects they reference, etc.

### 3a. Custom objects + fields + custom metadata + permission set + Apex + LWC + UI

Everything that does NOT depend on Einstein, in one shot:

```bash
sf project deploy start \
  --source-dir force-app/main/default/applications \
  --source-dir force-app/main/default/classes \
  --source-dir force-app/main/default/customMetadata \
  --source-dir force-app/main/default/flexipages \
  --source-dir force-app/main/default/layouts \
  --source-dir force-app/main/default/lwc \
  --source-dir force-app/main/default/objects \
  --source-dir force-app/main/default/permissionsets \
  --source-dir force-app/main/default/staticresources \
  --source-dir force-app/main/default/tabs \
  --source-dir force-app/main/default/triggers \
  --target-org <new-alias> \
  --wait 30
```

Should report ~59 components Created/Changed, 0 errors.

### 3b. Prompt templates — deploys in Draft

```bash
sf project deploy start \
  --source-dir force-app/main/default/genAiPromptTemplates \
  --target-org <new-alias> \
  --wait 15
```

Four templates land in Draft state:
- `AIDocBorrowerEmail`
- `AIDocClassifyFile`
- `AIDocSanityCheck`
- `AIDocSplitClassify`

### 3c. Manual step in Prompt Builder — activate all four prompts

Setup → **Prompt Builder**. For each of the four templates:
1. Click the template name to open it.
2. Click the **Activate** button on the latest version.
3. Wait for the green "Activated" indicator.

This step CANNOT be scripted — Salesforce requires a UI click. Skipping it makes
step 3d fail.

### 3d. Flows — depends on activated prompts in 3c

```bash
sf project deploy start \
  --source-dir force-app/main/default/flows \
  --target-org <new-alias> \
  --wait 15
```

Three flows deploy:
- `AIDocCoverageReview` (parent flow — the AI Document Review feature)
- `AIDocVerifyOneFile` (subflow — calls Classify + Sanity per file)
- `AIDocSplitClassifySpike` (Phase 3 spike subflow — calls Split Classify)

---

## 4. Smoke tests — confirm the deploy is healthy

### 4a. Pure-logic unit tests (no AI needed)

```bash
sf apex run test --class-names SegmentMergerTest --result-format human --synchronous --target-org <new-alias>
```

Expect: 18/18 pass, ~500ms, 97% coverage on `SegmentMerger`.

### 4b. Custom metadata seeded correctly

```bash
sf data query --query "SELECT COUNT() FROM Document_Type__mdt" --target-org <new-alias>
```

Expect: 20 records.

### 4c. Vision prompt spike (requires step 3c done)

Edit `scripts/apex/spike_split_classify.apex` and put a real ContentDocument Id
(any PDF in the org) on the `targetFileId` line. Then:

```bash
sf apex run --file scripts/apex/spike_split_classify.apex --target-org <new-alias>
```

Expect: a debug log line like
`SPIKE_OUTPUT: [{"document_type":"BANK_STATEMENT","source_institution":"...","start_page":1,"end_page":N}]`
and `SPIKE_PARSED: 1 segments returned`.

If this fails with "file input not supported" or similar, Einstein is enabled
but the vision model in this org doesn't accept files. Check
`sfdc_ai__DefaultGPT5Mini` model availability in Prompt Builder.

---

## 5. Test data for the AI Document Review feature

The existing AI Document Review flow expects a `genesis__Applications__c` record
with:
- A `clcommon__Party__c` row of type `BORROWER` linked to the application
- One or more `clcommon__Document_Category__c` records, organized as a tree
  (root category linked to a party's Account, leaf categories under it)
- ContentDocuments attached to leaf categories via `ContentDocumentLink`

The fastest way to validate the feature in a fresh org is to copy a working
application from a known-good org. Otherwise, build one manually following the
shape documented in `docs/APPLICATION_DATA_MODEL.md`.

---

## 6. Where state lives that this doc doesn't replace

- **GitHub repo `r-balaji/DocAgents`, branch `feat/doc-splitter`**: all source
- **Prompt Builder state in the org**: per-prompt activation. Always a manual step.
- **Org-level Einstein license**: cannot be scripted. Org admin must enable.
- **Test data**: not in source control. Must be recreated per org.

---

## 7. Why this doc exists

Two trial orgs expired in the middle of this build. Each time, we lost ~30
minutes rediscovering the right deploy order and the manual Prompt Builder
activation steps. This doc captures both so the next org swap is faster.

If you discover a new step (e.g. a different Einstein toggle, a missing object),
add it here.

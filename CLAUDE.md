# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Salesforce DX project targeting **API version 67.0** (Summer '25). Source lives in `force-app/main/default/` and is deployed to orgs via the Salesforce CLI (`sf`).

## Common Commands

### Salesforce CLI

```bash
sf org login web                          # Authorize an org
sf org open                               # Open the default org in browser
sf org create scratch -f config/project-scratch-def.json -a <alias>  # Create scratch org
sf project deploy start                   # Deploy source to the default org
sf project retrieve start                 # Pull metadata from the org
sf apex run --file scripts/apex/hello.apex  # Run anonymous Apex
sf apex run test --test-level RunLocalTests # Run all Apex tests in org
sf data query --file scripts/soql/account.soql  # Run a SOQL file
```

### Local Dev / Quality

```bash
npm run lint          # ESLint for Aura and LWC JS
npm run test:unit     # LWC Jest unit tests (sfdx-lwc-jest)
npm run test:unit:watch      # Jest in watch mode
npm run test:unit:coverage   # Jest with coverage report
npm run prettier      # Format all source files in-place
npm run prettier:verify      # Check formatting without writing

python3 -m pytest                                  # Python unit tests (tests/)
python3 -m pytest --cov=apex_test_finder            # with coverage report
```

Python tests require `pytest` and `pytest-cov` (`pip install pytest pytest-cov`).

**Pre-commit hook** (`husky` + `lint-staged`) automatically runs Prettier, ESLint, and Jest `--findRelatedTests` on staged files — do not skip it.

## Architecture

### Source Layout

All deployable metadata lives under `force-app/main/default/` following the standard SFDX source format:

- `lwc/` — Lightning Web Components (each component is a folder with `.html`, `.js`, `.css`, `.js-meta.xml`, and optionally `__tests__/*.test.js`)
- `aura/` — Aura components (legacy; prefer LWC for new work)
- `classes/` — Apex classes (`.cls` + `.cls-meta.xml`)
- `triggers/` — Apex triggers (`.trigger` + `.trigger-meta.xml`)
- `objects/` — Custom object and field metadata
- `permissionsets/`, `profiles/`, `layouts/`, `flexipages/`, etc.

### LWC conventions

- Wire adapters from `@salesforce/apex` and `lightning/uiRecordApi` are preferred over imperative Apex where possible.
- LWC Jest tests mock `@salesforce/*` and `lightning/*` imports automatically via `@salesforce/sfdx-lwc-jest`. Place tests in `lwc/<componentName>/__tests__/<componentName>.test.js`.
- ESLint uses `@salesforce/eslint-config-lwc/recommended` for LWC files and `@salesforce/eslint-plugin-aura` (recommended + locker) for Aura. The `@lwc/lwc/no-unexpected-wire-adapter-usages` rule is disabled in test files.
- Prettier uses `prettier-plugin-apex` for `.cls`/`.trigger` and `@prettier/plugin-xml` for metadata XML. LWC HTML files use the `lwc` Prettier parser.

### Apex conventions

- Apex classes intended for LWC must be annotated `@AuraEnabled`.
- Trigger logic belongs in handler/service classes, not directly in the trigger body.
- `.sfdx/tools/sobjects/standardObjects/` contains generated Apex stubs for standard objects — useful for understanding field availability but not editable.

### Scratch Org

`config/project-scratch-def.json` defines a Developer edition scratch org with Lightning Experience enabled. Dev Hub must be enabled in the authorized org to create scratch orgs.

### `.forceignore`

`__tests__/` directories, `jsconfig.json`, `.eslintrc.json`, and `node_modules/` are excluded from org pushes/pulls.

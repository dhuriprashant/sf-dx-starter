# Salesforce DX Starter

A Salesforce DX project (API v67.0) containing a custom **JSON:API framework** for Apex REST, plus reference docs on platform integration patterns.

## What's in this repo

### JSON:API Framework

A generic Apex REST framework that serves registered SObjects per the [JSON:API v1.1 specification](https://jsonapi.org/format/) from `/services/apexrest/jsonapi`. It supports CRUD, compound documents (`?include` with dot-paths and aliased nested relationship paths), sparse fieldsets, sorting, filtering, and offset pagination — all enforced with `USER_MODE` security. Source: the `JsonApi*` classes in [force-app/main/default/classes/](force-app/main/default/classes/).

- **[docs/json-api-framework.md](docs/json-api-framework.md)** — API reference: endpoints, query parameters, how to expose a new SObject, curl examples.
- **[docs/json-api-framework-internals.md](docs/json-api-framework-internals.md)** — technical internals: component map, request lifecycle, SOQL construction, compound-document algorithm, error and security model.

### Reference docs

- **[event-publishing.md](event-publishing.md)** — Salesforce change notification options (CDC, Platform Events, outbound messaging, etc.) for notifying consumer apps of record changes.
- **[callout-readme.md](callout-readme.md)** — Apex callouts reference: DML + callout restrictions, async patterns, passing new record IDs in payloads.

## About Salesforce DX

Salesforce DX is a development approach that brings source-driven development, team collaboration, and continuous integration to the Salesforce Platform. Instead of working directly in an org through a web browser, you work with metadata as source files in a local DX project, track changes in version control, and deploy through automated processes.

## Prerequisites

Before you start, make sure you have:

- **Salesforce CLI** - Download from [developer.salesforce.com/tools/salesforcecli](https://developer.salesforce.com/tools/salesforcecli). See [Install Salesforce CLI](https://developer.salesforce.com/docs/atlas.en-us.sfdx_setup.meta/sfdx_setup/sfdx_setup_install_cli.htm) for details.
- **VS Code with Salesforce Extension Pack** - See [Installation Instructions](https://developer.salesforce.com/docs/platform/sfvscode-extensions/guide/install.html) for details. Includes the Agentforce Vibes extension.
- **A development org** - Sign up for a free Developer Edition org [here](https://developer.salesforce.com/signup).
- **Dev Hub enabled** (optional, required to create scratch orgs) - You can enable Dev Hub in your development org under Setup > Dev Hub.  See [Provide Developers Access to Salesforce DX Tools](https://developer.salesforce.com/docs/atlas.en-us.sfdx_dev.meta/sfdx_dev/sfdx_setup_dx_tools.htm).

## Project Structure

Your DX project follows this structure:

- **`force-app/main/default/`** - Your metadata source files live in this default package directory. You can configure additional package directories in the `sfdx-project.json` file.
- **`config/`** - Scratch org definitions and project settings
- **`scripts/`** - Automation scripts for common tasks
- **`sfdx-project.json`** - Project manifest that defines package directories, namespace, API version, and other project-level settings

See [Salesforce DX Project Configuration](https://developer.salesforce.com/docs/atlas.en-us.sfdx_dev.meta/sfdx_dev/sfdx_dev_ws_config.htm).

## Get Started

Ready to start developing? The [Get Started with Salesforce DX](https://developer.salesforce.com/docs/atlas.en-us.sfdx_dev.meta/sfdx_dev/sfdx_dev_get_started_dx.htm) guide walks you through your first project, from creating a scratch org to creating a simple Apex class or LWC to deploying your code to a sandbox.

## Common Salesforce CLI Commands

Here are common CLI commands that you'll use the most:

- `sf org login web`: Authorize an org
- `sf org open`: Open your org in a browser
- `sf org create scratch`: Create a scratch org
- `sf project deploy start`: Deploy metadata to your org
- `sf project retrieve start`: Retrieve metadata from your org
- `sf template generate <artifact>`: Scaffold new components, such as Apex classes and triggers, LWC components, Lightning apps, and more
- `sf apex <command>`: Run Apex tests, run anonymous Apex blocks, and view logs
- `sf data <command>`: Work with test data
- `sf alias <command>`: Manage org aliases
- `sf config <command>`: Configure CLI settings

## Local Development & Quality

```bash
npm run lint                 # ESLint for Aura and LWC JS
npm run test:unit            # LWC Jest unit tests
npm run prettier             # Format all source files
npm run prettier:verify      # Check formatting without writing
```

A pre-commit hook (husky + lint-staged) runs Prettier, ESLint, and related Jest tests on staged files automatically.

Deploy and test the JSON:API framework:

```bash
sf project deploy start --source-dir force-app/main/default/classes
sf apex run test --class-names JsonApiRouterTest --result-format human --wait 10
```

## Use Agentforce Vibes to Build Lightning Apps

Transform your ideas into custom Lightning apps that extend CRM workflows directly in Lightning Experience. Through natural conversations with Agentforce Vibes, implement custom objects and fields, complex business logic, and dynamic UI components. See [Build a Lightning App Using Agentforce Vibes](https://developer.salesforce.com/docs/platform/einstein-for-devs/guide/lexapp-overview.html).

## Additional Resources

- [Agentforce Vibes Developer Guide](https://developer.salesforce.com/docs/platform/einstein-for-devs/guide/einstein-overview.html)
- [Salesforce CLI Installation Guide](https://developer.salesforce.com/docs/atlas.en-us.sfdx_setup.meta/sfdx_setup/sfdx_setup_intro.htm)
- [Salesforce DX Developer Guide](https://developer.salesforce.com/docs/atlas.en-us.sfdx_dev.meta/sfdx_dev/)
- [Salesforce CLI Command Reference](https://developer.salesforce.com/docs/atlas.en-us.sfdx_cli_reference.meta/sfdx_cli_reference/)
- [Salesforce CLI Plugin Development Guide](https://developer.salesforce.com/docs/platform/salesforce-cli-plugin/guide/conceptual-overview.html)
- [Salesforce VS Code Extensions Documentation](https://developer.salesforce.com/tools/vscode/)


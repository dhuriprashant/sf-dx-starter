# JSON:API Framework — Technical Internals

How the Apex JSON:API framework in this repo is structured, how a request flows through it, and how each class works. For the user-facing API reference (endpoints, query params, curl examples), see [json-api-framework.md](json-api-framework.md).

The framework serves registered SObjects as [JSON:API v1.1](https://jsonapi.org/format/) resources from a single Apex REST endpoint:

```
/services/apexrest/jsonapi/*
```

---

## 1. Component map

Nine classes under `force-app/main/default/classes/`, in three layers:

```
                         HTTP (Apex REST)
                               │
┌──────────────────────────────▼─────────────────────────────┐
│  JsonApiRouter          @RestResource entry point           │  HTTP layer
│   • method dispatch, path parsing, content negotiation      │
│   • top-level try/catch → error documents                   │
└──────────────┬──────────────────────────────┬───────────────┘
               │ uses                          │ uses
┌──────────────▼──────────────┐  ┌────────────▼───────────────┐
│  JsonApiService             │  │  JsonApiQueryParams        │  Engine layer
│   • generic CRUD engine     │  │   • parse/validate         │
│   • compound docs (?include)│  │     include/fields/sort/   │
│   • uses JsonApiQuery for   │  │     page/filter            │
│     SOQL + limit guards     │  │                            │
└──────────────┬──────────────┘  └────────────────────────────┘
               │ reads config from            │ serializes via
┌──────────────▼──────────────────────────────▼───────────────┐
│  JsonApiConfig → JsonApiRegistry → JsonApiResourceDefinition │  Config layer
│  JsonApiSerializer   JsonApiException   JsonApiError         │  + support
└──────────────────────────────────────────────────────────────┘
```

| Class                       | File                            | Role                                                                                                                                   |
| --------------------------- | ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `JsonApiRouter`             | `JsonApiRouter.cls`             | `@RestResource(urlMapping='/jsonapi/*')`. HTTP verb handlers, URL routing, header checks, body parsing, error-to-document translation. |
| `JsonApiService`            | `JsonApiService.cls`            | All business logic: CRUD, relationships, pagination, compound documents. Fully generic — no per-object code.                           |
| `JsonApiQuery`              | `JsonApiQuery.cls`              | Shared SOQL construction (`selectFrom`, `byId`, `byIds`, `children`) and transaction-limit guards (query-row budget, heap headroom).   |
| `JsonApiConfig`             | `JsonApiConfig.cls`             | The one file you edit to expose an SObject. Declares resource definitions.                                                             |
| `JsonApiRegistry`           | `JsonApiRegistry.cls`           | Static in-memory map: resource type name → definition.                                                                                 |
| `JsonApiResourceDefinition` | `JsonApiResourceDefinition.cls` | Fluent builder mapping JSON attribute names ↔ SObject field API names, plus relationship metadata.                                     |
| `JsonApiQueryParams`        | `JsonApiQueryParams.cls`        | Parses `include`, `fields[type]`, `sort`, `page[size]/[after]`, `filter[attr]` and validates them against the definition.              |
| `JsonApiSerializer`         | `JsonApiSerializer.cls`         | SObject → JSON:API resource object; assembles top-level documents and error documents.                                                 |
| `JsonApiException`          | `JsonApiException.cls`          | Exception carrying HTTP status, title, and JSON:API `source` pointer/parameter. Static factories per status code.                      |
| `JsonApiError`              | `JsonApiError.cls`              | Builds the JSON:API error-object map that gets serialized into error documents.                                                        |

Design principle: **the engine is data-driven**. `JsonApiService` and `JsonApiSerializer` know nothing about Account or Contact; everything they do is parameterized by a `JsonApiResourceDefinition`. Adding a new resource type requires zero engine changes — only a registration in `JsonApiConfig`.

---

## 2. Request lifecycle

Every request, regardless of verb, follows the same pipeline in `JsonApiRouter.handle()` ([JsonApiRouter.cls:39-61](../force-app/main/default/classes/JsonApiRouter.cls#L39-L61)):

```
Salesforce dispatches @HttpGet/@HttpPost/@HttpPatch/@HttpDelete
        │
        ▼
handle(method)
  1. res.addHeader('Content-Type', 'application/vnd.api+json')   ← set up-front so even errors carry it
  2. JsonApiConfig.registerAll()                                  ← lazy one-time registration per transaction
  3. checkHeaders(req, method)                                    ← 415 / 406 content negotiation
  4. route(method, req, res)                                      ← path → service call → response body
        │
        └─ catch:
             JsonApiException      → its own status + error document
             System.QueryException → 400
             System.DmlException   → 422 with DML message + StatusCode as `code`
             anything else         → 500
```

### 2.1 Verb dispatch

Apex REST allows one method per HTTP verb. Each annotated method ([JsonApiRouter.cls:19-37](../force-app/main/default/classes/JsonApiRouter.cls#L19-L37)) is a one-liner delegating to `handle('<VERB>')`, so all logic — including error handling — lives in one place. PUT is not mapped (JSON:API uses PATCH); Salesforce returns its own error for unmapped verbs.

### 2.2 Path parsing

`pathSegments()` ([JsonApiRouter.cls:119-131](../force-app/main/default/classes/JsonApiRouter.cls#L119-L131)) takes `RestRequest.requestURI`, strips everything up to and including `/jsonapi`, trims slashes, splits on `/`, and URL-decodes each segment. So:

```
/services/apexrest/jsonapi/accounts/001xx.../relationships/contacts
  → ['accounts', '001xx...', 'relationships', 'contacts']
```

### 2.3 Routing table

`route()` ([JsonApiRouter.cls:63-117](../force-app/main/default/classes/JsonApiRouter.cls#L63-L117)) dispatches on `(method, segment count)`:

| Method | Segments                      | Shape                              | Service call                                                 |
| ------ | ----------------------------- | ---------------------------------- | ------------------------------------------------------------ |
| GET    | 0                             | `/`                                | inline: meta doc listing `JsonApiRegistry.registeredTypes()` |
| GET    | 1                             | `/{type}`                          | `listResources`                                              |
| GET    | 2                             | `/{type}/{id}`                     | `getResource`                                                |
| GET    | 3                             | `/{type}/{id}/{rel}`               | `getRelated`                                                 |
| GET    | 4 (`seg[2]=='relationships'`) | `/{type}/{id}/relationships/{rel}` | `getRelationship`                                            |
| POST   | 1                             | `/{type}`                          | `createResource` → 201 + `Location` header                   |
| PATCH  | 2                             | `/{type}/{id}`                     | `updateResource`                                             |
| PATCH  | 4 (`relationships`)           | `/{type}/{id}/relationships/{rel}` | `patchRelationship`                                          |
| DELETE | 2                             | `/{type}/{id}`                     | `deleteResource` → 204, empty body                           |

Anything else throws `notFound` or `methodNotAllowed`. Before dispatch, `seg[0]` is resolved via `JsonApiRegistry.get()` (404 for unknown types) and query params are parsed once into a `JsonApiQueryParams` ([JsonApiRouter.cls:79-80](../force-app/main/default/classes/JsonApiRouter.cls#L79-L80)).

Two small guards worth knowing:

- `toId()` ([JsonApiRouter.cls:133-139](../force-app/main/default/classes/JsonApiRouter.cls#L133-L139)) converts the `{id}` segment via `Id.valueOf`; malformed IDs become 404, not a raw exception. Note it does **not** verify the ID's SObject prefix matches the resource type — a Contact ID under `/accounts/` produces an empty query result and thus a 404 anyway.
- `requestBody()` ([JsonApiRouter.cls:141-155](../force-app/main/default/classes/JsonApiRouter.cls#L141-L155)) requires a non-empty body that deserializes (untyped) to a JSON object; otherwise 400.

### 2.4 Content negotiation

`checkHeaders()` ([JsonApiRouter.cls:157-178](../force-app/main/default/classes/JsonApiRouter.cls#L157-L178)):

- **Request `Content-Type`** (POST/PATCH only): must contain `application/vnd.api+json` or `application/json`, else **415**. A missing Content-Type is tolerated.
- **`Accept`**: if present, at least one media range (parameters after `;` stripped) must be `application/vnd.api+json`, `*/*`, `application/*`, or `application/json`, else **406**. A missing Accept header is tolerated.

Responses always carry `Content-Type: application/vnd.api+json`.

---

## 3. Configuration layer

### 3.1 JsonApiResourceDefinition — the mapping

One instance per exposed resource type ([JsonApiResourceDefinition.cls](../force-app/main/default/classes/JsonApiResourceDefinition.cls)). Fluent builder API:

```apex
new JsonApiResourceDefinition('contacts', 'Contact')     // resourceType, sobjectName
    .attribute('firstName', 'FirstName')                 // JSON name → field API name
    .toOne('account', 'AccountId', 'accounts')           // relName, lookup field on THIS object, target type
    .toMany('cases', 'cases', 'ContactId')               // relName, target type, FK field on the CHILD object
    .nested('caseAccounts', new List<String>{ 'cases', 'account' })  // aliased multi-hop path (read-only)
```

State it holds:

- `attributes` — `Map<String, String>` of JSON attribute name → SObject field API name. This map is the **whitelist**: an attribute not in it can't be read, written, sorted, or filtered.
- `relationships` — `Map<String, Rel>` where the inner `Rel` class carries `name`, `isToMany`, `field`, `targetType`, and (for nested rels) `path`. The `field` member is overloaded by direction: for to-one it's the lookup on this SObject, for to-many it's the foreign-key lookup on the _child_ SObject; for nested rels it's null.
- **Nested rels** (`isNested()` = `path != null`) implement the spec's "expose a deeply nested relationship under an alternative name" provision. Each path segment must be a _direct_ relationship on the type reached by the previous segment. Their `isToMany`/`targetType` start null and are resolved lazily on first use by `JsonApiRegistry.resolveNested()`, which walks the path through the registry (registration order in `JsonApiConfig` therefore doesn't matter): cardinality is to-many if _any_ hop is to-many, and the target type is the final hop's. A broken path surfaces as a 500 Configuration Error.

Derived helpers:

- `getSelectFields()` ([JsonApiResourceDefinition.cls:78-89](../force-app/main/default/classes/JsonApiResourceDefinition.cls#L78-L89)) — the SELECT list for every query on this type: `Id` + all attribute fields + all direct to-one lookup fields (needed to emit relationship linkage); nested rels contribute nothing here. Sparse fieldsets do **not** shrink the query — filtering happens at serialization time.
- `fieldFor(jsonName)` ([JsonApiResourceDefinition.cls:92-97](../force-app/main/default/classes/JsonApiResourceDefinition.cls#L92-L97)) — resolves a JSON name to a field API name (`'id'` → `'Id'` special-cased), returning `null` if not exposed. This null-return is the validation primitive used by sort/filter parsing.
- `getDescribe()` / `getSObjectType()` — lazily cached `Schema.describeSObjects` result, used for field-type coercion and `newSObject()` instantiation.

### 3.2 JsonApiRegistry + JsonApiConfig

`JsonApiRegistry` ([JsonApiRegistry.cls](../force-app/main/default/classes/JsonApiRegistry.cls)) is a static `Map<String, JsonApiResourceDefinition>`. `get()` throws a 404-flavored `JsonApiException` for unknown types, so callers never null-check.

`JsonApiConfig.registerAll()` ([JsonApiConfig.cls:8-39](../force-app/main/default/classes/JsonApiConfig.cls#L8-L39)) populates it, guarded by a static `registered` flag so it runs once per transaction (Apex statics live for the transaction). Currently registers `accounts` (Account, with to-many `contacts` and the nested alias `contactManagers` = `contacts` → `reportsTo`) and `contacts` (Contact, with to-one `account` and to-one `reportsTo`, the standard `ReportsToId` self-lookup). `@TestVisible reset()` clears both flag and registry for tests.

Registration is code, not custom metadata — a deliberate trade-off: type-checked at compile time and deployable, but changing exposure requires a deploy.

---

## 4. Query parameter parsing — JsonApiQueryParams

`parse(req.params, def)` ([JsonApiQueryParams.cls:18-64](../force-app/main/default/classes/JsonApiQueryParams.cls#L18-L64)) walks every query-string key (Apex REST pre-decodes them, so the key literally arrives as `page[size]`) and populates:

| Param                  | Parsed into                                            | Validation                                                                                                                                                                      |
| ---------------------- | ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `include=a,b.c`        | `List<String> include` (raw names or dot-paths)        | each dot-separated segment must be a relationship on the type reached by the previous segment (walked through the registry), else 400 with `source.parameter`                   |
| `fields[TYPE]=x,y`     | `Map<String, Set<String>> sparseFields`                | **not validated** — unknown types/fields simply have no effect at serialization                                                                                                 |
| `sort=-name,createdAt` | `List<SortField>` (`attribute`, `descending`)          | each attribute must resolve via `def.fieldFor()`, else 400                                                                                                                      |
| `page[size]`           | `pageSize` (default null = no pagination)              | positive integer; `page[number]` is rejected with a 400 — offset pagination is not supported                                                                                    |
| `page[after]`          | `after`                                                | keyset cursor: a record Id of the target type (prefix-checked); requires `page[size]`, rejects `sort`; walk is `WHERE Id > :after ORDER BY Id ASC` — no OFFSET, unlimited depth |
| `filter[ATTR]=v1,v2`   | `Map<String, String> filters` (raw value; commas = IN) | attribute must resolve via `def.fieldFor()`, else 400                                                                                                                           |

Unrecognized parameters are silently ignored. Validation happens **against the definition of the primary resource type in the URL** — this is why parsing needs the `def` and happens after type resolution in the router.

One subtlety: `include`/`sort`/`filter` are validated per-definition, but `fields[...]` is keyed by resource type and applied later to whichever type is being serialized (primary or included), which is why it can't be validated up-front against a single definition.

---

## 5. The engine — JsonApiService

`public with sharing`, and every query and DML call passes `AccessLevel.USER_MODE` — see [§8 Security](#8-security-model).

### 5.1 Dynamic SOQL construction

All SOQL is assembled from **definition-derived identifiers** (field API names from the registration code, never from user input) plus **bind variables** for every user-supplied value, using `Database.queryWithBinds` / `countQueryWithBinds`. The pattern:

```apex
'SELECT ' + String.join(def.getSelectFields(), ', ')
+ ' FROM ' + def.sobjectName
+ whereClause              // 'Field IN :jsonApiFilter0 AND Id > :jsonApiAfter ...' — field names from def, values bound
+ orderBy                  // field names from def
+ ' LIMIT :jsonApiLimit'
```

There is no string concatenation of user values into SOQL anywhere; injection surface is limited to names that already passed the `fieldFor()` whitelist.

### 5.2 GET /{type} — listResources

([JsonApiService.cls:8-34](../force-app/main/default/classes/JsonApiService.cls#L8-L34))

1. `buildWhere()` turns `qp.filters` into `WHERE Field0 IN :jsonApiFilter0 AND Field1 IN :jsonApiFilter1 ...`. Each raw value is comma-split and converted to a **typed list** by `typedFilterValues()` ([JsonApiService.cls:449-491](../force-app/main/default/classes/JsonApiService.cls#L449-L491)) — `List<Date>`, `List<Datetime>`, `List<Decimal>`, `List<Boolean>`, or `List<String>` depending on the field's describe type. This exists because SOQL rejects `List<Object>` binds ("Invalid bind expression type of ANY").
2. No COUNT query is ever run. Paginated requests fetch `pageSize + 1` rows — the sentinel row's presence decides the `next` link — so a page costs only `pageSize + 1` of the 50k query-row governor budget regardless of collection size. Unpaginated requests fetch everything, capped with a `LIMIT` at the remaining budget; filling the cap is treated as truncation and throws a 400 "Result Set Too Large" instead of an uncatchable `LimitException` (`totalResources` is `records.size()`).
3. With `page[after]`, `Id > :jsonApiAfter` is ANDed into the WHERE and the fallback `ORDER BY Id ASC` provides the matching order (`sort` is rejected with a cursor). `next` carries the last returned record's Id, so following links walks a collection of any size in `pageSize` steps — no OFFSET is ever used, so there is no depth limit. The walk is not a snapshot: rows inserted behind the cursor mid-walk are missed.
4. The page query adds `buildOrderBy()` — each sort becomes `Field DESC NULLS LAST` / `ASC NULLS FIRST`, with a fallback `ORDER BY Id ASC` so pagination is stable when no sort is given — plus `LIMIT :jsonApiLimit` (`pageSize + 1`, or the row budget when unpaginated).
5. `buildCompound()` resolves `?include` (see §5.4), then each record is serialized and wrapped in a document with `pageLinks()` (`self`/`first`, plus `next` when the sentinel row was present _and_ the page is unsorted — the cursor cannot resume a custom sort order, so a sorted page is always the only page; `page[...]` brackets percent-encoded as `%5B`/`%5D`) and `pageMeta()` (`pageSize` only). Unpaginated requests get only a `self` link and `totalResources`.

### 5.3 GET /{type}/{id} — getResource and fetchById

`fetchById()` ([JsonApiService.cls:397-409](../force-app/main/default/classes/JsonApiService.cls#L397-L409)) is the shared "load or 404" primitive: `SELECT <selectFields> WHERE Id = :jsonApiId` in USER_MODE. Because USER_MODE applies sharing, a record the caller can't see is indistinguishable from a nonexistent one — both are 404, which avoids leaking record existence. It's reused by get, update (pre-check), delete (pre-check), related, and relationship endpoints.

### 5.4 Compound documents — buildCompound

([JsonApiService.cls:219-269](../force-app/main/default/classes/JsonApiService.cls#L219-L269)) implements `?include` for both plain relationship names and **dot-paths** (`include=contacts.reportsTo`). It returns a private `Compound` struct with two members:

- `included` — the deduplicated list of serialized related resources for the top-level `included` array. The dedup `seen` set (key `type + ':' + Id`) is **seeded with the primary records**, so primary data is never duplicated in `included`, per the spec.
- `toManyData` — `Map<relName, Map<parentId, List<identifier>>>`: the linkage the serializer needs to emit `relationships.{rel}.data` for to-many and nested relationships. Linkage from different paths merges per parent via `mergeLinkage()`.

The algorithm processes each include path **level by level**: starting from the primary records, each segment is expanded by `expandRelationship()` ([JsonApiService.cls:271-309](../force-app/main/default/classes/JsonApiService.cls#L271-L309)) into the next level of records, which become both `included` entries and the parents for the following segment. Per the spec's full-linkage rule, **intermediate resources are included along with the leaf nodes** — `contacts.reportsTo` puts the contacts _and_ their managers in `included`. Two mechanics make this efficient and correct:

- **Prefix cache**: expanded levels are memoized by path prefix, so `include=contacts,contacts.reportsTo` expands `contacts` once, not twice.
- **Deferred serialization**: included records are collected as `(record, def)` pairs and only serialized _after_ all paths are processed, with the complete `toManyData` map. That's what lets an included intermediate carry `data` linkage for the next segment (e.g. an included account's `contacts` array when the path is `account.contacts`) — full linkage, not just links.

Per segment kind, `expandRelationship` does:

- **to-many**: one bulk query — `JsonApiQuery.children()` selects the child definition's fields _plus the FK field_, filters `WHERE fk IN :parentIds` — children are grouped by parent ID into `toManyData`. One query per level regardless of how many parents (no N+1).
- **to-one**: collect the non-null lookup IDs across the parents, one `JsonApiQuery.byIds()` bulk fetch. No linkage map needed — the serializer reads the lookup value straight off the parent record.
- **nested** (aliased path): delegated to `traverseNested()` — see §5.5. Its root→final linkage merges into `toManyData` like a to-many segment.

Included resources are serialized with the same `qp`, so `fields[childType]` sparse fieldsets apply to them too (and per the spec, sparse fieldsets are the one thing allowed to drop relationship linkage from included resources).

### 5.5 Nested (aliased path) relationships — resolveNested / traverseNested

Implements the spec's "expose a deeply nested relationship under an alternative name" provision (registered via `.nested()`, §3.1) — unlike a dot-path include, an alias deliberately **hides the intermediate resources**. Two helpers:

- **`JsonApiRegistry.resolveNested()`** ([JsonApiRegistry.cls:33-54](../force-app/main/default/classes/JsonApiRegistry.cls#L33-L54)) — validates the path on first use and caches the result on the `Rel`: each segment must be a _direct_ relationship on the type reached by the previous segment (a broken path is a 500 Configuration Error); cardinality resolves to to-many if **any** hop is to-many; `targetType` becomes the final hop's type. Lazy resolution means `JsonApiConfig` registration order doesn't matter. It lives on the registry so both the engine and query-param validation can call it.
- **`traverseNested()`** ([JsonApiService.cls:330-395](../force-app/main/default/classes/JsonApiService.cls#L330-L395)) — walks the path hop by hop with **one bulk query per hop** (`JsonApiQuery.children` for to-many hops, `JsonApiQuery.byIds` for to-one hops), carrying a `Map<currentRecordId, Set<rootId>>` so fan-out/fan-in linkage stays correct — e.g. two contacts reporting to the same manager collapse to a single linkage entry per root account. It returns a `NestedResult`: the final-hop records, their definition, and `root → identifiers` linkage.

Only the **final-hop** records are serialized into `included`/`toManyData` — intermediates are queried but never emitted, which is the point of the alias. A nested rel whose hops are all to-one serializes as to-one linkage (single identifier or null) instead of an array. Nested rels are read-only end to end: body writes are rejected in `applyToOneRelationships` (400) and `patchRelationship` refuses them (403).

### 5.6 Writes — createResource / updateResource / deleteResource

**Create** ([JsonApiService.cls:51-62](../force-app/main/default/classes/JsonApiService.cls#L51-L62)):
`primaryData()` extracts and validates `body.data` as an object → `validateType()` requires `data.type` to equal the URL's resource type (409 on mismatch) → client-generated IDs rejected with 403 → new SObject instantiated via `def.getSObjectType().newSObject()` → attributes and to-one relationships applied → `Database.insert(rec, USER_MODE)` → the response is a fresh `getResource()` re-read, so the client sees server-computed values (defaults, formulas, audit fields).

**Update** ([JsonApiService.cls:66-83](../force-app/main/default/classes/JsonApiService.cls#L66-L83)):
same body validation, plus 409 if `data.id` is present and differs from the URL ID. `fetchById()` first for a proper 404, then a **sparse update**: `newSObject(recordId)` creates an SObject with only the ID set, only the fields present in the request are `put()`, and `Database.update` touches nothing else — that's what makes PATCH semantics correct.

**Delete** ([JsonApiService.cls:87-90](../force-app/main/default/classes/JsonApiService.cls#L87-L90)): `fetchById()` for the 404, then `Database.delete` in USER_MODE. Router sets 204 with no body.

Shared write plumbing:

- `applyAttributes()` ([JsonApiService.cls:562-575](../force-app/main/default/classes/JsonApiService.cls#L562-L575)) — every key in `data.attributes` must exist in `def.attributes` (unknown → 400 with pointer `/data/attributes/<name>`), then the value is coerced and `put()` onto the record.
- `coerce()` ([JsonApiService.cls:612-654](../force-app/main/default/classes/JsonApiService.cls#L612-L654)) — converts what `JSON.deserializeUntyped` produced (String/Decimal/Boolean) into the Apex type the field's describe demands: `Date.valueOf`, ISO-8601 Datetime via `JSON.deserialize` round-trip (handles the `T`/timezone formats `Datetime.valueOf` can't), Integer/Decimal narrowing, Boolean parsing. Bad values → 400.
- `applyToOneRelationships()` ([JsonApiService.cls:577-601](../force-app/main/default/classes/JsonApiService.cls#L577-L601)) — for each key in `data.relationships`: it must be a known, direct **to-one** rel (writing a to-many or nested rel here is a 400), `data: null` clears the lookup, otherwise the identifier's `type` must match the rel's `targetType` (409) and its `id` is written to the lookup field.

### 5.7 Relationship endpoints

- **`getRelated`** ([JsonApiService.cls:94-132](../force-app/main/default/classes/JsonApiService.cls#L94-L132)) — returns full resource objects: an array (possibly empty) for to-many via `JsonApiQuery.children`, a single resource or `null` for to-one. Nested rels are served by running `traverseNested` from the single parent record. `requireRel()` 404s on unknown relationship names.
- **`getRelationship`** ([JsonApiService.cls:136-158](../force-app/main/default/classes/JsonApiService.cls#L136-L158)) — same shape but returns only resource **identifiers** (`{type, id}`), with `self` + `related` links; nested rels return the traversal's linkage.
- **`patchRelationship`** ([JsonApiService.cls:162-195](../force-app/main/default/classes/JsonApiService.cls#L162-L195)) — direct to-one only: nested rels are read-only (403, checked first since their `isToMany` is null until resolved) and to-many linkage replacement would mean re-parenting arbitrary children (403). Validates the `data` member exists and its `type` matches, then writes the lookup (or null) with a sparse update and responds with the fresh linkage document.

---

## 6. Serialization — JsonApiSerializer

Everything is built as `Map<String, Object>` / `List<Object>` and serialized once with `JSON.serialize` at the router — no typed DTOs, which keeps the engine generic and key order irrelevant.

`resource()` ([JsonApiSerializer.cls:19-76](../force-app/main/default/classes/JsonApiSerializer.cls#L19-L76)) builds one resource object:

```json
{
  "type": "contacts",
  "id": "003...",
  "attributes": { "firstName": "Ada", ... },
  "relationships": {
    "account": {
      "links": { "self": ".../contacts/003.../relationships/account",
                 "related": ".../contacts/003.../account" },
      "data": { "type": "accounts", "id": "001..." }
    }
  },
  "links": { "self": ".../contacts/003..." }
}
```

Key mechanics:

- **Sparse fieldsets**: `qp.sparseFor(def.resourceType)` returns the allowed name set (or null = everything). Both attributes _and relationships_ are filtered by it, matching the spec's definition of "fields".
- **Relationship `data`**: direct to-one linkage is always emitted (the lookup value is on the record — free). To-many and nested linkage is only emitted when the caller passed the `toManyData` map, i.e. when that rel was `?include`d; otherwise the rel object carries links only. This keeps un-included relationships from costing queries. A nested rel resolved to to-one cardinality is emitted as a single identifier (or null) rather than an array.
- `document()` ([JsonApiSerializer.cls:82-103](../force-app/main/default/classes/JsonApiSerializer.cls#L82-L103)) wraps data with `{"jsonapi": {"version": "1.1"}}` plus optional `links` / `meta` / `included`. `errorDocument()` does the same for a list of `JsonApiError.toMap()`s.
- `baseUrl()` uses `URL.getOrgDomainUrl()`, so all generated links are absolute against the org's My Domain.

---

## 7. Error model

Two classes split the concern:

- **`JsonApiException`** ([JsonApiException.cls](../force-app/main/default/classes/JsonApiException.cls)) is the _control-flow_ type. It extends `Exception` and carries `status`, `title`, and optional `sourcePointer` / `sourceParameter`. Static factories map to statuses: `badRequest` 400, `badParameter` 400 + `source.parameter`, `forbidden` 403, `notFound` 404, `methodNotAllowed` 405, `notAcceptable` 406, `conflict` 409, `unsupportedMediaType` 415. `.withPointer('/data/attributes/x')` chains a JSON pointer to the offending body location.
- **`JsonApiError`** ([JsonApiError.cls](../force-app/main/default/classes/JsonApiError.cls)) is the _representation_: `toMap()` emits `{status, title, detail?, code?, source?{pointer?, parameter?}}` per the spec's error-object shape.

The router's catch chain (§2) is the only place errors become HTTP. Notably, `DmlException` → **422** with the first DML message as `detail` and the `StatusCode` enum (e.g. `REQUIRED_FIELD_MISSING`, `FIELD_CUSTOM_VALIDATION_EXCEPTION`) as `code` — so validation rules and required fields surface cleanly without any framework code knowing about them.

Deliberate throw-early style: parsing and validation throw immediately with pointers/parameters attached, so error responses always identify exactly what was wrong.

Example error document:

```json
{
  "jsonapi": { "version": "1.1" },
  "errors": [
    {
      "status": "400",
      "title": "Bad Request",
      "detail": "Unknown attribute: nickname",
      "source": { "pointer": "/data/attributes/nickname" }
    }
  ]
}
```

---

## 8. Security model

Defense in depth, three layers:

1. **Whitelist at the definition.** Only registered resource types are routable, and only declared attributes/relationships are readable, writable, sortable, filterable, or includable. Anything else is a 400/404 before any query runs.
2. **Injection-safe SOQL.** Field and object names in query strings come exclusively from `JsonApiConfig` registration code; every user-supplied _value_ (filters, IDs, page numbers) goes through `Database.queryWithBinds` bind maps.
3. **Platform enforcement.** `with sharing` on router and service plus `AccessLevel.USER_MODE` on every `queryWithBinds` / `countQueryWithBinds` / `insert` / `update` / `delete` means CRUD, FLS, and sharing rules of the _calling user_ are enforced by the platform: unreadable fields throw, invisible records 404, forbidden DML throws (→ surfaces via the catch chain).

Authentication is standard Salesforce OAuth — Apex REST requires a valid session/access token before the router ever runs.

---

## 9. Worked example: `GET /accounts?include=contacts&fields[contacts]=firstName&sort=-name&page[size]=2`

1. `doGet()` → `handle('GET')`; Content-Type header set; `registerAll()` populates the registry.
2. `checkHeaders` passes (no body; Accept allows the media type).
3. `pathSegments` → `['accounts']`; `JsonApiRegistry.get('accounts')` resolves the definition.
4. `JsonApiQueryParams.parse`: `include=['contacts']` (validated against accounts' relationships), `sparseFields={'contacts': {'firstName'}}`, `sorts=[{name, desc}]`, `pageSize=2`.
5. `listResources`:
   - `SELECT Id, Name, Industry, Phone, Website, NumberOfEmployees, CreatedDate FROM Account ORDER BY Name DESC NULLS LAST LIMIT :3` (USER_MODE) — `pageSize + 1`; the third (sentinel) row is trimmed from the result. Because the page is sorted, no `next` link is emitted regardless of the sentinel (the cursor cannot resume a name-ordered walk).
   - `buildCompound`: one query `SELECT Id, FirstName, ..., AccountId FROM Contact WHERE AccountId IN :(2 account ids)`; children grouped per account into `toManyData['contacts']`; each contact serialized (sparse → only `firstName` attribute) into `included`.
   - Each account serialized with `relationships.contacts.data` = its identifier list.
   - Document assembled with `links` (self/first) and `meta` `{pageSize: 2}`.
6. Router serializes the map, status 200.

Total: **2 SOQL queries** for the whole request, independent of row counts.

Variant with a dot-path — `GET /accounts/{id}?include=contacts.reportsTo`: after `fetchById` loads the account (1 query), `buildCompound` expands segment `contacts` (1 query) and segment `reportsTo` (1 query). Per the spec's full-linkage rule, `included` contains **both** the contacts and their managers, and each included contact carries its `reportsTo` linkage. Total: **3 queries**, generally `1 + pathLength`.

Variant with a nested alias — `GET /accounts/{id}?include=contactManagers`: same two hop queries via `traverseNested`, but only the managers land in `included` and in `relationships.contactManagers.data`; the intermediate contacts are queried, used for linkage, and never serialized. Same query count — the difference is purely what the response exposes.

---

## 10. Known limitations / design boundaries

- **Nested aliases can't nest.** A `.nested()` path segment must be a direct relationship — an alias can't reference another alias (500 Configuration Error). Dot-path _includes_ may use aliases as segments, though.
- **No include-path depth limit.** Dot-paths of any length are accepted; each segment costs one query, so a hostile deep path costs `pathLength` queries (bounded in practice by exposed relationships and the 100-SOQL governor limit).
- **Filters are equality/IN only** — no `filter[amount][gte]`-style operators; multiple filters always AND.
- **Pagination is cursor-only.** `page[number]` is rejected (400); the `page[after]` keyset cursor has unlimited depth but is forward-only, Id-ordered, and not a point-in-time snapshot. Consequently a **sorted page is not walkable**: `sort` + `page[size]` returns the top page with no `next` link, because the cursor cannot resume a custom sort order.
- **Query-row budget guards are truncation-based.** List, `JsonApiQuery.byIds`, and `JsonApiQuery.children` queries are each capped at the remaining 50k transaction budget and throw a 400 "Result Set Too Large" on hitting the cap — including a result that legitimately fills the budget exactly.
- **Heap is guarded heuristically.** After each bulk fetch, `JsonApiQuery`'s heap-headroom check throws a 400 "Response Too Large" when `Limits.getHeapSize() * 3 > Limits.getLimitHeapSize()` — the 3× reserves room for the document maps and JSON string that serialization still has to build. The multiplier is an estimate: very wide rows could still blow heap during serialization (uncatchable 500), and a modest overshoot may be rejected that would actually have fit. CPU time is not guarded.
- **To-many linkage is read-only** (`PATCH /relationships/{toMany}` → 403), and full-replacement POST/DELETE on to-many relationship endpoints isn't implemented.
- **No client-generated IDs** (403 per the optional part of the spec) and **no atomic multi-operation extension**.
- **Registrations are code**, not Custom Metadata — exposing an object requires a deploy.
- `fields[...]` values aren't validated; typos silently yield empty attribute sets.
- One `JsonApiError` per response; errors aren't aggregated across multiple invalid inputs (first failure wins).

## 11. Tests & deployment

`JsonApiRouterTest.cls` exercises the stack end-to-end by populating `RestContext.request`/`RestContext.response` and calling the router's verb methods directly (the standard Apex REST testing pattern). The 16 tests cover pagination/sort (a keyset-cursor walk via `page[after]` with `next`-link termination, the `page[number]` rejection, and the cursor+sort rejection), includes, sparse fieldsets, filters, CRUD with relationships, relationship endpoints, dot-path includes (`includesDotPathWithIntermediates` verifies intermediates and leaves are both included with full linkage; `dotPathEmitsToManyLinkageOnIncludedIntermediates` verifies deferred serialization emits to-many linkage on included intermediates and that primary data is never duplicated), nested aliases (`includesNestedRelationshipWithoutIntermediates` verifies intermediates are excluded and shared final-hop records dedupe; `servesNestedRelationshipEndpoints` covers the related/relationship endpoints and the PATCH 403), error mapping, content negotiation, and the root meta document.

```bash
sf project deploy start --source-dir force-app/main/default/classes
sf apex run test --class-names JsonApiRouterTest --result-format human --wait 10
```

Note: deploying with `--test-level RunSpecifiedTests` enforces 75% coverage _per class touched_; `JsonApiRegistry` and `JsonApiRouter` currently sit just below that, so deploy without a test level to a dev org and run the suite separately.

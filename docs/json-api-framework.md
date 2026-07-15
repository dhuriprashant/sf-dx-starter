# JSON:API Framework for Salesforce

A custom Apex REST framework that serves SObjects following the [JSON:API v1.1 specification](https://jsonapi.org/format/). Mounted at:

```
https://<my-domain>.my.salesforce.com/services/apexrest/jsonapi
```

## Endpoints

| Method | Path                                | Purpose                                   |
| ------ | ----------------------------------- | ----------------------------------------- |
| GET    | `/`                                 | List registered resource types (meta)     |
| GET    | `/{type}`                           | List resources (paginated)                |
| GET    | `/{type}/{id}`                      | Fetch one resource                        |
| GET    | `/{type}/{id}/{rel}`                | Fetch related resource(s)                 |
| GET    | `/{type}/{id}/relationships/{rel}`  | Fetch relationship linkage (identifiers)  |
| POST   | `/{type}`                           | Create (returns 201 + `Location` header)  |
| PATCH  | `/{type}/{id}`                      | Partial update                            |
| PATCH  | `/{type}/{id}/relationships/{rel}`  | Replace a to-one linkage (`data: null` clears it) |
| DELETE | `/{type}/{id}`                      | Delete (returns 204)                      |

## Supported query parameters

- `include=contacts` — compound documents; related resources land in `included`, and to-many linkage appears under `relationships.{rel}.data`. Dot-paths (`include=contacts.reportsTo`) are not supported; instead a nested path can be registered under a direct alias (e.g. `contactManagers`) per the [spec's alternative-name provision](https://jsonapi.org/format/#fetching-includes) — `include=contactManagers` then returns the final-hop resources without the intermediate ones.
- `fields[accounts]=name,industry` — sparse fieldsets per resource type.
- `sort=-name,createdAt` — `-` prefix means descending. Attributes must be exposed on the resource.
- `page[number]=2&page[size]=20` — offset pagination (max size 200). Responses carry `first`/`prev`/`next`/`last` links and `meta.totalResources`.
- `filter[name]=Acme` — equality filter; comma-separated values become an `IN` clause. Multiple filters AND together.

Requests with a body must use `Content-Type: application/vnd.api+json` (or `application/json`); responses are always `application/vnd.api+json`. Errors follow the JSON:API error-object format with `status`, `title`, `detail`, and `source` pointers.

## Exposing a new SObject

Add a definition in `JsonApiConfig.registerAll()`:

```apex
JsonApiRegistry.register(
    new JsonApiResourceDefinition('opportunities', 'Opportunity')
        .attribute('name', 'Name')
        .attribute('stage', 'StageName')
        .attribute('amount', 'Amount')
        .attribute('closeDate', 'CloseDate')
        .toOne('account', 'AccountId', 'accounts')   // lookup on this object
);
// and on the parent side:
// .toMany('opportunities', 'opportunities', 'AccountId')  // FK field on the child
// alias a nested path (each segment a direct relationship on the previous type):
// .nested('opportunityAccounts', new List<String>{ 'opportunities', 'account' })
```

Nested relationships are read-only: they can be `include`d and served from `/{type}/{id}/{rel}` and `/{type}/{id}/relationships/{rel}`, but PATCHing them returns 403.

Only attributes you list are readable/writable through the API — everything else is rejected with a 400 and a JSON:API source pointer.

## Architecture

| Class                       | Responsibility                                            |
| --------------------------- | --------------------------------------------------------- |
| `JsonApiRouter`             | `@RestResource` entry point, routing, content negotiation |
| `JsonApiConfig`             | Resource registrations (edit this to expose objects)      |
| `JsonApiRegistry`           | Type → definition lookup                                  |
| `JsonApiResourceDefinition` | Attribute/relationship mapping for one resource type      |
| `JsonApiQueryParams`        | Parses/validates include, fields, sort, page, filter      |
| `JsonApiService`            | Generic CRUD engine (SOQL building, includes, pagination) |
| `JsonApiSerializer`         | Resource objects, documents, links, error documents       |
| `JsonApiException` / `JsonApiError` | Error semantics per the spec                      |

Security: every query and DML runs with `AccessLevel.USER_MODE` under `with sharing`, so FLS, object permissions, and sharing rules of the calling user are enforced. Filter/sort/include values are validated against the resource definition and bound as SOQL bind variables — no dynamic SOQL injection surface.

## Example

```bash
sf org open  # or use any OAuth token
curl -H "Authorization: Bearer $TOKEN" \
     -H "Accept: application/vnd.api+json" \
  "https://<my-domain>.my.salesforce.com/services/apexrest/jsonapi/accounts?include=contacts&fields[contacts]=firstName,lastName&sort=-name&page[size]=10"
```

Create a contact linked to an account:

```bash
curl -X POST -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/vnd.api+json" \
     -d '{
       "data": {
         "type": "contacts",
         "attributes": { "firstName": "Ada", "lastName": "Lovelace" },
         "relationships": {
           "account": { "data": { "type": "accounts", "id": "001XXXXXXXXXXXX" } }
         }
       }
     }' \
  "https://<my-domain>.my.salesforce.com/services/apexrest/jsonapi/contacts"
```

## Deploy & test

```bash
sf project deploy start --source-dir force-app/main/default/classes
sf apex run test --class-names JsonApiRouterTest --result-format human --wait 10
```

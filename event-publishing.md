# Salesforce Change Notification Design

## Overview

When records are created, edited, or deleted on certain Salesforce objects and certain fields are modified, Salesforce can notify consumer apps of those changes. This document covers all available options.

---

## Options Summary

### 1. Change Data Capture (CDC) — Best Fit

Salesforce's native solution for exactly this use case.

- Publishes change events automatically on create/update/delete/undelete
- Supports field-level filtering (only send changed fields)
- Consumer apps subscribe via CometD, Pub/Sub API, or Apex triggers
- Supports standard and custom objects
- Replay ID support — consumers can catch up on missed events (72-hour retention)
- **Limit:** 5 objects free; more require add-on licenses

### 2. Platform Events — Most Flexible

Custom event schema you publish explicitly (usually from Apex triggers or Flows).

- You control exactly when and what gets published
- Consumer apps subscribe via CometD, Pub/Sub API, webhooks (via middleware), or Apex
- Good when you need custom filtering logic (e.g., only notify if `Status = 'Closed'`)
- Requires you to write the publishing logic (Apex trigger + `EventBus.publish()`)
- 72-hour event retention with replay support

### 3. Streaming API (PushTopic) — Legacy

SQL-like query defines what records/fields trigger notifications.

- `SELECT Id, Name, Status__c FROM Opportunity WHERE Status__c = 'Closed'`
- Consumers subscribe via CometD
- **Avoid for new designs** — Salesforce recommends CDC/Platform Events over this

### 4. Outbound Messages (Workflow/Flow) — Simple but Limited

SOAP-based, sends XML payload to an external HTTPS endpoint.

- No coding required — configured via Workflow Rules or Flow
- Only fires on create/update, **not delete**
- No retry visibility, no replay — fire and forget
- Good for simple use cases with a small number of fields

### 5. Apex Callouts (REST/GraphQL) — Full Control

Trigger-based HTTP callouts to any external endpoint.

- Maximum flexibility — any HTTP method, any payload shape
- Async via `@future` or Queueable Apex to avoid governor limits
- No built-in replay/retry — you must build that
- Risk of hitting callout governor limits at high volume

---

## Decision Matrix

| Requirement | Recommended Option |
|---|---|
| Standard pattern, minimal code | **CDC** |
| Custom field filtering / conditional logic | **Platform Events** |
| Consumer is external REST endpoint | **Platform Events + Middleware (MuleSoft/AWS EventBridge)** |
| Simple update notification, no delete needed | **Outbound Messages** |
| Full custom payload, low volume | **Apex Callouts** |

---

## Recommended Architecture

For most enterprise use cases:

```
Salesforce Object (CRUD)
    → CDC or Platform Events
        → Salesforce Pub/Sub API
            → Middleware (MuleSoft / AWS EventBridge / Azure Service Bus)
                → Consumer Apps
```

---

## How Change Data Capture (CDC) Works

### High-Level Flow

```
Record Change (CRUD)
    → Salesforce automatically publishes a Change Event
        → Event Bus (retained 72 hours)
            → Subscribers receive the event
```

Salesforce handles the publishing side entirely — no code needed to produce events.

### The Change Event Payload

Every change event has two parts:

**Header** (metadata about the change):
```json
{
  "ChangeEventHeader": {
    "entityName": "Account",
    "changeType": "UPDATE",
    "changedFields": ["Name", "Phone"],
    "recordIds": ["001xx000003GYn1"],
    "transactionKey": "...",
    "sequenceNumber": 1,
    "commitTimestamp": 1720000000000,
    "commitUser": "005xx000001SwSi"
  }
}
```

**Body** (new values of changed fields only — not the full record):
```json
{
  "Name": "Acme Corp Updated",
  "Phone": "415-555-1234"
}
```

On DELETE, the body is empty — only the record ID is in the header.

### Enabling CDC

```
Setup → Integrations → Change Data Capture
    → Move objects from "Available" to "Selected"
```

No Apex or triggers needed.

### How Consumers Subscribe

**Option A: Pub/Sub API (gRPC)** — recommended for external apps
```
Consumer connects via gRPC
    → Subscribes to /data/AccountChangeEvent
        → Streams events in real time
```

**Option B: CometD / Bayeux Protocol** — for legacy or browser-based consumers
```javascript
client.subscribe('/data/AccountChangeEvent', function(message) {
    console.log(message.data.payload.ChangeEventHeader.changeType);
});
```

**Option C: Apex Trigger on Change Event** — for in-Salesforce processing
```apex
trigger AccountCDC on AccountChangeEvent (after insert) {
    for (AccountChangeEvent event : Trigger.new) {
        EventBus.ChangeEventHeader header = event.ChangeEventHeader;
        if (header.changeType == 'UPDATE') {
            // react to the change inside Salesforce
        }
    }
}
```

### Replay / Catch-Up Mechanism

Events are stored for **72 hours**. Consumers can catch up on missed events using a Replay ID:

```
replayId = -1   → receive new events from now
replayId = -2   → receive ALL stored events (up to 72 hours back)
replayId = 1234 → resume from a specific point
```

### Channel Naming Convention

| Object | CDC Channel |
|---|---|
| Account | `/data/AccountChangeEvent` |
| Contact | `/data/ContactChangeEvent` |
| Custom Object (`Order__c`) | `/data/Order__ChangeEvent` |
| All objects at once | `/data/ChangeEvents` |

### Key Limits

| Limit | Value |
|---|---|
| Free objects (Standard/Custom) | 5 total |
| Event retention | 72 hours |
| Max event delivery per hour | 25,000 (Enterprise) |
| Max subscribers per channel | 1,000 |

---

## CDC Field-Level Filtering

**CDC cannot be configured to only publish events when specific fields change.** CDC publishes an event on every create/update/delete regardless of which fields changed. There are two workarounds:

### Option 1: Filter on the Consumer Side

```javascript
client.subscribe('/data/AccountChangeEvent', function(message) {
    const changedFields = message.data.payload.ChangeEventHeader.changedFields;
    const watchedFields = ['Status__c', 'Revenue__c'];

    const relevant = changedFields.some(f => watchedFields.includes(f));
    if (!relevant) return; // ignore this event

    // process the change
});
```

### Option 2: Platform Events with an Apex Trigger

Only publishes when specific fields change — filtering at the source:

```apex
trigger AccountTrigger on Account (after insert, after update, after delete) {
    List<My_Change_Event__e> events = new List<My_Change_Event__e>();

    for (Account newAcc : Trigger.new) {
        Account oldAcc = Trigger.oldMap?.get(newAcc.Id);

        if (oldAcc == null
            || newAcc.Status__c != oldAcc.Status__c
            || newAcc.Revenue__c != oldAcc.Revenue__c) {

            events.add(new My_Change_Event__e(
                Record_Id__c = newAcc.Id,
                Status__c    = newAcc.Status__c,
                Revenue__c   = newAcc.Revenue__c
            ));
        }
    }

    if (!events.isEmpty()) EventBus.publish(events);
}
```

### Filtering Approach Decision

| Scenario | Approach |
|---|---|
| Low event volume, simple filtering | CDC + consumer-side filter |
| High volume, don't want to overwhelm consumers | Platform Events + Apex trigger |
| Multiple consumers with different field interests | Platform Events |
| No code budget, quick setup | CDC + consumer-side filter |

---

## PushTopic (Streaming API)

### Creating a PushTopic

```apex
PushTopic pt = new PushTopic();
pt.Name = 'AccountStatusChanges';
pt.Query = 'SELECT Id, Name, Status__c, Revenue__c FROM Account WHERE Status__c = \'Active\'';
pt.ApiVersion = 59.0;
pt.NotifyForOperationCreate = true;
pt.NotifyForOperationUpdate = true;
pt.NotifyForOperationDelete = true;
pt.NotifyForFields = 'Referenced';
insert pt;
```

### The `NotifyForFields` Setting

| Value | Behavior |
|---|---|
| `Referenced` | Only notify if a field **in your SELECT** changed |
| `Select` | Same as Referenced |
| `Where` | Only notify if a field **in your WHERE** changed |
| `All` | Notify on any field change |

With `Referenced` and `SELECT Id, Name, Status__c, Revenue__c`:
- Status changes → notification fires
- Revenue changes → notification fires
- Phone changes → **no notification** (not in SELECT)

### The Event Payload

```json
{
  "channel": "/topic/AccountStatusChanges",
  "data": {
    "event": { "type": "updated", "replayId": 8 },
    "sobject": {
      "Id": "001xx000003GYn1",
      "Name": "Acme Corp",
      "Status__c": "Active",
      "Revenue__c": 500000
    }
  }
}
```

Unlike CDC, the payload contains **all SELECT fields**, not just the ones that changed.

### PushTopic vs CDC vs Platform Events

| Feature | PushTopic | CDC | Platform Events |
|---|---|---|---|
| Field-level filter at source | Yes (`NotifyForFields`) | No | Yes (Apex logic) |
| Delete events | Limited | Full | Manual |
| Payload | Full SELECT fields | Changed fields only | Custom schema |
| Event retention | 24 hours | 72 hours | 72 hours |
| SOQL WHERE filtering | Yes | No | Yes (Apex logic) |
| Salesforce recommendation | Legacy | Preferred | Preferred |
| Setup effort | Low | Lowest | Medium |

### Why Salesforce Deprecated PushTopic

- No support for the newer **Pub/Sub API (gRPC)** — CometD only
- 24-hour retention vs 72 hours
- SOQL query evaluated per-record at high volume — performance concerns
- Limited to 50 PushTopics per org

---

## Knowing Which Field Value Changed

| | Changed field names | New value | Old value |
|---|---|---|---|
| CDC | Yes (`changedFields`) | Yes (in body) | No — must store externally |
| PushTopic | No — must diff | Yes (all SELECT fields) | No — must store externally |
| Platform Events | You design it | Yes (if you include it) | **Yes (Trigger.oldMap)** |

### CDC — New Value Only

CDC tells you what changed via `changedFields` but **does not include the old value**:

```json
{
  "ChangeEventHeader": {
    "changeType": "UPDATE",
    "changedFields": ["Status__c", "Revenue__c"]
  },
  "Status__c": "Closed",
  "Revenue__c": 750000
}
```

To get the old value you must store it yourself:
- Query Salesforce before processing (adds latency)
- Consumer maintains its own state/cache of last known values
- Use a separate History object (if field history tracking is enabled)

### PushTopic — Must Diff Against Stored State

```javascript
const previous = myCache.get(record.Id);
if (previous.Status__c !== record.Status__c) {
    // Status changed from previous.Status__c → record.Status__c
}
```

### Platform Events — Old and New Values Included

The only option where old value is natively in the event, because the Apex trigger has access to `Trigger.oldMap`:

```apex
trigger AccountTrigger on Account (after update) {
    List<Account_Change__e> events = new List<Account_Change__e>();

    for (Account newAcc : Trigger.new) {
        Account oldAcc = Trigger.oldMap.get(newAcc.Id);

        if (newAcc.Status__c != oldAcc.Status__c) {
            events.add(new Account_Change__e(
                Record_Id__c    = newAcc.Id,
                Field_Name__c   = 'Status__c',
                Old_Value__c    = oldAcc.Status__c,
                New_Value__c    = newAcc.Status__c
            ));
        }
    }

    EventBus.publish(events);
}
```

Consumer receives:
```json
{
  "Record_Id__c": "001xx...",
  "Field_Name__c": "Status__c",
  "Old_Value__c": "Active",
  "New_Value__c": "Closed"
}
```

**Platform Events is the only option where old value is natively included in the event**, because the Apex trigger has access to `Trigger.oldMap` at the moment the change happens.

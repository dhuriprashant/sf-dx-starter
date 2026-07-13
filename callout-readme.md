# Salesforce Apex Callouts — Complete Reference

---

## Table of Contents

1. [DML + Callout Restriction](#dml--callout-restriction)
2. [Passing a New Record ID in a Callout Payload](#passing-a-new-record-id-in-a-callout-payload)
3. [Queueable Platform Limits](#queueable-platform-limits)
4. [Concurrent Job Limit Explained](#concurrent-job-limit-explained)
5. [Observability for Custom Apex REST Services](#observability-for-custom-apex-rest-services)
6. [Logging: @future vs Queueable vs Platform Events](#logging-future-vs-queueable-vs-platform-events)

---

## DML + Callout Restriction

Salesforce enforces a hard rule: **you cannot perform a callout after a DML operation in the same transaction** (and vice versa).

```apex
// This THROWS: "You have uncommitted work pending. Please commit or rollback before calling out."
Account acc = new Account(Name = 'Test');
insert acc;                          // DML first
Http h = new Http();                 // Callout after DML — ERROR
h.send(new HttpRequest());
```

### Solutions

#### 1. Callout First, Then DML (simplest)

```apex
// Works fine — callout before DML
HttpResponse res = makeCallout();
Account acc = new Account(Name = res.getBody());
insert acc;
```

#### 2. `@future(callout=true)` — Async Callout After DML

```apex
public class MyService {
    public static void processRecord(Id recordId) {
        MyObject__c obj = new MyObject__c(Status__c = 'Processing');
        insert obj;

        sendCallout(obj.Id);
    }

    @future(callout=true)
    public static void sendCallout(Id recordId) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:My_Named_Credential/api/endpoint');
        req.setMethod('POST');
        new Http().send(req);
    }
}
```

**Limits:** `@future` methods can't return values, can't be chained easily, and accept only primitive/collection arguments.

#### 3. Queueable with `Database.AllowsCallouts` (recommended)

```apex
public class CalloutQueueable implements Queueable, Database.AllowsCallouts {
    private Id recordId;

    public CalloutQueueable(Id recordId) {
        this.recordId = recordId;
    }

    public void execute(QueueableContext ctx) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:My_Named_Credential/api/endpoint');
        req.setMethod('GET');
        HttpResponse res = new Http().send(req);

        // DML is fine here — it's a fresh transaction
        MyObject__c obj = [SELECT Id FROM MyObject__c WHERE Id = :recordId];
        obj.Response__c = res.getBody();
        update obj;
    }
}

System.enqueueJob(new CalloutQueueable(newRecord.Id));
```

#### 4. Platform Events / Change Data Capture (event-driven)

```apex
// Trigger publishes an event
trigger AccountTrigger on Account (after insert) {
    List<Callout_Event__e> events = new List<Callout_Event__e>();
    for (Account a : Trigger.new) {
        events.add(new Callout_Event__e(Record_Id__c = a.Id));
    }
    EventBus.publish(events);
}

// Separate trigger on the event does the callout
trigger CalloutEventTrigger on Callout_Event__e (after insert) {
    // callout logic here — separate transaction
}
```

### Quick Decision Guide

| Scenario | Use |
|---|---|
| Callout result needed before saving | Callout first, then DML |
| Fire-and-forget after save | `@future(callout=true)` |
| Need chaining, complex state, or result handling | `Queueable + AllowsCallouts` |
| Trigger-driven, decoupled architecture | Platform Events |

---

## Passing a New Record ID in a Callout Payload

Since you need the ID from an `insert` before making the callout, **Queueable** is the right pattern.

```apex
// CalloutQueueable.cls
public class CalloutQueueable implements Queueable, Database.AllowsCallouts {
    private Id recordId;

    public CalloutQueueable(Id recordId) {
        this.recordId = recordId;
    }

    public void execute(QueueableContext ctx) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:My_Named_Credential/api/endpoint');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');

        req.setBody(JSON.serialize(new Map<String, Object>{
            'salesforceId' => recordId,
            'source'       => 'Salesforce'
        }));

        HttpResponse res = new Http().send(req);

        if (res.getStatusCode() != 200) {
            // log or handle error
        }
    }
}
```

```apex
// In your service/handler class
public class AccountService {
    public static void createAndNotify(Account acc) {
        insert acc;  // acc.Id is populated after this line
        System.enqueueJob(new CalloutQueueable(acc.Id));
    }
}
```

```apex
// Trigger-driven — batch IDs to avoid hitting the 50 jobs/transaction limit
trigger AccountTrigger on Account (after insert) {
    Set<Id> ids = Trigger.newMap.keySet();
    System.enqueueJob(new CalloutQueueable(ids));
}
```

**Key points:**
- `insert acc` populates `acc.Id` in-place — pass it immediately to the Queueable constructor
- The Queueable runs in a new transaction, so there's no DML+callout conflict
- `after insert` is the right trigger context — record is committed and the ID is stable
- Batch IDs into one job to avoid the 50 queued jobs per transaction limit

---

## Queueable Platform Limits

### Enqueuing Limits

| Limit | Value |
|---|---|
| Max jobs enqueued per transaction | 50 |
| Max jobs enqueued from a `@future` | 1 |
| Max chained jobs | Unlimited in prod / **1 in sandbox** |
| Max jobs running concurrently | 5 (varies by org edition) |

### Execution Limits (per job)

| Limit | Value |
|---|---|
| Max CPU time | 60,000 ms |
| Max heap size | 12 MB |
| Max SOQL queries | 100 |
| Max DML statements | 150 |
| Max DML rows | 10,000 |
| Max callouts (with `AllowsCallouts`) | 100 |
| Max future calls from a Queueable | 50 |
| Execution timeout | 60 seconds (callouts) |

### Practical Gotchas

**Sandbox chaining limit:**
```apex
public void execute(QueueableContext ctx) {
    // In sandbox, this chain stops after 1 child job
    // In production, it chains indefinitely
    System.enqueueJob(new NextQueueable());
}
```

**50 jobs per transaction:**
```apex
// BAD — hits limit on bulk insert of 51+ records
for (Account acc : Trigger.new) {
    System.enqueueJob(new CalloutQueueable(acc.Id)); // Error at 51
}

// GOOD — one job handles all records
System.enqueueJob(new CalloutQueueable(Trigger.newMap.keySet()));
```

**Test context:**
```apex
Test.startTest();
System.enqueueJob(new CalloutQueueable(acc.Id));
Test.stopTest(); // job runs here
```

**Chaining with depth tracking:**
```apex
public class BatchQueueable implements Queueable, Database.AllowsCallouts {
    private List<Id> remaining;

    public BatchQueueable(List<Id> ids) {
        this.remaining = ids;
    }

    public void execute(QueueableContext ctx) {
        List<Id> batch = new List<Id>();
        for (Integer i = 0; i < 10 && !remaining.isEmpty(); i++) {
            batch.add(remaining.remove(0));
        }
        processRecords(batch);

        if (!remaining.isEmpty()) {
            System.enqueueJob(new BatchQueueable(remaining));
        }
    }
}
```

---

## Concurrent Job Limit Explained

Salesforce uses a **shared pool** of worker threads across all orgs on a server instance. Concurrent job limits control how many Queueable jobs can be **actively executing at the same time**.

### Limits by Org Edition

| Org Type | Concurrent Jobs |
|---|---|
| Developer Edition / Scratch Org | 1 |
| Professional / Enterprise | 5 |
| Unlimited / Performance | 5 |
| Sandbox | 5 |

### What "Concurrent" Actually Means

```
Timeline:

Job A enqueued ──► [RUNNING] ──────────────► DONE
Job B enqueued ──────► [RUNNING] ──────────► DONE
Job C enqueued ──────────► [RUNNING] ──────► DONE
Job D enqueued ──────────────► [WAITING] ──► [RUNNING] ──► DONE
Job E enqueued ──────────────────► [WAITING] ──────────► [RUNNING] ──► DONE
Job F enqueued ──────────────────────► [WAITING] ─────────────────► [RUNNING]

                 ◄── max 5 running at the same time ──►
```

Jobs beyond the limit sit in a queue and wait — they are not dropped or failed.

### Why This Matters

**Bulk triggers** flood the queue:
```
1,000 records inserted → 1,000 Queueable jobs enqueued
→ only 5 run at a time → 995 sit waiting → delay in external system
```

**Callout timeout compounds the problem:**
```
5 jobs running, all waiting on slow external API (30s each)
→ all 5 slots occupied for 30 seconds
→ new jobs can't start until a slot frees
```

### Monitor Queue Status

```apex
List<AsyncApexJob> jobs = [
    SELECT Id, Status, JobType, CreatedDate, CompletedDate
    FROM AsyncApexJob
    WHERE JobType = 'Queueable'
    AND Status IN ('Queued', 'Processing', 'Holding')
    ORDER BY CreatedDate DESC
    LIMIT 50
];
```

| Status | Meaning |
|---|---|
| `Holding` | In queue, waiting for a free worker slot |
| `Queued` | Ready to run, slot available soon |
| `Processing` | Actively executing |
| `Completed` | Done |
| `Failed` | Errored out |

### Mitigation Strategies

```apex
// 1. Batch records into one job
System.enqueueJob(new CalloutQueueable(Trigger.newMap.keySet()));

// 2. Set callout timeouts — don't let slow APIs hold your slots
HttpRequest req = new HttpRequest();
req.setTimeout(10000); // 10 seconds max

// 3. Use Batch Apex for very large volumes
Database.executeBatch(new MyBatchClass(recordIds), 200);
```

---

## Observability for Custom Apex REST Services

### Architecture Overview

```
Incoming Request
      │
      ▼
┌─────────────────┐
│  Request Logger │  ← who called, what params, timestamp
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Business Logic │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Response Logger │  ← status, duration, payload size
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Error Handler  │  ← structured error capture
└─────────────────┘
```

### 1. Custom Log Object (`API_Log__c`)

```
Fields:
  Endpoint__c         (Text)
  HTTP_Method__c      (Text)
  Request_Params__c   (Long Text)
  Response_Status__c  (Number)
  Response_Body__c    (Long Text)
  Duration_Ms__c      (Number)
  User__c             (Lookup: User)
  Correlation_Id__c   (Text)
  Error_Message__c    (Long Text)
  Stack_Trace__c      (Long Text)
```

### 2. Logger Utility Class

```apex
public class ApiLogger {

    public class LogEntry {
        public String correlationId;
        public String endpoint;
        public String method;
        public String requestParams;
        public Integer responseStatus;
        public String responseBody;
        public Long durationMs;
        public String errorMessage;
        public String stackTrace;
    }

    @future
    public static void saveLog(
        String correlationId,
        String endpoint,
        String requestParams,
        Integer responseStatus,
        String responseBody,
        Long durationMs,
        String errorMessage,
        String stackTrace
    ) {
        insert new API_Log__c(
            Correlation_Id__c  = correlationId,
            Endpoint__c        = endpoint,
            HTTP_Method__c     = 'GET',
            Request_Params__c  = requestParams,
            Response_Status__c = responseStatus,
            Response_Body__c   = responseBody,
            Duration_Ms__c     = durationMs,
            User__c            = UserInfo.getUserId(),
            Error_Message__c   = errorMessage,
            Stack_Trace__c     = stackTrace
        );
    }
}
```

### 3. REST Service with Full Observability

```apex
@RestResource(urlMapping='/products/*')
global class ProductRestService {

    @HttpGet
    global static void getProduct() {
        Long startTime = System.currentTimeMillis();
        RestRequest  req = RestContext.request;
        RestResponse res = RestContext.response;

        String correlationId = req.headers.get('X-Correlation-Id');
        if (String.isBlank(correlationId)) {
            correlationId = generateCorrelationId();
        }
        res.addHeader('X-Correlation-Id', correlationId);

        String requestParams = JSON.serialize(req.params);
        String errorMessage  = null;
        String stackTrace    = null;

        try {
            String productId = req.requestURI.substringAfterLast('/');

            if (String.isBlank(productId)) {
                res.statusCode = 400;
                res.responseBody = Blob.valueOf(errorResponse('Missing product ID', correlationId));
                return;
            }

            List<Product2> products = [
                SELECT Id, Name, ProductCode, IsActive
                FROM Product2
                WHERE Id = :productId
                LIMIT 1
            ];

            if (products.isEmpty()) {
                res.statusCode = 404;
                res.responseBody = Blob.valueOf(errorResponse('Product not found', correlationId));
                return;
            }

            res.statusCode = 200;
            res.addHeader('Content-Type', 'application/json');
            res.responseBody = Blob.valueOf(JSON.serialize(products[0]));

        } catch (Exception e) {
            errorMessage = e.getMessage();
            stackTrace   = e.getStackTraceString();
            res.statusCode = 500;
            res.responseBody = Blob.valueOf(errorResponse('Internal server error', correlationId));

        } finally {
            Long duration = System.currentTimeMillis() - startTime;
            String responseBody = res.responseBody != null ? res.responseBody.toString() : null;

            ApiLogger.saveLog(
                correlationId,
                req.requestURI,
                requestParams,
                res.statusCode,
                responseBody,
                duration,
                errorMessage,
                stackTrace
            );
        }
    }

    private static String errorResponse(String message, String correlationId) {
        return JSON.serialize(new Map<String, String>{
            'error'         => message,
            'correlationId' => correlationId
        });
    }

    private static String generateCorrelationId() {
        return EncodingUtil.convertToHex(Crypto.generateAesKey(128)).substring(0, 16);
    }
}
```

### 4. Governor Limit Tracking

```apex
private static Map<String, Object> captureLimits() {
    return new Map<String, Object>{
        'soqlQueries' => Limits.getQueries() + '/' + Limits.getLimitQueries(),
        'queryRows'   => Limits.getQueryRows() + '/' + Limits.getLimitQueryRows(),
        'cpuTime'     => Limits.getCpuTime() + '/' + Limits.getLimitCpuTime(),
        'heapSize'    => Limits.getHeapSize() + '/' + Limits.getLimitHeapSize(),
        'dmlStatements' => Limits.getDmlStatements() + '/' + Limits.getLimitDmlStatements()
    };
}
```

### 5. Platform Events for Real-Time Monitoring

```apex
EventBus.publish(new API_Log_Event__e(
    Correlation_Id__c  = correlationId,
    Duration_Ms__c     = duration,
    Response_Status__c = res.statusCode,
    Endpoint__c        = req.requestURI
));
```

### Observability Summary

| Layer | Mechanism |
|---|---|
| Request/response logging | `API_Log__c` via `@future` |
| Trace across systems | `X-Correlation-Id` header |
| Runtime debugging | `System.debug()` + Debug Logs |
| Governor limit visibility | `Limits.*` captured in log |
| Real-time alerting | Platform Events → external sink |
| Error capture | `try/catch/finally` with stack trace |

---

## Logging: @future vs Queueable vs Platform Events

### Comparison

| | `@future` | `Queueable` | Platform Events |
|---|---|---|---|
| Overhead | Minimal | Higher | Lowest |
| Use case fit | Fire-and-forget simple data | Complex state, chaining | High volume / real-time |
| Concurrent job slots used | No | Yes | No |
| Argument types | Primitives only | Any object via constructor | Primitive fields |
| Testability | Moderate | Better | Good |

### When Queueable Makes Sense for Logging

Only when your log entry requires **non-primitive data** that can't be serialized to strings for `@future`:

```apex
public class LogQueueable implements Queueable {
    private ApiLogger.LogEntry entry;

    public LogQueueable(ApiLogger.LogEntry entry) {
        this.entry = entry;
    }

    public void execute(QueueableContext ctx) {
        insert new API_Log__c(
            Correlation_Id__c  = entry.correlationId,
            Endpoint__c        = entry.endpoint,
            Duration_Ms__c     = entry.durationMs,
            Response_Status__c = entry.responseStatus,
            Error_Message__c   = entry.errorMessage,
            Stack_Trace__c     = entry.stackTrace
        );
    }
}
```

### Platform Events Approach (Best Decoupling)

```apex
// In the REST service — no async job consumed, no slot used
EventBus.publish(new API_Log_Event__e(
    Correlation_Id__c  = correlationId,
    Duration_Ms__c     = duration,
    Response_Status__c = res.statusCode,
    Endpoint__c        = req.requestURI
));
```

A separate trigger or Flow on `API_Log_Event__e` handles the actual `API_Log__c` insert.

### Decision Guide

```
Simple log fields (primitives)  →  @future          (least overhead)
Complex log object              →  Queueable        (only if needed)
High volume / real-time needs   →  Platform Events  (best decoupling)
```

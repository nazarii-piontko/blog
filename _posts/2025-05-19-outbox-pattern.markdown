---
layout:    "single"
classes:   "wide"
title:     "Transactional Outbox Pattern: From Theory to Production"
excerpt:   "When microservices need to update state and notify others at the same time, it’s easy to run into problems - lost events, race conditions, or partial failures. The transactional outbox pattern offers a practical way to ensure both data and events are handled reliably. This article breaks down how the pattern works, what makes it production-ready, and where things can go wrong."
tags:      "distributed-systems patterns outbox dotnet"
date:      "2025-05-19"
toc:       true
header:
 teaser: /assets/posts/outbox-pattern/logo.png
---

# Introduction

Imagine a microservices architecture. You're developing a warehouse inventory service. When items arrive from suppliers, two operations must succeed in sequence: updating inventory counts in the database and sending restock events to the product catalog service. If either fails - due to a transient error, for instance - you risk stock discrepancies or outdated product availability, affecting customer experience and sales. Consider another scenario in your users service. You store new user data and notify other services. Fail to send the notification, and users might be unable to access key features. Send the notification before confirming storage, and other services may act on non-existent data.

These are real risks in distributed systems. How can we ensure both database commits and event dispatches succeed together or not at all?

Enter the transactional outbox pattern or usually just outbox pattern: an elegant solution for maintaining data consistency across service boundaries.

# How It Works

The transactional outbox pattern introduces two additional components to ensure consistency between data changes and events dispatching in distributed systems: **Outbox Table** and **Relay Process**.

The **Outbox Table** is an additional database table used to temporarily store events that need to be published. This table resides in the same database as service’s core data and is written to in the same transaction.

For example, in the users service, when a new user is created, the application performs two operations in a single transaction:
- Inserts the new user record into the `users` table.
- Inserts a corresponding `UserCreated` event into the `outbox` table.

By bundling both writes into one transaction, we ensure that either both operations succeed or both are rolled back ([ACID](https://en.wikipedia.org/wiki/ACID) properties of database transactions).

There’s no strict standard for the outbox table schema, however, a very basic structure might look like this:

| Column Name   | Type                   | Description                                   |
|---------------|------------------------|-----------------------------------------------|
| `id`          | `INT` / `UUID`         | Unique identifier for the outbox event        |
| `event_type`  | `STRING`               | Type of the event (e.g., `UserCreated`)       |
| `payload`     | `JSON` / `TEXT`        | Serialized event body                         |
| `created_at`  | `TIMESTAMP`            | Time when the event was stored                |
| `sent_at`     | `TIMESTAMP` `NULLABLE` | Time when the event was dispatched (optional) |

This table schema can definitely be expanded with additional fields as needed, such as:
* `entity_id` and `entity_name` to track the domain object
* `retries`, `status`, or `error_message` for debugging or advanced error handling
* `correlation_id` for tracing

The **Relay Process** is a background process, also often called as **outbox processor** or **events dispatcher**. It periodically polls the outbox table for unsent events and publishes them to the messaging system (such as `RabbitMQ`, `AWS EventBridge`, `Azure Service Bus`, `Kafka`, etc.). Once an event is successfully sent, the relay process either marks the record as dispatched or deletes the record.

To better understand the architecture and events flow, here are two diagrams: *Components Diagram* and *Sequence Diagram*.

{% plantuml %}
skinparam backgroundColor transparent
skinparam defaultFontColor #eaeaea

skinparam componentBorderColor green
skinparam componentBackgroundColor black

skinparam databaseBorderColor green

skinparam queueBorderColor green
skinparam queueBackgroundColor black

skinparam arrowColor green

[Service] as service
[Relay Process] as relay

database "Database" {
  [Domain Tables] as domainDB
  [Outbox Table] as outboxDB
}

queue "Messaging System" as broker

service --> domainDB : "1. Update\ndomain\ndata"
service --> outboxDB : "2. Insert event\ninto\nOutbox Table"

relay --> outboxDB : "3. Polls for\nunsent\nevents"
relay --> broker : "4. Sends\nevents"
relay --> outboxDB : "5. Marks as\nsent/deletes"
{% endplantuml %}

Figure 1. Components Diagram - illustrates the core parts of the pattern: the service, the outbox table, the relay process, and the messaging system.


{% plantuml %}
skinparam backgroundColor transparent
skinparam defaultFontColor #eaeaea

skinparam noteBorderColor green
skinparam noteBackgroundColor black

skinparam databaseBorderColor green
skinparam databaseBackgroundColor black

skinparam queueBorderColor green
skinparam queueBackgroundColor black

skinparam sequence {
  ArrowColor green
  ActorBorderColor white
  LifeLineBorderColor green
  LifeLineBackgroundColor green

  ParticipantBorderColor green
  ParticipantBackgroundColor black

  ActorBorderColor green
  ActorBackgroundColor black

  DividerBackgroundColor black
  DividerBorderColor black

  group {
    BorderColor green
    BackgroundColor transparent
    LineThickness 1
  }
}

skinparam SequenceBoxBorderColor LightGreen

participant Client as client
participant "Service" as service
database "Database" as db
participant "Relay\nProcess" as relay
queue "Messaging\nService" as broker

== Transaction Phase ==

client -> service: Request\n(e.g. register user)
activate service

service -> db: Begin transaction
activate db

service -> db: Update domain data\n(e.g., insert User)
service -> db: Insert outbox entry\n(e.g. insert UserCreated)
note right: Both operations in\nthe same transaction

service -> db: Commit transaction
deactivate db

service --> client: Response
deactivate service

== Publishing Phase ==

relay -> db: Begin transaction
activate db

relay -> db: Select batch of\nunsent events

db --> relay: Return batch of\nevents

loop For each event
    relay -> broker: Publish event
    activate broker
    broker --> relay: Acknowledge
    deactivate broker
    
    relay -> db: Mark as sent or delete
    activate db
    db --> relay: Confirm update/delete
    deactivate db
end

relay -> db: Commit transaction
deactivate db
{% endplantuml %}
Figure 2. Sequence Diagram - shows the step-by-step lifecycle of a change, from transaction commit to event dispatch.

There are many articles that explain the transactional outbox pattern, and multiple libraries can help to implement it without much effort. For example, in .NET, [`MassTransit`](https://masstransit.io/) supports the [transactional outbox pattern](https://masstransit.io/documentation/patterns/transactional-outbox) and can handle events persistence automatically. But in real projects, it’s not always that easy. Sometimes we can’t use a library due to specific requirements or constraints. Other times, the library has limitations, or its features aren’t clearly documented. That’s when it becomes important to understand what to consider when running the transactional outbox pattern in production - how to make it stable, observable, scalable, and what trade-offs and failure modes to be aware of.

# Production Ready

## Safely Selecting Unsent Events in the Relay Process

At first glance, selecting unsent events might seem simple - just run a `SELECT` query to fetch a small batch (e.g. 10 rows) from the outbox table. But once we introduce **multiple relay instances** for scalability or fault tolerance, things get more complicated.

We need to ensure that:
- Each event is processed **only once**.
- Relay processes **don’t block or interfere** with each other unnecessarily.

To achieve this, we must add **row-level locking** to selection queries. This allows multiple relays to work safely in parallel without picking the same rows.

**`PostgreSQL`** offers a clean solution using `FOR UPDATE SKIP LOCKED`:

```sql
SELECT * FROM outbox
WHERE sent_at IS NULL
ORDER BY created_at
LIMIT 10
FOR UPDATE SKIP LOCKED;
```

* `FOR UPDATE`: locks the selected rows during the transaction.
* `SKIP LOCKED`: skips any rows already locked by other transactions.

**`MySQL 8.0`** and newer support the same `FOR UPDATE SKIP LOCKED` syntax, so the same approach applies directly.

In **`SQL Server`**, we can achieve similar behavior using locking hints:

```sql
SELECT TOP 10 *
FROM outbox WITH (ROWLOCK, UPDLOCK, READPAST)
WHERE sent_at IS NULL
ORDER BY created_at;
```

* `ROWLOCK`: enforces row-level locking (instead of page or table).
* `READPAST`: skips rows that are already locked by other transactions.
* `UPDLOCK`: acquires update locks instead of shared locks.

Choosing the right row-locking strategy helps keep relay process safe and reliable under load.

## Handling Mid-Batch Crashes

Let’s say the relay process grabs a batch of events, starts sending them and crashes halfway through. What then?

The good news is: if we’re using `FOR UPDATE SKIP LOCKED` (or equivalent), those unprocessed rows will become visible again once the transaction rolls back or the database connection closes. As long as we only mark events as sent after the broker confirms delivery, we're safe - nothing gets lost.

The downside? Some events might get retried. That’s fine if consumers handle duplicates (see idempotency), but it’s something to be aware of.

## Separating the Relay Process from the API Service

In many implementations, especially those guided by default library configurations like `MassTransit`, it's common to co-host the relay process. The background worker responsible for publishing events from the outbox within the main API service. This setup is convenient and works well for small-scale systems with low traffic or a limited number of replicas (typically fewer than five).

However, this strategy doesn’t scale well.

As service scales horizontally - say, to 10, 15, or even 30 replicas - each instance runs its own copy of the relay logic. This results in redundant and overlapping polling, where all instances query the outbox table at regular intervals (even a modest 25-50ms). What initially seemed like a harmless background task becomes a storm of database queries.

This creates two critical issues:

* **Database pressure and lock contention**. Every relay process instance attempts to acquire locks on the outbox table to safely claim and process events. These locks are not cheap. In one of my services with `Amazon Aurora`, I've started noticing that the database spends considerable CPU time managing locks, not executing queries.

* **Mismatched scaling profiles**. The core of the problem is architectural. API (REST API) traffic and relay process scale differently. API scales with user demand, which might require many instances to handle load. The outbox relay process, on the other hand, scales with write throughput - that is, how many new events are added to the outbox table. In many real-world systems, a single relay process instance is enough to handle even high volumes of events. Scaling it beyond that typically yields no benefit and only introduces locking and concurrency overhead.

The better approach is to **separate the relay process from the API instance** and run them as independent deployment units. They can still live in the same codebase but should be deployed with different configurations. For instance, one deployment might have the relay process enabled while another disables it and only handles HTTP traffic. This way, each component scales on its own terms. `MassTransit` supports this model. It is possible to control whether the relay process runs at startup using configuration (search for `DisableDeliveryService`).

## Handling At-Least-Once Delivery

It’s easy to overlook, but the transactional outbox pattern guarantees **at-least-once delivery** - not exactly-once. This means that due to transient failures (e.g., network issues, broker timeouts, retries), consumers might receive duplicate events. If downstream processing isn't prepared for this, it risks inconsistent state or triggering actions multiple times (e.g., sending duplicate emails or creating double charges).

To deal with this, there are two main options:

* **Make logic idempotent**. Design consumers so they can safely handle the same event more than once. For example, inserting a record only if it doesn’t exist.

* **Deduplicate events explicitly**. Maintain a **separate table** (aka `inbox` table) to store processed event IDs for a defined retention period (e.g. one hour, six hours, or even a few days). Before handling a event, the consumer checks this store. If the ID is found, the event is skipped; otherwise, it's processed and the ID is saved.

The event ID in `inbox` table must be globally unique - not just the domain entity’s ID. A single entity (e.g., a user or product) can generate multiple distinct events over time, and all of them must be independently tracked.

## Handling Out-of-Order Delivery

Besides duplicates, **out-of-order events delivery** is another common edge case in real-world deployments. This can happen due to:
* Multiple relay processes. When several instances read and dispatch events in parallel, event order is not guaranteed.
* Multiple consumer instances. Concurrent processing can lead to events being handled in a different order than they were created.
* Due to async retries or varying event latency some events could be delayed, while others no.

What can be done to handle this:
* Including a timestamp in the event payload and resolve conflicts based on event time.
* Including a entity version number (or sequence ID) in the event payload and resolve conflicts based on version.
* Using message brokers that support ordering guarantees (e.g., Kafka partitions or Azure Service Bus sessions) if messages grouping by entity key is possible. Still, this alone does not eliminate issues on the producer side - out-of-order inserts into the outbox table or race conditions during transaction commits can still lead to event disorder.

Designing for eventual consistency often means tolerating some degree of event disorder, but planning for it upfront ensures a more resilient system.

## Don’t Forget Database Maintenance

**Outbox (and inbox) tables tend to grow** silently in the background. With every new event or processed event, a new row gets added. It’s easy to overlook this at first. In systems with moderate traffic and decent indexing, performance might hold up fine even with hundreds of thousands of records.

But over time, things change. Queries that once ran instantly start to slow down. The database has to sift through more data, manage larger indexes, and handle more storage. Fetching new events or checking for duplicates becomes more expensive. Left unchecked, this can lead to subtle but persistent performance issues.

That’s why it’s important to build in regular cleanup of both outbox and inbox tables. For the outbox, once a event has been successfully dispatched, it can often be removed immediately, unless there's a need to keep it around for debugging or auditing. For the inbox, the retention window depends on how long duplicate events are expected to arrive. In most systems, keeping processed event IDs for a few hours to a couple of days is enough to cover retries and delayed deliveries.

There’s no one-size-fits-all schedule, some systems might clean up every few hours, others daily. What matters is that **cleanup is automatic and consistent**. It doesn’t need to be complex. Just enough to keep things running smoothly and prevent silent degradation over time.

## Observability

The transactional outbox pattern implicitly introduces a **secondary queue** into system - one that exists within database, independent of messaging system. Most teams already monitor their messaging systems (e.g., RabbitMQ dashboards, Kafka exporters, Azure metrics), but the outbox itself often goes unobserved, especially when it’s implemented manually or using lightweight libraries.

This oversight can be dangerous. The outbox is effectively a queue, and like any queue, it **requires monitoring** to ensure inflow and outflow stay balanced. If the relay process can’t keep up, queue grows, introducing latency in event propagation, and eventually, customer-facing lag or missed actions.

At a minimum, we should monitor:
* The average age of unsent events - indicates how long events are waiting to be dispatched.
* Rate of incoming events - how fast new events are being added to the outbox.
* Rate of outgoing events – how fast the relay is processing and dispatching events.
* Errors within relay process.

When these metrics drift apart - e.g., event age rising, or inflow consistently outpacing outflow - it’s a signal that something is wrong, the relay is failing, overloaded, or misconfigured.

Modern runtimes like .NET make it easy to instrument this kind of telemetry using OpenTelemetry, Prometheus exporters, or Application Insights. Don’t guess - observe. Set up alerts, visualize trends, and establish baselines.

This kind of visibility is especially critical because the outbox pattern operates under eventual consistency. For some domains, a few seconds of delay might be acceptable. For others, even short delays can introduce real risk.

> I once worked on a system with an internal currency mechanism. Users could spend internal currency on incentives. The balance deduction logic used an eventually consistent pipeline with an transactional outbox pattern. While we had safeguards, especially to roll back transactions if users didn’t have enough points, timing mattered. A user could trigger multiple transactions before the first slow deduction processed - and effectively "overspend". Since some incentives involved real goods, this caused a serious incident.<br><br>Had we monitored the outbox queue itself, not just the external broker, we could have spotted the delay early, throttled users, or paused processing. Instead, the backlog built silently.<br><br>The root cause was the lack of separation between the API and the relay process.

Rule of thumb: when a new queue is introduced (explicit or implicit), we **MUST also introduce new monitoring**. Without it, we’re flying blind.

# Wrapping Up

The transactional outbox pattern might seem simple at first glance. Just write an event to a table and send it later. But like most things in distributed systems, the devil is in the details. Making it work reliably in production means thinking about:
* How to safely select unsent events without collisions.
* Where the relay process should live and how it should scale.
* What to do with duplicates or events arriving out of order.
* How to keep the database healthy over time.
* And how to monitor the whole thing so you’re not flying blind when things slow down.

If these parts are ignored, problems don’t show up immediately. They sneak in gradually - longer delays, subtle inconsistencies, and performance cliffs that are hard to debug when it’s already too late. But with the right approach, the transactional outbox pattern becomes a solid foundation for building resilient, event-driven systems.

For most teams, especially when starting out, using a ready-to-use library is the best move. Libraries like `MassTransit` for .NET or `Axon Framework` for `Java` take care of the boilerplate and edge cases, allowing to focus on domain logic. If you can fit them into your stack and constraints, use them. Just be sure you understand how they behave in production, especially around delivery guarantees, scaling, and observability.

This article focused on the classic outbox setup - write to database, regularly poll the database inside relay process. But this isn’t the only way.

In the next article, I’ll look at other implementation options - ways to reduce lag and scale better. Coming soon.

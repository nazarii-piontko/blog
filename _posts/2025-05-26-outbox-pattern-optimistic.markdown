---
layout:    "single"
classes:   "wide"
title:     "Transactional Outbox Pattern: Now with Optimistic Sending"
excerpt:   "The standard transactional outbox pattern ensures consistency but adds latency and load. This article introduces optimistic sending - a simple upgrade that tries to publish events immediately and falls back only if needed. Faster, lighter, just as reliable."
tags:      "distributed-systems patterns outbox dotnet"
date:      "2025-05-26"
header:
 teaser: /assets/posts/outbox-pattern/logo.png
---

In the [previous article](/_posts/2025-05-19-outbox-pattern), I described the **standard transactional outbox pattern** - a practical solution for ensuring that both database operations and event dispatches succeed together, or not at all. It’s a clever workaround for the fact that distributed systems don’t support distributed transactions out of the box. By using an **Outbox Table** and a background **Relay Process**, we can keep our services decoupled while maintaining consistency guarantees.

But once it's implemented and especially once it hits production you start to notice its rough edges.

Polling introduces lag into the system. Even if the polling interval is short, say, 50ms or 100ms - there’s still a gap between when a business operation completes and when its corresponding event gets published. And the worst part, that lag isn’t even predictable. It depends on poll timing, system load, database response time, and more. Sometimes it’s 50ms, sometimes it’s 2 seconds, sometimes it's even more. In addition to that, regular polling creates pressure on the database. It might look like "it's just one small `SELECT` query every so often". But few polling replicas, expensive locking functionality, and simple "`SELECT` query" starts to utilize quite significant portion of database CPU, I/O, locks. In a system I worked on using Amazon RDS, it was a reason of quite nasty incident. And finally, last but not least - monitoring, the standard transaction outbox pattern require solid monitoring. Many forget about it until it's too late. Some libraries provide monitoring capabilities out fo the box but not all do.

So what are our options to improve performance of standard transactional outbox pattern implementation. I call it **Optimistic Sending** (maybe it is not fully correct name but still).

Let’s start with a quick thoughtful experiment. Say a single-instance AWS RDS database guarantees 99.5% uptime, and AWS SQS guarantees 99.9%. These aren’t edge-case numbers, it possible to archive even higher numbers for uptime in AWS or Azure/GCP. Nevertheless, what is combine uptime of RDS and SQS in this case - slightly higher then 99.4% (0.999 * 0.995). It means that we can expect failure for about 0.6% of time. It's about **1m 26s daily** and **10m weekly**. Not that bad - right? In reality it's even better than that, we can expect fails for individual transactions/events per day.

So, what does it give us? Let's do the small shift in mindset, not architecture. We still write events to the outbox table and still have the relay process running - nothing critical gets removed. However, after committing a transaction, we **immediately try to send the event to the broker**:

* If it works? ✅ We clean up the outbox row (either delete or mark as sent).
* If it fails? ❌ We do nothing. The relay process will pick it up later, just like it always would.

The outbox goes from being the **default queue** to a **backup queue**, relay process become a **failure-handling fallback**. So, we are not removing the relay process, it just gets **less work**. It still polls the database, but more rarely, only looking for messages that didn't make it out for certain period of time, say, 30 seconds. Also we safely can leave one relay process instead of trying to improve it. In a perfect and most probable scenario the relay never actually sends anything.

Here’s a high-level flow of the happy path vs fallback:

{% plantuml %}
skinparam backgroundColor transparent
skinparam defaultFontColor #eaeaea

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
queue "Messaging\nService" as broker
participant "Fallback\nRelay\nProcess" as relay

== Happy Path ==

client -> service: Request\n(e.g. register user)
activate service

service -> db: Begin transaction
activate db

service -> db: Update domain data\n(e.g., insert User)
service -> db: Insert outbox entry\n(e.g. insert UserCreated)
service -> db: Commit transaction
deactivate db

service -> broker: Publish events
activate broker
broker --> service: Acknowledge
deactivate broker

service -> db: Mark events as\nsent or delete
activate db
db --> service: Confirm update/delete
deactivate db

service --> client: Response
deactivate service

== Fallback Path ==

relay -> db: Begin transaction
activate db

relay -> db: Select batch of\nunsent events\nwhich are unsent for "too long"

db --> relay: Return batch of\nunsent events

relay -> broker: Publish events
activate broker
broker --> relay: Acknowledge
deactivate broker
    
relay -> db: Mark events as sent or delete
activate db
db --> relay: Confirm update/delete
deactivate db

relay -> db: Commit transaction
deactivate db
{% endplantuml %}

And here is a simple C# example:

```csharp
/// <summary>
/// Creates a user and tries to send a `UserCreated` event optimistically.
/// </summary>
public async Task CreateUserAsync(UserDto input)
{
    // Create domain object
    var user = new User { Id = Guid.NewGuid(), Email = input.Email };
    _dbContext.Users.Add(user);


    // Prepare outbox event alongside domain entity
    var userCreatedEvent = new UserCreated { user.Id, user.Email }
    var outboxEvent = new OutboxEvent
    {
        Id = Guid.NewGuid(),
        EventType = userCreatedEvent.GetType().Name,
        Payload = JsonSerializer.Serialize(userCreatedEvent),
        CreatedAt = DateTime.UtcNow
    };
    _dbContext.OutboxEvents.Add(outboxEvent);
    
    // Atomic insert of domain state and outbox event to database
    await _dbContext.SaveChangesAsync();

    try
    {
        // Attempt to publish right after commit
        await _eventPublisher.PublishAsync(outboxEvent);

        // Mark sent event for deletion
        _dbContext.OutboxEvents.Remove(outboxEvent);

        // Send delete command to database
        await _dbContext.SaveChangesAsync();
    }
    catch (Exception ex)
    {
        _logger.LogWarning(ex, "Optimistic send failed. Relay will handle it.");
    }
}

```

Now let's examine potential issues with this approach:

* Because of most events get sent immediately and a few get delayed, the order of delivery isn’t guaranteed, if order matters, the consumers need to handle it or this implementation is not an option for that particular problem. To be honest, the standard implementation also does not guarantee in-order delivery by default.
* If the fallback logic has "too short" acceptable delay window, the system might have too many duplicates, but as with any other **at-least-once delivery** the consumer should handle it.
* The observability is still needed. Observability is inevitable, but this time it might be slightly simpler.

The good about this approach: we don’t have to rebuild anything, just slightly upgrading the default path. If you already using something like MediatR or any cross-cutting concern implementation for sending outbox event, it just a simple upgrade in just a few places of your codebase.

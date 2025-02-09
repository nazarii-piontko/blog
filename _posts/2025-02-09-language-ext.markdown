---
layout:    "single"
classes:   "wide"
title:     "Practical Functional Programming in C#: Using Option and Result Patterns"
excerpt:   "Discover how to leverage functional programming patterns in C# to write more maintainable and error-resistant code. Learn practical applications of Option and Result types using Language.Ext, moving beyond null checks and exception handling to create more explicit and safer code without sacrificing readability."
tags:      "dotnet csharp"
date:      "2025-02-09"
---

# Introduction

Code maintainability typically correlates with code clarity and explicit statements (less "magic" in code). While exceptions might be found in Proof of Concepts implementations, in production code this correlation stays strong. In this article, I'll try show how three useful concepts from functional programming can help with code clarity.

C# is a multi-paradigm language, but most C# developers treat it as object-oriented only, often seeing functional programming concepts as unnecessary complexity. While I'm not a fan of using functional programming for everything, I've found some concepts quite useful - and I'll explain them here.

For this journey into functional concepts, we'll use [Language.Ext](https://github.com/louthy/language-ext) - a popular C# library that extends the language's functional programming capabilities. While C# gives us LINQ, lambdas, and pattern matching out of the box, `Language.Ext` adds a rich set of functional programming tools that integrate seamlessly with the language. The library is extensive, but let's focus on two practical concepts we can start using in code today: `Option` and `Result`. Interesting fact, Microsoft plans to add `Option` and `Result` in their future language updates: [https://github.com/dotnet/csharplang/blob/main/proposals/TypeUnions.md#common-unions](https://github.com/dotnet/csharplang/blob/main/proposals/TypeUnions.md#common-unions)

To add `Language.Ext` to our project, we need to add Nuget package [LanguageExt.Core](https://www.nuget.org/packages/LanguageExt.Core).

# Option

The first concept is an `Option<A>`. It's implemented as `readonly struct Option<A>` in `Language.Ext`. The purpose of `Option<A>` is to explicitly represent a value that may or may not exist - in most cases, to make nullability explicit in the code. While C# has nullable reference types, `Option<A>` provides a better approach to handling such cases.

Where might this be useful? Imagine we have a user repository with a method to get a user by email. Traditionally, we might write something like this:

```csharp
public interface IUserRepository
{
    Task<User?> GetByEmailAsync(string email);
}

public class UserRepository(MyDbContext db) : IUserRepository
{
    public Task<User?> GetByEmailAsync(string email)
    {
        var user = await db.Users.FirstOrDefaultAsync(u => u.Email == email);
        return user;
    }
}

public class UserService(IUserRepository repository)
{
    public async Task<bool> ProcessUserAsync(string email)
    {
        var user = await repository.GetByEmailAsync(email);
        if (user != null)
        {
            // Do some actions with a user
            return true;
        }
        else
        {
            // Handle missing user or just return
            return false;
        }
    }
}
```

This code has several issues. First, the nullability is implicit - we need to check the return type and remember to handle the null case. Second, it's easy to forget the null check, leading to potential runtime errors. Third, the null handling pattern leads to nested if-else statements that can become hard to read.

Here's how we could rewrite this using `Option<T>`:

```csharp
public interface IUserRepository
{
    Task<Option<User>> GetByEmailAsync(string email);
}

public class UserRepository(MyDbContext db) : IUserRepository
{
    public async Task<Option<User>> GetByEmailAsync(string email)
    {
        var user = await db.Users.FirstOrDefaultAsync(u => u.Email == email);
        return user; // Only return type has been changed, the return statement stays the same due to implicit type casting
    }
}

public class UserService(IUserRepository repository)
{
    public Task<bool> ProcessUserAsync(string email)
    {
        return repository.GetByEmailAsync(email)
            .Match(
                Some: async user => 
                {
                    // Do some async/await actions with a user
                    return true;
                },
                None: () => 
                {
                    // Handle missing user or just return
                    return false;
                }
            );
    }
}
```

or if we are really not comfortable with `Match` then something like this:

```csharp
public class UserService(IUserRepository repository)
{
    public async Task<bool> ProcessUserAsync(string email)
    {
        var optionalUser = await repository.GetByEmailAsync(email);
        if (optionalUser.IsNone)
        {
            // Handle missing user or just return
            return false;
        }

        var user = optionalUser.ValueUnsafe();
        // Do some async actions with a user
        return true;
    }
}
```

The `Option` approach offers several benefits:
1. The possibility of a missing value is explicit in the type system
2. Pattern matching with `Match` ensures we handle both cases or making "null handling" more explicit
3. The intent is clearer - `Option<User>` tells other developers that this operation might not return a user

It is also important to note that `Option<A>` isn't meant to replace all nullable types in the code. We mostly should use it when we want to make the handling of missing values explicit and when working with domain logic where clarity about the possibility of missing values is important for maintaining correct business logic.

# Result & OptionalResult

The second concept worth exploring is `Result`: `OptionalResult<A>` and `Result<A>`. While `Option<A>` handles the presence or absence of a value, `OptionalResult<A>` adds another dimension - it can represent both missing values and failures. `Result<A>` represents two dimensions, existing value and failures. This makes it particularly useful when we need different handling strategies based on the context higher in the call stack.

Without using `Result` concept, the common approach to handle logical failures or hardware failures (like network issues) is through exceptions or even worth masking them with null (like returning null when e.g. Redis is not available). This has several drawbacks. First, method signatures don't indicate which exceptions might be thrown, requiring additional documentation. Second, exceptions make the code flow less explicit - we can't tell from looking at the code where exceptions are handled. Third, there's no compile-time enforcement ensuring that errors are handled appropriately higher in the call-stack - developers might forget to catch specific exceptions or handle them inappropriately. `Result` solves these problems by making error cases explicit in the type system - the method signature itself tells us that the operation might fail, and the compiler ensures we handle both success and failure cases. This leads to more maintainable and safer code where error handling is a visible part of the design rather than an afterthought.

Let's explore this with a caching scenario. Imagine we're implementing a caching layer for the application. When fetching data, several things could happen:
1. The data is found in the cache (success with value)
2. The cache is working but the data isn't there (success with no value)
3. The cache operation fails (failure with an exception)

Here's how we might implement this using `OptionalResult<A>`:

```csharp
public class CacheService(IDistributedCache cache)
{
    public async Task<OptionalResult<T>> GetAsync<T>(string key)
    {
        try
        {
            var data = await cache.GetAsync(key);
            return data == null 
                ? new OptionalResult<T>(Option<T>.None) // Success without value, cache miss
                : new OptionalResult<T>(Option<T>.Some(Deserialize<T>(data))); // Success with value
        }
        catch (Exception ex)
        {
            return new OptionalResult<T>(ex); // Cache operation failed
        }
    }
}
```

The `Match` method is the key to handling different cases. It provides a clear, pattern-matching approach to dealing with both the success/failure state and the presence/absence of a value. Here's a detailed look at the matching syntax:

```csharp
service
    .GetAsync<User>("user:1")
    .Match(
        Some: user => // Handle success with value
        None: () => // Handle success with no value
        Fail: ex => // Handle failure
    );
```

`OptionalResult<A>` shines when we need to handle errors differently across our application layers. Unlike throwing exceptions or returning null, it gives us a structured way to deal with both missing values and failures. Error handling becomes part of the method signature - making it impossible to forget about edge cases and letting us handle them appropriately based on context. In practice, this means fewer bugs from unhandled cases and code that clearly shows its intent to other developers.

# Conclusion

After exploring `Option<A>` and `OptionalResult<A>`/`Result<A>`, we can see how these patterns help write clearer, more maintainable code by making handling of edge cases explicit. While everyone could implement these concepts on their own and probably sometimes has to implement them if only one simple concept is required, `Language.Ext` brings a mature implementation with great C# integration and a whole ecosystem of related functional concepts.
Speaking of which, I recommend checking out other useful types from `Language.Ext`:

* `Fin<A>` for explicit error handling, supporting both exception and custom error cases. Starting from version 5 of `Language.Ext`, it will replace `Result<A>` as the primary way to represent operations that can fail. We should use this when we want explicit control over error cases, especially for business logic, validation, and other scenarios where failures are expected and should be handled explicitly.
* `Try<A>` for specifically designed for exception-prone operations. It automatically catches any exceptions that occur during execution and wraps them in a failure case. While it might be similar to `Fin<A>` it focuses on exceptions only.
* `Either<L, R>` for operations with two possible result types.

The goal here isn't to push functional programming everywhere - it's about having more tools in our toolbox. Use these patterns where they make sense: domain logic, places where being explicit about edge cases really matters. The rest of the codebase can stay as object-oriented as we want.
It's worth noting that while these functional types are excellent for internal module logic, they might not be the best choice for public APIs, especially when exposing them to external consumers. In microservices architecture, we can safely use them within each service's internal implementation or within a module in a modular monolith. However, for public-facing APIs or service boundaries, it's often better to stick with more conventional return types to avoid redundant dependency on third party library or "unknown" concepts.

Whether we start with `Language.Ext` or roll own implementation, the key is writing code that clearly shows its intent and systematically handles edge cases. That's what makes code a little bit more maintainable in the long run.

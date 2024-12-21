---
layout:    "single"
classes:   "wide"
title:     "C# async Exception Handling: Will This Crash Your Process?"
excerpt:   "C# async exception handling exhibits different behaviors based on method signatures. Article describes how 'async void' and 'async Task' handle exceptions when a method throws an exception."
tags:      "dotnet csharp async exceptions"
date:      "2024-12-20"
toc:       false
---

A colleague recently asked me about C# exception handling behavior with async/await keywords and TPL. His question was straightforward - which exception-throwing scenarios would crash the process? Here's a sample code that demonstrates different scenarios.

```csharp
Task.Run(VoidFunc);      // 1
VoidFuncAsync();         // 2
Task.Run(VoidFuncAsync); // 3
TaskFuncAsync();         // 4
Task.Run(TaskFuncAsync); // 5

await Task.Delay(5000); // Wait a bit for crash

static void VoidFunc() 
{
    Log("VoidFunc starting");
    throw new ApplicationException("VoidFunc");
}

static async void VoidFuncAsync()
{
    Log("VoidFuncAsync starting");
    await Task.Delay(500);
    Log("VoidFuncAsync wait finished");
    throw new ApplicationException("VoidFuncAsync");
}

static async Task TaskFuncAsync()
{
    Log("TaskFuncAsync starting");
    await Task.Delay(500);
    Log("TaskFuncAsync wait finished");
    throw new ApplicationException("TaskFuncAsync");
}

static void Log(string message) => Console.WriteLine(message);
```

We've set up three methods that all throw exceptions: a plain old void method, an async void method, and an async Task method. Then we call them (one by one) in *five* different ways - some wrapped in `Task.Run`, others called directly. The 5-second delay at the end gives us time to see which ones crash our process versus just failing gracefully.

**Results**. Let's look at each case:
* `Task.Run(VoidFunc)` does **not crash** the process.
* `VoidFuncAsync()` **crashes** the process immediately.
* `Task.Run(VoidFuncAsync)` also **crashes** the process.
* `TaskFuncAsync()` does **not crash** the process.
* `Task.Run(TaskFuncAsync)` does **not crash** the process as well.

Let's examine each scenario in detail to understand the underlying behavior.

**Scenario #1**

When we call `Task.Run(VoidFunc)`, something interesting happens behind the scenes. Even though `VoidFunc` throws an exception, the process keeps running. This works because `Task.Run` captures any exception thrown inside `VoidFunc` and stores it within the `Task` itself. The exception doesn't escape to the caller because the caller is not awaiting or calling .Wait() on the `Task`. It is well documented [here](https://learn.microsoft.com/en-us/dotnet/standard/parallel-programming/exception-handling-task-parallel-library)

Interesting fact, when we start `VoidFunc` using `ThreadPool.QueueUserWorkItem`, the process will crash.

**Scenarios #2 & #3**

When we use an `async void` method, whether called directly or wrapped in `Task.Run`, the process crashes. This happens because the C# compiler generates the code for `async void` methods using [`AsyncVoidMethodBuilder`](https://github.com/dotnet/runtime/blob/main/src/libraries/System.Private.CoreLib/src/System/Runtime/CompilerServices/AsyncVoidMethodBuilder.cs). When an exception occurs, the generated code calls the `SetException` method from `AsyncVoidMethodBuilder`, which calls `Task.ThrowAsync`, which "immediately" makes this exception "unhandled".

**Scenarios #4 & #5**

When we use an `async Task` method, whether called directly or wrapped in `Task.Run`, our process survives exceptions. This happens because the C# compiler generates the code for `async Task` methods using [`AsyncTaskMethodBuilder`](https://github.com/dotnet/runtime/blob/main/src/libraries/System.Private.CoreLib/src/System/Runtime/CompilerServices/AsyncTaskMethodBuilder.cs) (the different to one above). When an exception occurs, the generated code again calls the `SetException` method from `AsyncTaskMethodBuilder`, but this time it calls `TrySetException` on the associated `Task`, marking it as "faulted" with containing the exception.

**async void**

The `async void` changes how exceptions are handled at the compiler level, making it particularly dangerous. When the C# compiler encounters an `async void` method, it generates different exception handling code compared to `async Task` methods. While `async Task` integrates cleanly with TPL's exception handling infrastructure, `async void` bypasses these safeguards, leading to unhandled exceptions that can crash your process. This is why the primary best practice for async programming in C# is clear: always use `async Task` for your asynchronous methods, reserving `async void` exclusively for event handlers where we have no choice due to delegate signature requirements.

**Compiler-generated code for the code above**

```csharp
// Decompiled with JetBrains decompiler

using System;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;

[CompilerGenerated]
internal class Program
{
  [AsyncStateMachine(typeof (Program.<<Main>$>d__0))]
  [DebuggerStepThrough]
  private static Task <Main>$(string[] args)
  {
    Program.<<Main>$>d__0 stateMachine = new Program.<<Main>$>d__0();
    stateMachine.<>t__builder = AsyncTaskMethodBuilder.Create();
    stateMachine.args = args;
    stateMachine.<>1__state = -1;
    stateMachine.<>t__builder.Start<Program.<<Main>$>d__0>(ref stateMachine);
    return stateMachine.<>t__builder.Task;
  }

  public Program()
  {
    base..ctor();
  }

  [DebuggerStepThrough]
  [SpecialName]
  private static void <Main>(string[] args)
  {
    Program.<Main>$(args).GetAwaiter().GetResult();
  }

  [CompilerGenerated]
  internal static void <<Main>$>g__VoidFunc|0_0()
  {
    Program.<<Main>$>g__Log|0_3("VoidFunc starting");
    throw new ApplicationException("VoidFunc");
  }

  [AsyncStateMachine(typeof (Program.<<<Main>$>g__VoidFuncAsync|0_1>d))]
  [DebuggerStepThrough]
  [CompilerGenerated]
  internal static void <<Main>$>g__VoidFuncAsync|0_1()
  {
    Program.<<<Main>$>g__VoidFuncAsync|0_1>d stateMachine = new Program.<<<Main>$>g__VoidFuncAsync|0_1>d();
    stateMachine.<>t__builder = AsyncVoidMethodBuilder.Create();
    stateMachine.<>1__state = -1;
    stateMachine.<>t__builder.Start<Program.<<<Main>$>g__VoidFuncAsync|0_1>d>(ref stateMachine);
  }

  [NullableContext(1)]
  [AsyncStateMachine(typeof (Program.<<<Main>$>g__TaskFuncAsync|0_2>d))]
  [DebuggerStepThrough]
  [CompilerGenerated]
  internal static Task <<Main>$>g__TaskFuncAsync|0_2()
  {
    Program.<<<Main>$>g__TaskFuncAsync|0_2>d stateMachine = new Program.<<<Main>$>g__TaskFuncAsync|0_2>d();
    stateMachine.<>t__builder = AsyncTaskMethodBuilder.Create();
    stateMachine.<>1__state = -1;
    stateMachine.<>t__builder.Start<Program.<<<Main>$>g__TaskFuncAsync|0_2>d>(ref stateMachine);
    return stateMachine.<>t__builder.Task;
  }

  [NullableContext(1)]
  [CompilerGenerated]
  internal static void <<Main>$>g__Log|0_3(string message)
  {
    Console.WriteLine(message);
  }

  [CompilerGenerated]
  private sealed class <<<Main>$>g__TaskFuncAsync|0_2>d : IAsyncStateMachine
  {
    public int <>1__state;
    public AsyncTaskMethodBuilder <>t__builder;
    private TaskAwaiter <>u__1;

    public <<<Main>$>g__TaskFuncAsync|0_2>d()
    {
      base..ctor();
    }

    void IAsyncStateMachine.MoveNext()
    {
      int num1 = this.<>1__state;
      try
      {
        TaskAwaiter awaiter;
        int num2;
        if (num1 != 0)
        {
          Program.<<Main>$>g__Log|0_3("TaskFuncAsync starting");
          awaiter = Task.Delay(500).GetAwaiter();
          if (!awaiter.IsCompleted)
          {
            this.<>1__state = num2 = 0;
            this.<>u__1 = awaiter;
            Program.<<<Main>$>g__TaskFuncAsync|0_2>d stateMachine = this;
            this.<>t__builder.AwaitUnsafeOnCompleted<TaskAwaiter, Program.<<<Main>$>g__TaskFuncAsync|0_2>d>(ref awaiter, ref stateMachine);
            return;
          }
        }
        else
        {
          awaiter = this.<>u__1;
          this.<>u__1 = new TaskAwaiter();
          this.<>1__state = num2 = -1;
        }
        awaiter.GetResult();
        Program.<<Main>$>g__Log|0_3("TaskFuncAsync wait finished");
        throw new ApplicationException("TaskFuncAsync");
      }
      catch (Exception ex)
      {
        this.<>1__state = -2;
        this.<>t__builder.SetException(ex);
      }
    }

    [DebuggerHidden]
    void IAsyncStateMachine.SetStateMachine([Nullable(1)] IAsyncStateMachine stateMachine)
    {
    }
  }

  [CompilerGenerated]
  private sealed class <<<Main>$>g__VoidFuncAsync|0_1>d : IAsyncStateMachine
  {
    public int <>1__state;
    public AsyncVoidMethodBuilder <>t__builder;
    private TaskAwaiter <>u__1;

    public <<<Main>$>g__VoidFuncAsync|0_1>d()
    {
      base..ctor();
    }

    void IAsyncStateMachine.MoveNext()
    {
      int num1 = this.<>1__state;
      try
      {
        TaskAwaiter awaiter;
        int num2;
        if (num1 != 0)
        {
          Program.<<Main>$>g__Log|0_3("VoidFuncAsync starting");
          awaiter = Task.Delay(500).GetAwaiter();
          if (!awaiter.IsCompleted)
          {
            this.<>1__state = num2 = 0;
            this.<>u__1 = awaiter;
            Program.<<<Main>$>g__VoidFuncAsync|0_1>d stateMachine = this;
            this.<>t__builder.AwaitUnsafeOnCompleted<TaskAwaiter, Program.<<<Main>$>g__VoidFuncAsync|0_1>d>(ref awaiter, ref stateMachine);
            return;
          }
        }
        else
        {
          awaiter = this.<>u__1;
          this.<>u__1 = new TaskAwaiter();
          this.<>1__state = num2 = -1;
        }
        awaiter.GetResult();
        Program.<<Main>$>g__Log|0_3("VoidFuncAsync wait finished");
        throw new ApplicationException("VoidFuncAsync");
      }
      catch (Exception ex)
      {
        this.<>1__state = -2;
        this.<>t__builder.SetException(ex);
      }
    }

    [DebuggerHidden]
    void IAsyncStateMachine.SetStateMachine([Nullable(1)] IAsyncStateMachine stateMachine)
    {
    }
  }

  [CompilerGenerated]
  private sealed class <<Main>$>d__0 : IAsyncStateMachine
  {
    public int <>1__state;
    public AsyncTaskMethodBuilder <>t__builder;
    public string[] args;
    private TaskAwaiter <>u__1;

    public <<Main>$>d__0()
    {
      base..ctor();
    }

    void IAsyncStateMachine.MoveNext()
    {
      int num1 = this.<>1__state;
      try
      {
        TaskAwaiter awaiter;
        int num2;
        if (num1 != 0)
        {
          Task.Run(Program.<>O.<0>__VoidFunc ?? (Program.<>O.<0>__VoidFunc = new Action((object) null, __methodptr(<<Main>$>g__VoidFunc|0_0))));
          Program.<<Main>$>g__VoidFuncAsync|0_1();
          Task.Run(Program.<>O.<1>__VoidFuncAsync ?? (Program.<>O.<1>__VoidFuncAsync = new Action((object) null, __methodptr(<<Main>$>g__VoidFuncAsync|0_1))));
          Program.<<Main>$>g__TaskFuncAsync|0_2();
          Task.Run(Program.<>O.<2>__TaskFuncAsync ?? (Program.<>O.<2>__TaskFuncAsync = new Func<Task>((object) null, __methodptr(<<Main>$>g__TaskFuncAsync|0_2))));
          awaiter = Task.Delay(5000).GetAwaiter();
          if (!awaiter.IsCompleted)
          {
            this.<>1__state = num2 = 0;
            this.<>u__1 = awaiter;
            Program.<<Main>$>d__0 stateMachine = this;
            this.<>t__builder.AwaitUnsafeOnCompleted<TaskAwaiter, Program.<<Main>$>d__0>(ref awaiter, ref stateMachine);
            return;
          }
        }
        else
        {
          awaiter = this.<>u__1;
          this.<>u__1 = new TaskAwaiter();
          this.<>1__state = num2 = -1;
        }
        awaiter.GetResult();
      }
      catch (Exception ex)
      {
        this.<>1__state = -2;
        this.<>t__builder.SetException(ex);
        return;
      }
      this.<>1__state = -2;
      this.<>t__builder.SetResult();
    }

    [DebuggerHidden]
    void IAsyncStateMachine.SetStateMachine([Nullable(1)] IAsyncStateMachine stateMachine)
    {
    }
  }

  [CompilerGenerated]
  private static class <>O
  {
    public static Action <0>__VoidFunc;
    public static Action <1>__VoidFuncAsync;
    [Nullable(new byte[] {0, 2})]
    public static Func<Task> <2>__TaskFuncAsync;
  }
}
```

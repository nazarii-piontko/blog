---
layout:    "single"
classes:   "wide"
title:     "Calling Async Rust from C#: Tokio, Callbacks, and Cancellation"
excerpt:   "Rust's Tokio and C#'s Task scheduler don't share a runtime. Bridging async Rust and C# across FFI takes a Tokio runtime owned by .NET, Tasks completed from native callbacks, and safe cancellation across the boundary. Built around DataFusionSharp's Apache DataFusion bindings."
tags:      "rust dotnet csharp ffi interop async tokio datafusionsharp"
date:      "2026-04-26"
header:
  teaser: /assets/posts/rust-csharp-async-interop/logo.png
toc: false
---

Rust↔C# interop is reasonably well-documented for the simple case: define `extern "C" fn add(a: i32, b: i32) -> i32`, P/Invoke it from C#, done. The async case is much less covered, and the few resources that exist tend to stop at "spawn a Tokio task and call back into C#" without spelling out the lifetime, GC, and cancellation details that make a production library actually work. That gap is what I want to fill here, because it's where I had to figure most of this out by trial and error.

What follows is a walk through one set of solutions: a Tokio runtime owned by the .NET process, an FFI callback bridge that completes a `Task` on the C# side, and a lock-free state machine that keeps cancellation safe across the boundary. The running example is [DataFusionSharp](https://github.com/nazarii-piontko/datafusion-sharp), a .NET binding for [Apache DataFusion](https://datafusion.apache.org/) — DataFusion is async to its core (every query, file scan, and object-store request returns a `Future`), and the binding's whole job is to expose that as idiomatic `Task<T>`-returning C# methods. Tokio sits on one end, the .NET task scheduler on the other, with no shared notion of "completion" between them.

## Async in Rust and C#

Both Rust and C# settled on the same fundamental design: `async` functions compile to state machines that drive an external object (`Future` in Rust, `Task` in C#). The state machine yields control whenever it would block, and resumes when an "awaitable" completes. The vocabulary differs but the mechanics are basically the same.

In Rust, `async fn foo()` is sugar that the compiler rewrites into a function returning `impl Future<Output = T>`. A `Future` is a trait with a single method: `poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<T>`. Polling either returns `Ready(value)` or `Pending`, and on `Pending` the future has registered a `Waker` somewhere so it can be polled again later. Crucially, *nothing polls a `Future` until you hand it to an executor*. The most popular executor is [Tokio](https://tokio.rs/), a multi-threaded scheduler that owns a thread pool, drives futures to completion, and provides timers and an I/O reactor.

In C#, `async Task<T>` is also sugar — the compiler rewrites the body into a state machine implementing `IAsyncStateMachine`, with `MoveNext()` standing in for Rust's `poll` (almost, C# is push-based while Rust is pull-based). The difference is that the state machine is wired up automatically: continuations land on the .NET thread pool by default, awaiters are part of the BCL, and there is no executor to choose. You just call an `async` method and `await` what it returns.

Both compilers are doing the similar transformation, but the resulting state machine has to be driven by something, and Rust and C# don't share an executor, a poll loop, or a notion of completion. A Rust `Future` can't be awaited from C# directly, and shipping Tokio's runtime into .NET as a managed scheduler is not on the table either. So something has to bridge the two sides.

## The Bridge: Callbacks at the FFI Boundary

The lowest common denominator both sides understand is a C-style callback. The pattern looks like this:

1. C# calls a native function and that function returns immediately.
2. Native code spawns a Tokio task that does the actual async work.
3. When the task finishes, it invokes a callback function pointer the C# side passed in.
4. The callback unblocks a `TaskCompletionSource` on the C# side, which completes the `Task` the original caller is awaiting.

The native function returns synchronously and immediately — it's just a "start this work" message. Everything else happens through the callback.

Here's the possible callback signature on the Rust side:

```rust
pub type Callback = unsafe extern "C" fn(
    result: *const std::ffi::c_void,
    error: *const ErrorInfoData,
    user_data: isize,
);
```

Three pieces:

- **`result`** — pointer to whatever the operation produced, or null on error.
- **`error`** — pointer to error info, or null on success.
- **`user_data`** — an opaque `isize` the caller passed in. Native code never looks at it, it's just round-tripped back to C#. This is how we identify *which* operation just completed, and the callback later turns it back into a managed object — the section on `GCHandle` below covers that part.

## Wire Format and Lifetimes

Two `#[repr(C)]` structs do all the heavy lifting for data crossing the boundary:

```rust
#[repr(C)]
pub struct BytesData {
    data: *const u8,
    len: u32,
}

#[repr(C)]
pub struct ErrorInfoData {
    pub code: ErrorCode,
    pub message: BytesData,
}
```

`#[repr(C)]` makes the layout byte-identical to C# structs declared with `[StructLayout(LayoutKind.Sequential)]`, which means they pass through P/Invoke with zero marshalling — the bytes on the stack on one side are the bytes on the stack on the other.

`BytesData` is a pointer-and-length pair. It carries arguments going *into* native code (Protobuf-encoded options, query parameters, raw bytes), and it carries bulk results coming *back* through the callback's `result` slot. `ErrorInfoData` packages a numeric error code with a message in the same shape; the callback's `error` slot is a pointer to one of these when an operation failed.

The general rule for FFI lifetimes here:

- **Inputs**: pinned on the C# side, consumed by Rust before the call returns or before the spawned task finishes. Either way, Rust never holds onto an input pointer past the immediate operation.
- **Outputs**: owned by Rust, exposed to C# only during the callback. C# copies what it needs (`Marshal.PtrToStructure` for whole structs, `Marshal.ReadIntPtr` for a single pointer, plain copy loops for `BytesData` payloads), then Rust frees the original as the callback returns.

This is similar to how borrow checking works in pure Rust — the pointer's "lifetime" is the duration of the call. The only twist is that the borrow checker can't see across the FFI boundary, so the convention is enforced by hand on both sides.

## Owning Tokio from C#

DataFusionSharp creates and owns the Tokio runtime explicitly, so the C# side has full control over its lifetime.

```rust
pub type RuntimeHandle = Arc<tokio::runtime::Runtime>;

#[unsafe(no_mangle)]
pub unsafe extern "C" fn datafusion_runtime_new(
    runtime_ptr: *mut *mut RuntimeHandle,
) -> ErrorCode {
    let mut builder = tokio::runtime::Builder::new_multi_thread();

    builder.enable_all();

    match builder.build() {
        Ok(runtime) => {
            let runtime_handle: RuntimeHandle = Arc::new(runtime);
            unsafe { *runtime_ptr = Box::into_raw(Box::new(runtime_handle)); }
            ErrorCode::Ok
        }
        Err(_) => ErrorCode::RuntimeInitializationFailed,
    }
}
```

A few things worth pointing out:

- The runtime is wrapped in `Arc`, then boxed and returned as a raw pointer. The `Arc` lets multiple objects hold their own reference without complex lifetime management. The raw pointer is what crosses the FFI boundary.
- `new_multi_thread().enable_all()` gives us a real, multi-threaded Tokio with timers, I/O, and the works. `enable_all()` is a single call that turns on every optional Tokio feature: the timer wheel, the I/O reactor for sockets and files, and the signal handlers. Without it, `tokio::time::sleep` would panic at runtime.

On the C# side, we wrap the raw pointer in a `SafeHandle` so it gets cleaned up even if the C# code forgets to dispose explicitly. `SafeHandle` makes the handle GC-aware. It also guarantees that the handle is not freed while another thread is in the middle of a P/Invoke that uses it — the runtime ref-counts active calls and only allows `ReleaseHandle` once the count drops to zero. That eliminates a whole category of use-after-free bugs at the FFI boundary, with no extra code on our part.

## The Smallest Async Operation: Ping

Before tackling SQL, file I/O, and cancellation, here is the simplest possible async FFI call: a `ping` that sleeps for a specified number of milliseconds and then signals completion. It exercises every piece of the Rust-side machinery — runtime, spawn, select, callback. The next section covers the matching C# half.

Rust side:

```rust
#[unsafe(no_mangle)]
pub unsafe extern "C" fn datafusion_ping(
    runtime_ptr: *mut RuntimeHandle,
    timeout_millis: u64,
    callback: Callback,
    user_data: isize,
    cancellation_token_out_ptr: *mut *mut CancellationToken,
) -> ErrorCode {
    let runtime = ffi_ref!(runtime_ptr);

    let cancellation_token = CancellationToken::new();
    crate::cancellation::into_raw_ptr(&cancellation_token, cancellation_token_out_ptr);

    runtime.spawn(async move {
        let result = tokio::select! {
            () = tokio::time::sleep(Duration::from_millis(timeout_millis)) => Ok(()),
            () = cancellation_token.cancelled() => Err(crate::cancellation::error()),
        };

        crate::invoke_callback(result, callback, user_data);
    });

    ErrorCode::Ok
}
```

Four things happen here:

1. A Tokio `CancellationToken` is created and a pointer to it is written back through the out parameter (more on this in the cancellation section).
2. `runtime.spawn(async move { ... })` schedules the actual work on the Tokio thread pool. `spawn` returns immediately; the closure runs on a worker thread.
3. Inside the spawned task, `tokio::select!` races two futures: the sleep and the cancellation signal. Whichever finishes first wins; the other is dropped. Dropping a future is how Rust says "stop polling it" — `tokio::time::sleep` cleans up its timer entry as it's dropped, so the abandoned branch costs nothing.
4. When done, the C-style callback fires with either the result or an error, passing back the same `user_data` we received.

The `extern "C"` function itself returns `ErrorCode::Ok` *synchronously*. From C#'s perspective, it just got a "scheduled" acknowledgment — the result will arrive later via the callback.

## The C# Side: From Callback to Task

The C# side is more involved. Callers expect a `Task` they can `await`, not a callback, so bridging the two takes three pieces.

### 1. A TaskCompletionSource

[`TaskCompletionSource`](https://learn.microsoft.com/en-us/dotnet/api/system.threading.tasks.taskcompletionsource) gives us a `Task` whose completion we control imperatively. We hand the `Task` to the caller, then later call `TrySetResult`, `TrySetException`, or `TrySetCanceled` from inside the callback.

The cross-cutting plumbing — the `GCHandle` that pins the operation across the FFI call, the `CancellationTokenRegistration`, and the three-state pointer slot for the native cancellation handle — lives on an abstract base class that the typed leaf types inherit from:

```csharp
internal abstract class AsyncOperation
{
    private readonly CancellationToken _cancellationToken;
    private CancellationTokenRegistration _cancellationRegistration;
    private GCHandle _handle;
    private IntPtr _cancellationTokenHandle;

    protected AsyncOperation(CancellationToken cancellationToken)
    {
        _cancellationToken = cancellationToken;
    }

    internal IntPtr GetHandle() { /* lazy GCHandle.Alloc, returns a stable IntPtr */ }
    internal void EnsureNativeCall(...) { /* validates result, stores the native cancel pointer,
                                              registers OnCancelled, throws if the call failed */ }
    protected void Cleanup()       { /* free GCHandle, destroy native token, unregister */ }
}
```

Two leaf types specialise it: `AsyncVoidOperation` for fire-and-forget completion, and `AsyncOperation<TResult>` for callbacks that yield a typed value. Each adds a `TaskCompletionSource` of the matching shape and a `Complete(...)` method that translates the callback's result or exception into the right `TrySet*` call:

```csharp
internal sealed class AsyncVoidOperation : AsyncOperation
{
    private readonly TaskCompletionSource _taskCompletionSource =
        new(TaskCreationOptions.RunContinuationsAsynchronously);

    internal Task Task => _taskCompletionSource.Task;

    internal void Complete(Exception? exception = null)
    {
        Cleanup();

        switch (exception)
        {
            case null:
                _taskCompletionSource.TrySetResult();
                break;
            case DataFusionException { ErrorCode: DataFusionErrorCode.Canceled }:
                _taskCompletionSource.TrySetCanceled();
                break;
            default:
                _taskCompletionSource.TrySetException(exception);
                break;
        }
    }
}
```

`TaskCreationOptions.RunContinuationsAsynchronously` matters here. Without it, calling `TrySetResult` synchronously dispatches the awaiter's continuation on whatever thread invoked the callback — which is a Tokio worker thread. Continuations belong on the .NET thread pool, not on Tokio's; running them inline can starve Tokio workers and even deadlock if the continuation does any blocking I/O of its own. With the flag set, the runtime queues the continuation through `ThreadPool.UnsafeQueueUserWorkItem`, the Tokio worker returns to its scheduler immediately, and the C# code wakes up on a managed thread. Both sides go back to running their own jobs.

### 2. A GCHandle as user_data

How does the native callback know *which* `AsyncVoidOperation` to complete? Answer is `user_data: isize` slot. It's perfect for an opaque managed-object identifier — and `GCHandle` is exactly that.

```csharp
internal IntPtr GetHandle()
{
    if (!_handle.IsAllocated)
        _handle = GCHandle.Alloc(this, GCHandleType.Normal);

    return GCHandle.ToIntPtr(_handle);
}
```

`GCHandle.Alloc` does two things: it keeps the C# object alive even when nothing managed references it, and it gives us a stable `IntPtr` we can hand to native code. When the callback fires, it passes that `IntPtr` back, we call `GCHandle.FromIntPtr` to recover the original object, and free the handle.

This is the standard way to round-trip a managed object identity through unmanaged code. Without it, the GC could collect the `AsyncVoidOperation` between the call and the callback, leaving the callback with nothing valid to complete. `GCHandleType.Normal` keeps the object alive but does not pin its memory — there's no need to, because we never read its bytes from native code, only its identity.

### 3. An UnmanagedCallersOnly Callback

The actual callback function needs to be a plain function pointer with the C calling convention.

```csharp
[UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
internal static void CallbackForVoid(IntPtr _, IntPtr error, IntPtr handle)
{
    var ex = error != IntPtr.Zero
        ? ErrorInfoData.FromIntPtr(error).ToException()
        : null;
    var op = AsyncVoidOperation.FromHandle(handle);
    op?.Complete(ex);
}
```

[`[UnmanagedCallersOnly]`](https://learn.microsoft.com/en-us/dotnet/api/system.runtime.interopservices.unmanagedcallersonlyattribute) tells the runtime: this method must be callable directly as a C function pointer. The compiler verifies that all parameter types are blittable and that the body doesn't take a managed reference to itself. The result is a function pointer you can hand to native code with no marshalling overhead.

`FromHandle` does the inverse of `GetHandle`: it converts the `IntPtr` back to the managed object.

### Putting It Together

With those three pieces, the entire managed `PingAsync` looks like this:

```csharp
internal Task PingAsync(TimeSpan timeout, CancellationToken cancellationToken = default)
{
    unsafe
    {
        var op = new AsyncVoidOperation(cancellationToken);
        var result = NativeMethods.Ping(
            _handle,
            (ulong) timeout.TotalMilliseconds,
            &GenericCallbacks.CallbackForVoid,
            op.GetHandle(),
            out var cancellationTokenHandle);
        op.EnsureNativeCall(result, cancellationTokenHandle, "Failed to start ping.");

        return op.Task;
    }
}
```

The `&GenericCallbacks.CallbackForVoid` syntax produces a real function pointer (this is C# 9's function-pointer feature, which works with `[UnmanagedCallersOnly]` methods). We pass the `GCHandle` as `user_data`, and we get back a `Task` the caller can await.

`EnsureNativeCall` does the post-call bookkeeping that the snippet hides: it stores the cancellation-token pointer the native side returned, registers a callback on the user's token (`_cancellationToken.Register(OnCancelled)`) so user-side cancellation flows back into Rust, and throws if the native call returned an error code instead of `Ok`. Why that bookkeeping is non-trivial becomes clear in the cancellation section below.

That's the complete request → spawn → callback → Task lifecycle. For an operation returning a value, only one piece changes: a typed `AsyncOperation<TResult>` wraps a `TaskCompletionSource<TResult>`, and the matching callback parses the `result` pointer into a `TResult` before completing.

## Returning a Typed Result: SQL

Once the void case is in place, returning a typed result is mostly mechanical. Here's what `SqlAsync` looks like — a query that produces a `DataFrame`:

```csharp
public async Task<DataFrame> SqlAsync(string sql, CancellationToken cancellationToken = default)
{
    Task<DataFrameSafeHandle> sqlTask;

    unsafe
    {
        var op = new AsyncOperation<DataFrameSafeHandle>(cancellationToken);
        var result = NativeMethods.ContextSql(
            _handle,
            sql,
            BytesData.Empty,
            &CallbackForSqlAsync,
            op.GetHandle(),
            out var cancellationTokenHandle);
        op.EnsureNativeCall(result, cancellationTokenHandle, "Failed to start executing SQL query.");
        sqlTask = op.Task;
    }

    var dataFrameSafeHandle = await sqlTask.ConfigureAwait(false);
    return new DataFrame(this, dataFrameSafeHandle);
}

[UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
private static void CallbackForSqlAsync(IntPtr result, IntPtr error, IntPtr handle)
{
    var op = AsyncOperation<DataFrameSafeHandle>.FromHandle(handle);

    if (error != IntPtr.Zero)
    {
        op?.Complete(ErrorInfoData.FromIntPtr(error).ToException());
        return;
    }

    var dataFrameHandle = Marshal.ReadIntPtr(result);
    var safe = new DataFrameSafeHandle(dataFrameHandle);

    if (op is null)
        safe.Dispose(); // Nobody's waiting — free the native handle ourselves.
    else
        op.Complete(safe);
}
```

The Rust side pushes a `*mut DataFrameWrapper` through `result`. On the C# side we read the pointer with `Marshal.ReadIntPtr`, wrap it in a `DataFrameSafeHandle`, and complete the operation.

The pattern of "callback receives a raw pointer to a result struct, C# wraps it" generalizes to anything: bytes, integers, strings, even FFI Apache Arrow schemas. Each result type gets its own callback function but they all share the same shape.

## Cancellation

Now the reverse direction: a C# caller wants to cancel an in-flight operation by triggering its .NET `CancellationToken`. The cancellation needs to flow back through the FFI boundary into the running Tokio task.

(A naming note before going further: both Rust and .NET happen to call this primitive `CancellationToken`. To keep them straight, I'll prefix every mention as either *Tokio* or *.NET* below.)

Tokio already has the right primitive in [`tokio_util::sync::CancellationToken`](https://docs.rs/tokio-util/latest/tokio_util/sync/struct.CancellationToken.html) — a token whose `cancelled()` future resolves when `cancel()` is called from anywhere. Plug that into `tokio::select!` (you saw it in the ping function above), and you have an async operation that races real work against an external cancel signal.

The piece that's missing is letting C# call `cancel()` on that Tokio token. So we expose two more FFI functions:

```rust
#[unsafe(no_mangle)]
pub unsafe extern "C" fn datafusion_cancellation_token_cancel(
    token_ptr: *mut CancellationToken,
) -> ErrorCode {
    if token_ptr.is_null() { return ErrorCode::InvalidArgument; }
    let token = unsafe { Box::from_raw(token_ptr) };
    token.cancel();
    ErrorCode::Ok
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn datafusion_cancellation_token_destroy(
    token_ptr: *mut CancellationToken,
) -> ErrorCode {
    if token_ptr.is_null() { return ErrorCode::InvalidArgument; }
    unsafe { drop(Box::from_raw(token_ptr)) };
    ErrorCode::Ok
}
```

When a Rust async function starts, it creates a Tokio `CancellationToken`, clones it (cloning a Tokio token shares the same internal cancellation state — it doesn't make a separate token), and writes a raw pointer to the clone back through the out parameter. The C# side stores that pointer. If the user's .NET `CancellationToken` fires, C# P/Invokes `datafusion_cancellation_token_cancel`, which cancels the Tokio token, which makes `cancellation_token.cancelled()` resolve in `tokio::select!`, which preempts the real future.

If the operation completes normally, C# P/Invokes `datafusion_cancellation_token_destroy` instead, freeing the Tokio token without firing it.

The C# wiring looks straightforward: register a callback on the user's .NET token that triggers the native cancel function.

```csharp
_cancellationRegistration = _cancellationToken.Register(OnCancelled);

private void OnCancelled() => Cancel();
```

Except it isn't, because there's a race, and I had to redo this twice before it stopped flaking in tests.

### The Race

Step by step, the ping flow goes:

1. C# calls `Ping`, passing a callback and a slot for the cancellation-token pointer.
2. Native code creates the cancellation token, writes its pointer to the out parameter, **and spawns the Tokio task**.
3. The native function returns to C#.
4. C# wires up `cancellationToken.Register(OnCancelled)` so cancellation will trigger the native `Cancel`.

The problem: between step 2 and step 4, the Tokio task can start, complete, and fire the callback. If that happens, the callback completes the `Task` — but the C# side hasn't yet decided what to do with the cancellation-token pointer. Worse, if the user cancels right after step 4 wires up cancellation, C# might call `Cancel` on a token that's already been freed by the completion path.

With a `ping(0)` call, the spawned future completes essentially synchronously on a Tokio worker, so this race fires in practice. By the time the calling thread gets back to step 4, the callback has already run, the GC handle has been freed, and the cancellation token would be gone if we destroyed it eagerly.

The simplest fix is to take a lock. But this is a hot path; we don't want a mutex on every async call.

### The Three-State Pointer

Instead, the C# `AsyncOperation` treats the native cancellation-token pointer as a tiny lock-free state machine with three states:

- `IntPtr.Zero` — no native token registered yet (initial state).
- A real pointer — token is alive, cancellation can fire.
- `IntPtr(-1)` — operation has finished (completed, errored, or cancelled), token has been or will be destroyed.

The transitions are atomic, using `Interlocked.CompareExchange` and `Interlocked.Exchange`:

```csharp
private bool TryInitializeCancellationTokenHandle(IntPtr handle)
{
    var prev = Interlocked.CompareExchange(
        ref _cancellationTokenHandle,
        handle,
        EmptyCancellationTokenHandle);
    return prev == EmptyCancellationTokenHandle;
}

private IntPtr TakeCancellationTokenHandle()
{
    return Interlocked.Exchange(
        ref _cancellationTokenHandle,
        FinishedCancellationTokenHandle);
}
```

`TryInitialize` runs in `EnsureNativeCall` on the calling thread. `Take` runs in two places: the cleanup path inside `Complete` (callback thread), and the cancellation path inside `Cancel` (whichever thread fires the user's `CancellationToken`).

Now the race is well-defined. Two scenarios cover what can happen:

- **C# wins** (the spawned task hasn't completed yet): `TryInitialize` succeeds (CAS from `Zero` → real handle), and the cancellation registration is wired. Whichever path fires next — completion or cancellation — calls `Take` to read the live pointer, transitions to `Finished`, and acts on it.
- **Tokio task wins** (it completes immediately, runs the callback, which transitions the slot to `Finished` via cleanup): `TryInitialize` sees `Finished`, the CAS fails, and C# destroys the token it had been about to register. Cleanup is a no-op.

In both scenarios, cancellation and completion can never both `Take` the same live pointer, because `Exchange` is atomic — exactly one of them sees the real handle; the other sees `Finished` and walks away.

The takeaway I'd hold onto from this: whenever an FFI handle has both a completion path and a from-the-outside path that can fire at the same time, two states aren't enough. A third state — "done, hands off" — and an atomic CAS into the pointer slot itself is usually cheaper than reaching for a mutex.

## Production Notes

A few practical things worth mentioning:

- **`[LibraryImport]` over `[DllImport]`**. The `[LibraryImport]` source generator produces marshalling code at compile time, which makes the bindings AOT-compatible.
- **`[SuppressGCTransition]`** on cheap, non-blocking native functions like `CancellationTokenCancel`. Skipping the GC transition shaves a few hundred nanoseconds per call. The trade-off is that the call must not block, allocate, or take any time at all in native code, because the GC is effectively paused for its duration. Cancellation is a simple atomic store on Tokio's side, so it qualifies.

## Wrapping Up

The pattern in five points:

- One Tokio runtime, owned by C# for its full lifetime, holding a raw pointer wrapped in a `SafeHandle`.
- Every async FFI call accepts a `(callback, user_data, cancellation_token_out)` triple and returns immediately. Real work runs on the Tokio pool.
- The managed side keeps its operation object alive across the call via `GCHandle`, completes a `TaskCompletionSource` from a static `[UnmanagedCallersOnly]` callback, and frees the handle on the way out.
- Cancellation flows the other way through a Tokio `CancellationToken` whose pointer is round-tripped through a three-state lock-free machine on the C# side, robust against the obvious "callback fires before C# wires cancellation" race.
- Inputs and outputs cross the FFI boundary as `#[repr(C)]` structs of pointers and lengths, with strict ownership rules: inputs are pinned by C#, outputs are owned by Rust and live only for the duration of the callback.

The code lives at [github.com/nazarii-piontko/datafusion-sharp](https://github.com/nazarii-piontko/datafusion-sharp) — the runtime and cancellation pieces are in `native/src/runtime.rs`, `native/src/cancellation.rs`, and `src/DataFusionSharp/Interop/AsyncOperations.cs` if you want to see all the production warts (memory-test instrumentation, finalizers, edge cases) that I trimmed for this post.

That's a lot of plumbing for what looks like a simple `await`. The payoff is that once it's set up, the C# side is just `await context.SqlAsync(...)` and the Tokio executor is doing real multi-core async work underneath. If you're binding any other Tokio-based Rust library to .NET, you'll probably end up with a fairly close variant of this same wiring — the specifics change but the shape is the same.

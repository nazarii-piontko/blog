---
layout: single
classes: wide
title: "C++ SIMD Auto-Vectorization: Why Array Access Patterns Matter"
excerpt: "A practical exploration of how restructuring array accesses in C++ can help compilers generate vectorized code that's 2x faster, with detailed assembly analysis of bitpacking implementations."
tags: "optimizations c++ asm simd sse"
date: "2026-01-24"
toc: false
header:
 teaser: /assets/posts/simd-auto-vectorization/logo.png
---

Recently I've been working on bitpacking code, and I discovered something interesting: seemingly minor changes in how we access arrays can lead to dramatic performance improvements, all thanks to the compiler's ability to auto-vectorize our code using [SIMD](https://en.wikipedia.org/wiki/Single_instruction,_multiple_data) instructions. Let me show you what I mean.

For simplification, let's assume we need to pack 1024 64-bit unsigned integer values using 8 bits each in C++. Bitpacking is a common operation in compression algorithms and data serialization, where we want to squeeze multiple small values into a single machine word to save space.

## The Naive Approach

What most of us would write first is a straightforward nested loop that processes values one at a time, something like this (simplified, no error checking, no bounds checking):

```cpp
constexpr size_t ARRAY_SIZE = 1024; // Total number of input values

void bitpack_naive(const uint64_t* __restrict input, uint64_t* __restrict output) {
    for (size_t i = 0, j = 0; i < ARRAY_SIZE; ) {
        uint64_t acc = 0;

        for (size_t k = 0, shift = 0; k < 8; ++k, ++i, shift += 8)
            acc |= (input[i] & 0xFF) << shift;

        output[j++] = acc;
    }
}
```

This code reads 8 consecutive input values, masks each to 8 bits, shifts them into appropriate position in accumulator, and combines them into a single 64-bit output word using bitwise OR. It's simple, clean, readable, and... surprisingly effective when compiled with `-O3` (`-O3` option enables aggressive optimizations, additionally `-msse4` for SSE or `-mavx2` for AVX2 can be used to enable specific SIMD instruction sets).

Note: [SSE](https://en.wikipedia.org/wiki/Streaming_SIMD_Extensions) (Streaming SIMD Extensions) allows to process multiple data points in parallel using 128-bit registers. It uses `xmm` CPU registers and instructions like `pand`, `psllq`, or `por` to manipulate data in parallel. Another common SIMD instruction set is [AVX](https://en.wikipedia.org/wiki/Advanced_Vector_Extensions), which uses 256-bit `ymm` CPU registers.

Looking at the generated assembly, we can see the compiler ([`clang-21`](https://clang.llvm.org/) in my case) has done something remarkable. Instead of the simple scalar operations we wrote, it's generated SIMD code using SSE instructions. Here's a snippet of the generated assembly:

```nasm
; Load pre-computed mask constants into XMM registers
movdqa  .LCPI7_0(%rip), %xmm0       ; xmm0 = mask for bytes 0 and 8 [255,0,0,0,0,0,0,0,255,0,0,0,0,0,0,0]
movdqa  .LCPI7_1(%rip), %xmm1       ; xmm1 = mask for bytes 1 and 9 [0,255,0,0,0,0,0,0,0,255,0,0,0,0,0,0]
; ... (additional masks loaded for other byte positions)

.LBB7_1:                            ; Main loop starts here
  ; Load two 64-bit values from different locations into XMM registers
  movq       64(%rdi,%rax,8), %xmm7 ; Load value at input index 8 (64-bit data at address 64 + base, 64 = skip 8 values * 8 bytes each, base = %rdi + %rax*8) into xmm7 - second value
  movq       (%rdi,%rax,8), %xmm8   ; Load value at input index 0 (64-bit data at address 0 + base, base = %rdi + %rax*8) into xmm8 - first value
  punpcklqdq %xmm7, %xmm8           ; Combine the two values into a single 128-bit register xmm8
  pand       %xmm0, %xmm8           ; Apply mask to extract only the bytes we want, bitwise AND, result in xmm8

  ; Repeat for next pair of values
  movq       72(%rdi,%rax,8), %xmm7 ; Load value at input index 9 (64-bit data at address 72 + base, 72 = skip 9 values * 8 bytes each, base = %rdi + %rax*8) into xmm7
  movq       8(%rdi,%rax,8), %xmm9  ; Load value at input index 1 (64-bit data at address 8 + base, 8 = skip 1 value * 8 byte, base = %rdi + %rax*8) into xmm9
  punpcklqdq %xmm7, %xmm9           ; Combine the two values into a single 128-bit register xmm9
  psllq      $8, %xmm9              ; Shift left by 8 bits to position the byte correctly, result in xmm9
  pand       %xmm1, %xmm9           ; Apply mask to extract only the bytes we want, bitwise AND, result in xmm9

  por        %xmm8, %xmm9           ; Combine with previous result using bitwise OR, result in xmm9

  ; ... (similar operations for remaining bytes)

  movdqu     %xmm8, (%rsi,%rax)     ; Store the final packed result into output array

  ; Loop counter increment and check
  addq       $16, %rax              ; Move base forward by 16
  cmpq       $1024, %rax            ; Compare base with 1024
  jne        .LBB7_1                ; Jump back if not done
```

Note: The exact instruction mix, register allocation, and masks will vary by compiler version, target CPU, and flags. The snippets are representative of the optimization strategy rather than a byte-for-byte listing.

The compiler has done two clever optimizations here:

1. **Loop unrolling**. The compiler unrolls the outer loop by a factor of 2, processing two output words per iteration (one from input indices 0-7, another from 8-15). The next iteration processes input indices 16-23 and 24-31, and so on. The inner loop is effectively eliminated through vectorization. This reduces loop overhead and increases instruction-level parallelism.

2. **Auto-vectorization**. It's using SIMD SSE instructions to process multiple values in parallel. The [`punpcklqdq`](https://www.felixcloutier.com/x86/punpcklbw:punpcklwd:punpckldq:punpcklqdq) instruction interleaves data, [`psllq`](https://www.felixcloutier.com/x86/psllw:pslld:psllq) performs parallel shifts, [`pand`](https://www.felixcloutier.com/x86/pand) performs bitwise AND with mask, and [`por`](https://www.felixcloutier.com/x86/por) combines results.

The compiler is working hard to vectorize a pattern that wasn't originally written with SIMD in mind. While the memory accesses are actually sequential (reading consecutive elements 0, 1, 2, 3...), the compiler must use intricate shuffle operations (`punpcklqdq`) to reorganize this data into SIMD-friendly positions, which adds overhead.

## The Vectorization-Friendly Approach

Now, let's restructure the code slightly. Instead of reading consecutive elements and packing them together, we'll change the access pattern together with manual loop unrolling:

```cpp
void bitpack_vectorized(const uint64_t* __restrict input, uint64_t* __restrict output) {
    for (int i = 0; i < 128; ++i) {
        uint64_t acc = input[i] & 0xFF;
        acc |= (input[i + 128] & 0xFF) << 8;
        acc |= (input[i + 256] & 0xFF) << 16;
        acc |= (input[i + 384] & 0xFF) << 24;
        acc |= (input[i + 512] & 0xFF) << 32;
        acc |= (input[i + 640] & 0xFF) << 40;
        acc |= (input[i + 768] & 0xFF) << 48;
        acc |= (input[i + 896] & 0xFF) << 56;
        output[i] = acc;
    }
}
```

So what's changed? Instead of reading 8 consecutive input values, we're now reading values that are 128 elements apart: `i`, `i + 128`, `i + 256`, and so on.

Why this particular pattern? We're processing 1024 values, packing 8 bits from each value. This means we'll produce 128 output values (1024 / 8 = 128). Each iteration handles one output value by reading from 8 locations spaced 128 elements apart. This stride length (128) isn't arbitrary - it's the number of output values we're producing, which ensures each iteration processes one value from each "slice" of the input array.

The generated assembly for this version looks like this:

```nasm
; Same mask setup as before
movdqa  .LCPI8_0(%rip), %xmm0      ; Load masks into XMM registers
; ... (other masks)

.LBB8_1:                           ; Main loop
  ; Load 16 bytes (2 uint64_t values) with simple, contiguous access
  movdqu  (%rdi,%rax,8), %xmm7     ; Load 2 contiguous values from indices 0 and 1 (data address 0 + base, base = %rdi + %rax*8) into xmm7
  pand    %xmm0, %xmm7             ; Apply mask to extract relevant bytes, result in xmm7

  ; Load from next stride - still contiguous relative to loop counter
  movdqu  1024(%rdi,%rax,8), %xmm8 ; Load 2 contiguous values from indices 128 and 129 (1024 + base, 1024 = 128 values * 8 bytes each, base = %rdi + %rax*8) into xmm8
  psllq   $8, %xmm8                ; Shift left by 8 bits to position byte correctly, result in xmm8
  pand    %xmm1, %xmm8             ; Apply mask to extract relevant bytes, result in xmm8

  por     %xmm7, %xmm8             ; Combine with previous, result in xmm8

  ; ... (similar operations for remaining bytes)

  movdqu  %xmm8, (%rsi,%rax,8)     ; Store packed result into output

  ; Loop counter increment and check
  addq    $2, %rax                 ; Increment index by 2
  cmpq    $128, %rax               ; Compare index with 128
  jne     .LBB8_1                  ; Jump back if not done
```

## Why Is This Faster?

To visualize the difference:

* Naive approach - reads consecutive elements, requires shuffling:
  ```
  Iteration i=0,1: read [0,8] [1,9] [2,10]... [7,15] → shuffle → pack → → output[0,1]
  Iteration i=2,3: read [16,24] [17,25] [18,26]... [23,31] → shuffle → pack → → output[2,3]
  ...
  Iteration i=126,127: read [1008,1016] [1009,1017]... [1015,1023] → shuffle → pack → → output[126,127]
  ```
  Problem: To vectorize, must load `[0]` and `[8]` together, `[1]` and `[9]` together, etc. Requires `punpcklqdq` to interleave non-adjacent values.

* Vectorized approach - reads strided elements, naturally aligned. Input conceptually divided into 8 slices of 128 elements:
  ```
  Iteration i=0,1: read [0,1] [128,129] [256,257]... [896,897] → pack → → output[0,1]
  Iteration i=2,3: read [2,3] [130,131] [258,259]... [898,899] → pack → → output[2,3]
  ...
  Iteration i=126,127: read [126,127] [254,255]... [1022,1023] → pack → → output[126,127]
  ```
  Advantage: Loading `[0,1]` or `[128,129]` is a single [`movdqu`](https://www.felixcloutier.com/x86/movdqu:vmovdqu8:vmovdqu16:vmovdqu32:vmovdqu64) instruction. Values naturally align to SIMD lanes - no shuffling needed.

The key differences from the naive version:

1. **Simpler memory access pattern**. While the accesses are strided rather than sequential, they map naturally to SIMD lanes without requiring shuffle operations. Instead of the complex `punpcklqdq` instructions, we now have straightforward `movdqu` (move unaligned double quadword) loads from predictable offsets: base, base+1024, base+2048, etc.

2. **No data reorganization needed**. The naive version had to use `punpcklqdq` to interleave data from different memory locations. The vectorized version eliminates this entirely - the data is already in the right layout for SIMD processing.

3. **Better instruction-level parallelism**. The simpler instruction sequence allows the CPU's out-of-order execution to work more effectively. There are fewer dependencies between operations.

4. **Cache-friendly for this workload**. While strided access can sometimes have worse cache behavior than sequential access, our working set (1024 × 8 = 8KB) fits comfortably in L1 cache, so the strided pattern doesn't introduce cache penalties. For much larger datasets, this trade-off would need careful consideration.

The benchmark results speak for themselves: **the vectorized version is approximately 2x faster than the naive implementation**.

Benchmark Results produced with [`nanobench`](https://github.com/martinus/nanobench) on `Debian GNU/Linux 12 bookworm (x86-64)` with `Intel© Core™ i7-10510U CPU @ 1.80GHz × 4`:

```
| relative |  ns/op |         op/s | err% | total | benchmark
|---------:|-------:|-------------:|-----:|------:|:------------
|   100.0% | 499.44 | 2,002,232.02 | 0.0% |  0.12 | `naive`
|   212.9% | 234.64 | 4,261,819.64 | 0.2% |  0.06 | `vectorized`
```

This example demonstrates a counterintuitive principle in performance optimization: the way we access our data matters more than we might think. By restructuring array accesses to align with how SIMD instructions operate, we can help the compiler generate dramatically more efficient code - even when the change seems to make the algorithm "worse" from a traditional optimization perspective.

## Bonus: The Same Principle in C#

While we've been exploring C++ throughout this article, the principle of SIMD-friendly access patterns applies to other languages as well. C# provides explicit SIMD support through the [`System.Runtime.Intrinsics`](https://learn.microsoft.com/en-us/dotnet/api/system.runtime.intrinsics) namespace, allowing to write vectorized code directly.

Unlike C++, where the compiler often auto-vectorizes loops, C# typically requires to write explicit SIMD code using intrinsics. However, the core insight remains the same: the strided access pattern we discovered translates directly to better SIMD performance in C# as well.

Here's how both approaches look in C#:

```csharp
public static class BitPacker
{
    public const int ArraySize = 1024;
    
    public static void PackNaive(ReadOnlySpan<ulong> input, Span<ulong> output)
    {
        for (int i = 0, j = 0; i < input.Length; )
        {
            ulong acc = 0;
            
            for (int k = 0, shift = 0; k < 8; ++k, ++i, shift += 8)
                acc |= (input[i] & 0xFF) << shift;
            
            output[j++] = acc;
        }
    }
    
    public static unsafe void PackSIMD(ReadOnlySpan<ulong> input, Span<ulong> output)
    {
        // We need unsafe code to work with pointers for intrinsics
        fixed (ulong* inputPtr = input) // Pin input span to get a pointer
        fixed (ulong* outputPtr = output) // Pin output span to get a pointer
        {
            // Pre-create mask vectors for each byte position
            var mask0 = Vector128.Create(0xFF, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0, 0, 0, 0, 0, 0, 0).AsUInt64();
            var mask1 = Vector128.Create(0, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0, 0, 0, 0, 0, 0).AsUInt64();
            var mask2 = Vector128.Create(0, 0, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0, 0, 0, 0, 0).AsUInt64();
            var mask3 = Vector128.Create(0, 0, 0, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0, 0, 0, 0).AsUInt64();
            var mask4 = Vector128.Create(0, 0, 0, 0, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0, 0, 0).AsUInt64();
            var mask5 = Vector128.Create(0, 0, 0, 0, 0, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0, 0).AsUInt64();
            var mask6 = Vector128.Create(0, 0, 0, 0, 0, 0, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0).AsUInt64();

            for (int i = 0; i < 128; i += 2)
            {
                Sse2.Or( // Combine two output values
                    Sse2.Or( // Combine first four loads
                        Sse2.Or( // Combine first four loads
                            Sse2.And(Sse2.LoadVector128(inputPtr + i), mask0), // First 128-bit load
                            Sse2.And(Sse2.ShiftLeftLogical(Sse2.LoadVector128(inputPtr + i + 128), 8), mask1)), // Second 128-bit load
                        Sse2.Or( // Combine third and fourth loads
                            Sse2.And(Sse2.ShiftLeftLogical(Sse2.LoadVector128(inputPtr + i + 256), 16), mask2), // Third 128-bit load
                            Sse2.And(Sse2.ShiftLeftLogical(Sse2.LoadVector128(inputPtr + i + 384), 24), mask3))), // Fourth 128-bit load
                    Sse2.Or( // Combine last four loads
                        Sse2.Or( // Combine fifth and sixth loads
                            Sse2.And(Sse2.ShiftLeftLogical(Sse2.LoadVector128(inputPtr + i + 512), 32), mask4), // Fifth 128-bit load
                            Sse2.And(Sse2.ShiftLeftLogical(Sse2.LoadVector128(inputPtr + i + 640), 40), mask5)), // Sixth 128-bit load
                        Sse2.Or( // Combine seventh and eighth loads
                            Sse2.And(Sse2.ShiftLeftLogical(Sse2.LoadVector128(inputPtr + i + 768), 48), mask6), // Seventh 128-bit load
                            Sse2.ShiftLeftLogical(Sse2.LoadVector128(inputPtr + i + 896), 56)))) // Eighth 128-bit load
                    .Store(outputPtr + i); // Store the packed result
            }
        }
    }
}
```

This is the straightforward translation of original assembly code - reading consecutive elements and packing them together.

The SIMD version follows the same pattern we discovered:

* We access the input array with strides of 128 elements
* Load pairs of values into `Vector128<ulong>` registers
* Apply shifts and masks using SSE2 intrinsics
* Combine the results with bitwise `OR` operations

The notable differences from C++ is explicit intrinsics. While the C++ compiler is able to auto-vectorize code, in C# we're directly calling methods like `Sse2.ShiftLeftLogical` and `Sse2.And`. This gives us fine-grained control but requires more verbose code. Of course, it is possible to be that explicit in C++ as well using intrinsics, but auto-vectorization is often more convenient, nevertheless understanding how to write SIMD-friendly code is crucial.

Benchmarking with [`BenchmarkDotNet`](https://benchmarkdotnet.org/) on `Debian GNU/Linux 12 bookworm (x86-64)` with `Intel© Core™ i7-10510U CPU @ 1.80GHz × 4`:

```
| Method | Mean       | Error   | StdDev  | Ratio |
|------- |-----------:|--------:|--------:|------:|
| Naive  | 1,358.0 ns | 3.00 ns | 2.50 ns |  1.00 |
| SIMD   |   311.5 ns | 3.47 ns | 3.07 ns |  0.23 |
```

SIMD implementation significantly (about 4.3x) outperforms the naive scalar approach, demonstrating that the principle of SIMD-friendly access patterns is language-agnostic.
The lesson carries across: whether you're writing C++, C#, or any other language with SIMD support, thinking about how your data access patterns align with SIMD operations is crucial for achieving optimal performance.

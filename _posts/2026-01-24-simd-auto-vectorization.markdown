---
layout: single
classes: wide
title: "C++ SIMD Auto-Vectorization: Why Array Access Patterns Matter"
excerpt: "A practical exploration of how restructuring array accesses in C++ can help compilers generate vectorized code that's 2x faster, with detailed assembly analysis of bitpacking implementations."
tags: "optimizations c++ simd sse"
date: "2026-01-24"
toc: false
header:
 teaser: /assets/posts/simd-auto-vectorization/logo.png
---

Recently I've been working on bitpacking code, and I discovered something interesting: seemingly minor changes in how we access arrays can lead to dramatic performance improvements, all thanks to the compiler's ability to auto-vectorize our code using SIMD instructions. Let me show you what I mean.

For simplification, let's assume we need to pack 1024 64-bit unsigned integer values using 8 bits each in C++. Bitpacking is a common operation in compression algorithms and data serialization, where we want to squeeze multiple small values into a single machine word to save space.

## The Naive Approach

What most of us would write first is a straightforward nested loop that processes values one at a time, something like this:

```cpp
constexpr size_t ARRAY_SIZE = 1024;

void bitpack_naive(const uint64_t* __restrict input, uint64_t* __restrict output) {
    for (size_t i = 0, j = 0; i < ARRAY_SIZE; ) {
        uint64_t acc = 0;

        for (size_t k = 0, shift = 0; k < 8; ++k, ++i, shift += 8)
            acc |= (input[i] & 0xFF) << shift;

        output[j++] = acc;
    }
}
```

This code reads 8 consecutive input values, masks each to 8 bits, shifts them into appropriate position in accumulator, and combines them into a single 64-bit output word using bitwise OR. It's simple, clean, readable, and... surprisingly effective when compiled with `-O3` (`-O3` option enables aggressive optimizations).

Looking at the generated assembly, we can see the compiler (`clang`) has done something remarkable. Instead of the simple scalar operations we wrote, it's generated SIMD code using SSE instructions. SSE (Streaming SIMD Extensions) allows to process multiple data points in parallel using 128-bit registers. It uses `xmm` CPU registers and instructions like `pand`, `psllq`, or `por` to manipulate data in parallel. Another common SIMD instruction set is AVX, which uses 256-bit `ymm` CPU registers. Here's a snippet of the generated assembly:

```asm
# Load pre-computed mask constants into XMM registers
movdqa  .LCPI7_0(%rip), %xmm0       # xmm0 = mask for bytes 0 and 8 [255,0,0,0,0,0,0,0,255,0,0,0,0,0,0,0]
movdqa  .LCPI7_1(%rip), %xmm1       # xmm1 = mask for bytes 1 and 9 [0,255,0,0,0,0,0,0,0,255,0,0,0,0,0,0]
# ... (additional masks loaded for other byte positions)

.LBB7_1:                            # Main loop starts here
  # Load two 64-bit values from different locations into XMM registers
  movq       64(%rdi,%rax,8), %xmm7 # Load value at index 8 (64 + base, 64 = 8 values * 8 bytes each, base = %rdi + %rax*8) into %xmm7 - second value
  movq       (%rdi,%rax,8), %xmm8   # Load value at index 0 (0 + base, base = %rdi + %rax*8) into %xmm8 - first value
  punpcklqdq %xmm7, %xmm8           # Combine the two values into a single 128-bit register %xmm8
  pand       %xmm0, %xmm8           # Apply mask to extract only the bytes we want, bitwise AND, result in %xmm8

  # Repeat for next pair of values
  movq       72(%rdi,%rax,8), %xmm7 # Load value at index 9 (72 + base, 72 = 9 values * 8 bytes each, base = %rdi + %rax*8) into %xmm7
  movq       8(%rdi,%rax,8), %xmm9  # Load value at index 1 (8 + base, 8 = 1 value * 8 byte, base = %rdi + %rax*8) into %xmm9
  punpcklqdq %xmm7, %xmm9           # Combine the two values into a single 128-bit register %xmm9
  psllq      $8, %xmm9              # Shift left by 8 bits to position the byte correctly, result in %xmm9
  pand       %xmm1, %xmm9           # Apply mask to extract only the bytes we want, bitwise AND, result in %xmm9

  por        %xmm8, %xmm9           # Combine with previous result using bitwise OR, result in %xmm9

  # ... (similar operations for remaining bytes)

  movdqu     %xmm8, (%rsi,%rax)     # Store the final packed result into output array

  # Loop counter increment and check
  addq       $16, %rax              # Move base forward by 16
  cmpq       $1024, %rax            # Compare base with 1024
  jne        .LBB7_1                # Jump back if not done
```

The compiler has done two clever optimizations here:

1. **Loop unrolling**. The compiler unrolls the outer loop by a factor of 2, processing two output words per iteration (one from input indices 0-7, another from 8-15). The next iteration processes input indices 16-23 and 24-31, and so on. The inner loop is effectively eliminated through vectorization. This reduces loop overhead and increases instruction-level parallelism.

2. **Auto-vectorization**. It's using SIMD SSE instructions to process multiple values in parallel. The `punpcklqdq` instruction interleaves data, `psllq` performs parallel shifts, and `por` combines results.

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

```asm
# Same mask setup as before
movdqa  .LCPI8_0(%rip), %xmm0      # Load masks into XMM registers
# ... (other masks)

.LBB8_1:                           # Main loop
  # Load 16 bytes (2 uint64_t values) with simple, contiguous access
  movdqu  (%rdi,%rax,8), %xmm7     # Load 2 contiguous values from indices 0 and 1 (0 + base, base = %rdi + %rax*8) into %xmm7
  pand    %xmm0, %xmm7             # Apply mask to extract relevant bytes, result in %xmm7

  # Load from next stride - still contiguous relative to loop counter
  movdqu  1024(%rdi,%rax,8), %xmm8 # Load 2 contiguous values from indices 128 and 129 (1024 + base, 1024 = 128 values * 8 bytes each, base = %rdi + %rax*8) into %xmm8
  psllq   $8, %xmm8                # Shift left by 8 bits to position byte correctly, result in %xmm8
  pand    %xmm1, %xmm8             # Apply mask to extract relevant bytes, result in %xmm8

  por     %xmm7, %xmm8             # Combine with previous, result in %xmm8

  # ... (similar for other strides)

  movdqu  %xmm8, (%rsi,%rax,8)     # Store packed result into output

  # Loop counter increment and check
  addq    $2, %rax                 # Increment index by 2
  cmpq    $128, %rax               # Compare index with 128
  jne     .LBB8_1                  # Jump back if not done
```

## Why Is This Faster?

To visualize the difference:

* Naive approach - reads consecutive elements, requires shuffling:
  ```
  Iteration 1: [0][1][2][3][4][5][6][7] → shuffle & pack → output[0]
  Iteration 2: [8][9][10][11][12][13][14][15] → shuffle & pack → output[1]
  ```
  Problem: To vectorize, must load `[0]` and `[8]` together, `[1]` and `[9]` together, etc. Requires `punpcklqdq` to interleave non-adjacent values.

* Vectorized approach - reads strided elements, naturally aligned. Input conceptually divided into 8 slices of 128 elements:
  ```
  Slice 0: [0][1][2]...[127]
  Slice 1: [128][129][130]...[255]
  ...
  Slice 7: [896][897][898]...[1023]

  Iteration i=0,1: Read [0,1] [128,129] [256,257]... → pack → output[0,1]
  Iteration i=2,3: Read [2,3] [130,131] [258,259]... → pack → output[2,3]
  ```
  Advantage: Loading `[0,1]` or `[128,129]` is a single `movdqu` instruction. Values naturally align to SIMD lanes - no shuffling needed.

The key differences from the naive version:

1. **Simpler memory access pattern**. While the accesses are strided rather than sequential, they map naturally to SIMD lanes without requiring shuffle operations. Instead of the complex `punpcklqdq` instructions, we now have straightforward `movdqu` (move unaligned double quadword) loads from predictable offsets: base, base+1024, base+2048, etc.

2. **No data reorganization needed**. The naive version had to use `punpcklqdq` to interleave data from different memory locations. The vectorized version eliminates this entirely - the data is already in the right layout for SIMD processing.

3. **Better instruction-level parallelism**. The simpler instruction sequence allows the CPU's out-of-order execution to work more effectively. There are fewer dependencies between operations.

4. **Cache-friendly for this workload**. While strided access can sometimes have worse cache behavior than sequential access, our working set (1024 × 8 = 8KB) fits comfortably in L1 cache, so the strided pattern doesn't introduce cache penalties. For much larger datasets, this trade-off would need careful consideration.

The benchmark results speak for themselves: **the vectorized version is approximately 2x faster than the naive implementation**.

Benchmark Results produced with [`picobench`](https://github.com/iboB/picobench):

```
Name (* = baseline)       |   Dim   |  Total ms |  ns/op  |Baseline| Ops/second
--------------------------|--------:|----------:|--------:|-------:|----------:
 bench_bitpack_naive *    |       8 |     0.003 |     379 |      - |  2632444.9
 bench_bitpack_vectorized |       8 |     0.002 |     198 |  0.522 |  5040957.8
 bench_bitpack_naive *    |      64 |     0.021 |     333 |      - |  2997517.7
 bench_bitpack_vectorized |      64 |     0.010 |     153 |  0.459 |  6527947.8
 bench_bitpack_naive *    |     512 |     0.177 |     346 |      - |  2886881.6
 bench_bitpack_vectorized |     512 |     0.092 |     180 |  0.520 |  5554229.7
 bench_bitpack_naive *    |    4096 |     1.327 |     323 |      - |  3086875.7
 bench_bitpack_vectorized |    4096 |     0.668 |     163 |  0.504 |  6130204.0
 bench_bitpack_naive *    |    8192 |     3.140 |     383 |      - |  2609094.2
 bench_bitpack_vectorized |    8192 |     1.345 |     164 |  0.428 |  6090638.4
```

This example demonstrates a counterintuitive principle in performance optimization: the way we access our data matters more than we might think. By restructuring array accesses to align with how SIMD instructions operate, we can help the compiler generate dramatically more efficient code - even when the change seems to make the algorithm "worse" from a traditional optimization perspective.

## Bonus: The Same Principle in C#

While we've been exploring C++ throughout this article, the principle of SIMD-friendly access patterns applies to other languages as well. C# provides explicit SIMD support through the `System.Runtime.Intrinsics` namespace, allowing to write vectorized code directly.

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

Benchmarking with `BenchmarkDotNet`:

```
| Method | Mean     | Error    | StdDev   | Median   | Ratio | RatioSD |
|------- |---------:|---------:|---------:|---------:|------:|--------:|
| Naive  | 759.0 ns | 15.15 ns | 37.43 ns | 746.0 ns |  1.00 |    0.07 |
| SIMD   | 147.4 ns |  1.94 ns |  1.52 ns | 147.4 ns |  0.19 |    0.01 |
```

SIMD implementation significantly outperforms the naive scalar approach, demonstrating that the principle of SIMD-friendly access patterns is language-agnostic.
The lesson carries across: whether you're writing C++, C#, or any other language with SIMD support, thinking about how your data access patterns align with SIMD operations is crucial for achieving optimal performance.

---
layout:    "single"
classes:   "wide"
title:     "Luhn Algorithm: Credit Card Number Validation in Nanoseconds"
excerpt:   "Ever mistyped your credit card number and gotten an instant error? That split-second check isn't database magic - it's clever 1950s math that catches typos faster than you can blink. From credit cards to ISBNs, this elegant checksum algorithm silently guards against human error millions of times each day."
tags:      "checksum data-validation luhn"
date:      "2024-12-24"
header:
 teaser: /assets/posts/luhn-algorithm/logo.png
---

Have you ever mistyped your credit card number on a website and gotten an instant error message? Pretty convenient, right? But here's the interesting part - the website doesn't need to check with Visa or Mastercard backend to know you made a mistake. "Massive database check" is actually solved with clever math from the 1950s called the [Luhn algorithm](https://en.wikipedia.org/wiki/Luhn_algorithm) (Luhn formula). The same principle is used everywhere - from ID and TAX numbers to car VIN or ISBN numbers - making it possible to catch simple typing errors without making a single network request.

The "magic" behind is surprisingly simple - it's basically a clever checksum that catches the most common human errors: mistyping a digit or switching two digits around. Here's how it actually works in practice: let's say you're typing in your credit card number: `4532 9145 6789 0123`. The last digit `3` is a check digit. To validate we starting from the rightmost digit, multiply every second digit by `2`. If multiplying gives us a two-digit number, we add those digits together (or subtract 9 - it's the same). Then we sum up all numbers. The total should be divisible by 10. If it's not - we've caught an error.

Let's walk through it step by step in details. Visa card - `4532 9145 6789 0123`.

1. First, write the number from right to left: `3 2 1 0 9 8 7 6 5 4 1 9 2 3 5 4`
2. Double every second digit:
    * `3 (2×2) 1 (0×2) 9 (8×2) 7 (6×2) 5 (4×2) 1 (9×2) 2 (3×2) 5 (4×2)`
    * `3 4 1 0 9 16 7 12 5 8 1 18 2 6 5 8`
3. Add digits of doubled numbers that are greater than 9:
    * `16` becomes `1+6 = 7` (or `16-9 = 7`).
    * `12` becomes `1+2 = 3` (or `12-9 = 3`).
    * `18` becomes `1+8 = 9` (or `18-9 = 9`).
    * So now we have: `4 1 0 9 7 7 3 5 8 1 9 2 6 5 8`.
4. Sum all digits: `3+4+1+0+9+7+7+3+5+8+1+9+2+6+5+8 = 78`.
5. Check if divisible by `10`: `78 ÷ 10 = 7 remainder 8`.
6. Not divisible by `10`, so this would be an invalid number!

To make this number valid, we need to change the check digit from `3` to `5`. In this case, the sum `(5+4+1+0+9+7+7+3+5+8+1+9+2+6+5+8) = 80` is divisible by 10 (`80 ÷ 10 = 8 remainder 0`). More formally, to calculate the check digit, we need to calculate the total sum of the "payload" (rest of the digits) as usual. The check digit is then equal to `(10 - (TotalSumOfPayload mod 10)) mod 10`.

Fascinating is how this simple pattern catches the most common mistakes people make when typing numbers. Sure, it's not perfect - some errors can slip through (e.g. it will not detect `22` ↔ `55`, `33` ↔ `66` or `44` ↔ `77`) - but for something that takes nanoseconds to calculate and requires zero external validation, that's pretty good.

Here is an example of simple (no edge cases handling) C# function which validate number:

```csharp
bool IsValid(string number)
{
    var sum = 0;

    // Start false since first digit (from right) is the check digit
    var multipleBy2 = false;

    // Process from right to left
    for (var i = number.Length - 1; i >= 0; i--)
    {
        var symbol = number[i];

        // Skip any whitespace characters (e.g., spaces between number groups)
        if (char.IsWhiteSpace(symbol))
            continue;
        
        var digit = symbol - '0';
        
        if (multipleBy2)
        {
            digit *= 2;

            // If result > 9, subtract 9 (equivalent to summing the digits)
            // Example: 8 * 2 = 16 -> 1 + 6 = 7 -> or 16 - 9 = 7
            if (digit > 9)
                digit -= 9;
        }
        
        sum += digit;
        multipleBy2 = !multipleBy2;
    }
    
    // Valid if sum is divisible by 10
    return sum % 10 == 0;
}
```

And here is an example of simple (no edge cases handling) C# function that generate check digit for "payload" number:

```csharp
int GenerateCheckDigit(string payload)
{
    var sum = 0;

    // Start true since first digit (from right) is NOT the check digit
    var multipleBy2 = true;

    // Process from right to left
    for (var i = payload.Length - 1; i >= 0; i--)
    {
        var symbol = payload[i];

        // Skip any whitespace characters (e.g., spaces between number groups)
        if (char.IsWhiteSpace(symbol))
            continue;

        var digit = symbol - '0';
            
        if (multipleBy2)
        {
            digit *= 2;

            // If result > 9, subtract 9 (equivalent to summing the digits)
            // Example: 8 * 2 = 16 -> 1 + 6 = 7 -> or 16 - 9 = 7
            if (digit > 9)
                digit -= 9;
        }
        
        sum += digit;
        multipleBy2 = !multipleBy2;
    }
    
    // Calculate check digit that would make total sum divisible by 10
    return (10 - sum % 10) % 10;
}
```

Bonus, benchmark results (system: [Intel© Core™ i7-10510U CPU @ 1.80GHz × 4](https://www.intel.com/content/www/us/en/products/sku/196449/intel-core-i710510u-processor-8m-cache-up-to-4-90-ghz/specifications.html), RAM 16 GB, Debian GNU/Linux 11 bullseye (x86-64), .NET 9:

| Method             | Mean     | Error    | StdDev   | Allocated |
|------------------- |---------:|---------:|---------:|----------:|
| IsValid            | 29.27 ns | 0.608 ns | 0.791 ns |         - |
| GenerateCheckDigit | 31.09 ns | 0.639 ns | 1.120 ns |         - |

Described Luhn algorithm is actually a specific case of a more general Luhn algorithm where each position can have its own weight. While credit cards use the alternating 1,2 pattern, other systems use different weight sequences to catch different types of errors or provide stronger validation. For example International Standard Book Number (ISBN-13) uses [alternating 1,3 pattern](http://www.hahnlibrary.net/libraries/isbncalc.html) to compute its check digit, Vehicle Identification Numbers (VIN) uses a more complex weight system: [8,7,6,5,4,3,2,10,0,9,8,7,6,5,4,3,2](https://en.wikipedia.org/wiki/Vehicle_identification_number#Check-digit_calculation). 

Let's look at how it works generically:
1. Each position in the number gets assigned a weight.
2. Each digit is multiplied by its corresponding weight.
3. If the result is greater than 9, we sum its digits (just like in the credit card version).
4. Sum all results.
5. Check if the total is divisible by a chosen modulus (credit cards use 10).

That's it for now - catch you next time when we dive into more hidden gems of everyday computing that make our digital lives just a bit smoother.

---

**Bonus: Luhn Algorithm Online Validator**

Enter a card number to validate it using the Luhn algorithm, or generate a check digit for partial numbers

<div>
    <div>
        <label for="card-number">Credit Card Number:</label>
        <input type="text" 
               id="card-number"
               placeholder="Enter Credit Card Number"
               style="border: 1px solid white; border-radius: 4px;">
    </div>

    <div>
        <button onclick="validate()"
                style="border: none; border-radius: 4px; padding: 1rem; background-color: black; color: white;">
            Validate
        </button>
        <button onclick="generateCheck()"
                style="border: none; border-radius: 4px; padding: 1rem; background-color: black; color: white;">
            Generate Check Digit
        </button>
    </div>

    <div id="card-number-proc-result"></div>
</div>

<script>
    function calculateLuhnSum(number, hasCheckDigit) {
        let sum = 0;
        let isSecond = !hasCheckDigit;
        
        for (let i = number.length - 1; i >= 0; i--) {
            let symbol = number[i]
            if (symbol < '0' || symbol > '9')
                continue

            let digit = symbol - '0';
            
            if (isSecond) {
                digit *= 2;
                if (digit > 9) {
                    digit -= 9;
                }
            }
            
            sum += digit;
            isSecond = !isSecond;
        }
        
        return sum;
    }

    function isValidNumberFormat(number) {
        return number && /^[\d ]+$/.test(number);
    }

    function validate() {
        const number = document.getElementById('card-number').value;
        const resultDiv = document.getElementById('card-number-proc-result');
        
        if (!isValidNumberFormat(number)) {
            resultDiv.style.color = 'red';
            resultDiv.textContent = 'Please enter a valid number (digits only)';
            return;
        }

        const sum = calculateLuhnSum(number, true);
        const isValid = sum % 10 === 0;
        
        if (isValid) {
            resultDiv.style.color = 'lime';
            resultDiv.innerHTML = `Valid number!<br>Total sum: ${sum} (divisible by 10)`;
        } else {
            resultDiv.style.color = 'red';
            resultDiv.innerHTML = `Invalid number!<br>Total sum: ${sum} (not divisible by 10)`;
        }
    }

    function generateCheck() {
        const number = document.getElementById('card-number').value;
        const resultDiv = document.getElementById('card-number-proc-result');
        
        if (!isValidNumberFormat(number)) {
            resultDiv.style.color = 'red';
            resultDiv.textContent = 'Please enter a valid number (digits only)';
            return;
        }

        const sum = calculateLuhnSum(number, false);
        const checkDigit = (10 - (sum % 10)) % 10;
        
        resultDiv.style.color = 'lime';
        resultDiv.innerHTML = `Check digit: <strong>${checkDigit}</strong><br>Complete number: <strong>${number}${checkDigit}</strong>`;
    }

    document.getElementById('card-number').addEventListener('keypress', function(e) {
        if (e.key === 'Enter')
            validate();
    });
</script>

---

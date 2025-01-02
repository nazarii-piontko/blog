---
layout:    "single"
classes:   "wide"
title:     "Numbers Rounding: More Than One Way"
excerpt:   "Programming languages often use `banker's rounding` - rounding to the nearest even digit - which means 1.25 becomes 1.2 while 1.35 becomes 1.4, contradicting the familiar rule of always rounding 5 up"
tags:      "math"
date:      "2025-01-02"
---

Default number rounding rules can differ across programming languages, and almost nobody notices until it's too late. The problem isn't that the implementations are wrong—it's that they're doing something completely different from what developers expect.

Take this C# code:
```csharp
Math.Round(1.25, 1) // Returns 1.2
Math.Round(1.35, 1) // Returns 1.4
```

This behavior might drive developers crazy because it contradicts what we learned in school. We were all taught that 5 rounds up. Always. So why does C# round 1.25 down to 1.2?

The answer lies in IEEE 754 standard, which says numbers ending in .5 should round to the nearest even digit. It also called banker's rounding. This means 1.25 goes to 1.2 (2 is even) while 1.35 goes to 1.4 (4 is even).

While this sounds like an academic detail, it causes real production issues. Cross-platform applications are especially vulnerable - JavaScript by default rounds up for .5 (also called "round away from zero") while C# rounds to even. Even Excel and Google Sheets have the same default rounding rules. This tiny difference might creating systematic errors that are hard to track down.

The IEEE approach does have valid mathematical reasons. Traditional "round up at .5" creates an upward bias because every .5 gets rounded up. Round-to-even eliminates this bias by going up half the time and down half the time. For large-scale systems processing millions of values, this statistical really fairness matters.

But mathematical elegance doesn't help when your financial reports don't match across systems. That's why C# gives us an escape hatch:

```csharp
// Traditional rounding that actually matches what humans expect
Math.Round(1.25, 1, MidpointRounding.AwayFromZero) // Returns 1.3
```

The real issue isn't about which rounding method is "correct" - they all have valid use cases. Banking systems need statistical fairness. User interfaces might need to match human expectations. Scientific computing sometimes needs truncation instead of rounding.

The problem is that most developers aren't making an active choice. They're using their language's default behavior without realizing it might not match what they want. And by the time they notice, it's usually because something has already gone wrong in production.

So make the choice explicit. If you're building financial software, decide up front how you'll handle rounding. Document it. Test edge cases. And whatever you do, don't assume `Math.Round()` works like you learned in grade school.

---
layout:    "single"
classes:   "wide"
title:     "Universal Scalability Law"
excerpt:   "Ever wonder why doubling database server's CPU cores doesn't double performance? Through real-world AWS RDS benchmarks, we'll explore the Universal Scalability Law and learn why throwing more hardware at performance problems isn't always the answer. Tests with RDS instances revealed some surprising patterns that might change how you approach your next capacity planning meeting."
tags:      "capacity-planning"
date:      "2025-01-27"
---

Have you ever added more vCPU to the cloud database or service instance expecting a nice performance boost, only to see disappointing results? Think about the last time you scaled 2x or 4x expecting corresponding improvement?  While it seems logical that doubling vCPU should double performance, real systems rarely work exact that way. There's actually fascinating math behind this common frustration.

Welcome the Universal Scalability Law (USL), developed by [Dr. Neil Gunther in 1993](http://www.perfdynamics.com/Papers/njgCMG93.pdf). It's not just another academic formula - it's a practical tool that explains why systems hit performance walls. Whether we're vertically scaling a database instance or adding instances to services to scale horizontally, USL helps predict when we'll hit diminishing returns and why throwing more hardware at the problem won't necessary help.

The formula might look intimidating but it captures a fundamental truth about system performance:

$$ C(N) = \frac{N}{1 + α \cdot (N-1) + β \cdot N \cdot (N-1)} $$

`N` represents any resource or capacity we're trying to scale - this could be hardware resources (like vCPU count or I/O throughput) or software capacity (like concurrent database connections). The function `C(N)` gives us a relative performance ratio that shows how performance changes as we scale up, always compared to our baseline case.

Let's look at two common scenarios:

When measuring database throughput, `N` might represent the number of simultaneous users accessing the system. In this case, `C(N)` shows us the relative throughput compared to having just one user. For example, if we measure that one user achieves 10 requests per second, and two users together achieve 19 requests per second, we can calculate:

* `C(1) = 1` (baseline)
* `C(2) = 19/10 = 1.9` (meaning we get 1.9 times higher throughput with two users)

When testing vertical scaling, `N` represents the number of vCPUs, and `C(N)` shows the performance ratio compared to using a single vCPU. For instance, if a single-vCPU configuration processes 10 transactions per second at maximum, and a four-vCPU configuration processes 35 transactions per second, then:

* `C(1) = 1` (baseline)
* `C(4) = 35/10 = 3.5` (meaning we get 3.5 times the performance with four vCPUs)

Where things get really interesting is in those two Greek letters - `α` (alpha) and `β` (beta) - contention and coherency. We might think of contention as baristas sharing a single espresso machine - more baristas mean longer queues to use shared resource. Each barista has to wait their turn to use the machine. Coherency is trickier - it's the overhead of keeping everything in sync, like baristas coordinating who makes which drinks and updating the shared order board. As we add more baristas, these effects compound until they start eating into our performance gains.

Where USL gets really interesting - it allows to predict scaling behavior before spending money on hardware. Run some benchmarks with different vCPU counts, use some math tools to estimate parameters (like Python [`curve_fit`](https://docs.scipy.org/doc/scipy/reference/generated/scipy.optimize.curve_fit.html) from `scipy.optimize`), plot the results, and USL will tell you whether upgrading to that 32-core instance will actually help or just waste money.

Lets have a look on how USL works in practice using [PostgreSQL 16 on AWS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_PostgreSQL.html). I have ran some benchmarks using different AWS RDS for PostgreSQL instance sizes to see how vertical scaling really performs. I wanted to simulate a real-world scenario, so I used [TPC-B](https://www.postgresql.org/docs/current/pgbench.html#TRANSACTIONS-AND-SCRIPTS) - a classic banking benchmark that's been the industry standard. Think of it as simulating a bank with multiple tellers processing transactions simultaneously. Each transaction updates account balances, records history, and updates branch statistics - pretty much what you'd expect from a write-heavy financial system.

I picked 3 RDS instances running on AWS's Graviton2 processors: `db.m6g.large`, `db.m6g.xlarge`, and `db.m6g.2xlarge`. To keep things clean, I ran the load generator ([pgbench](https://www.postgresql.org/docs/current/pgbench.html)) on a separate [EC2](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/concepts.html) instance in the same [availability zone](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-regions-availability-zones.html#concepts-availability-zones) - no point in letting higher network latency mess with results. The database was configured with 5 million accounts, 500,000 tellers, and 50,000 branches (`-s 50`). Why these numbers? Simple - I wanted the dataset too big to fit in memory. Real databases don't always have the luxury of keeping everything in RAM. I then hammered each instance with an increasing number of concurrent connections, starting from 1 and going all the way up to 128. This way, we can see how each instance size handles growing concurrency pressure. Each test was run 4 times and results were averaged to get more consistent data. 

<div class="chart">
    <canvas id="benchmark-results-tps"></canvas>
</div>

<div class="chart">
    <canvas id="benchmark-results-ratio"></canvas>
</div>

The upper chart shows raw throughput (TPS) for three RDS instances as I increase client connections from 1 to 128. Dotted lines represent actual measurements, while solid lines show the USL approximation that closely follows the real-world data. The bottom chart shows performance ratios relative to the `large` instance.

The benchmark results tell a story about what happens when we throw more hardware at PostgreSQL. Our biggest `db.m6g.2xlarge` instance peaked at around 7,300 transactions per second before hitting a wall, while the much smaller `db.m6g.large` peaked at 2,400 transactions per second. At first glance, that might seem reasonable - bigger instance, better performance. But the second graph comparing the performance ratios between instance sizes, and this is where it gets interesting. In a perfect world, the `xlarge` (2x the price of large) should give us 2x performance, and the `2xlarge` (4x the price) should give us 4x performance. Reality? The `xlarge` managed to provide even more than 2x improvement - 2.2x improvement over the `large` instance (probably due to the bigger cache). On the other hand, the `2xlarge` oscillates only at 3.5x - meaning that last doubling of resources gave us diminishing returns.

Why does this happen? Again two key factors: contention and coherency. They represent the real-world friction that stops from getting that perfect linear scaling. Contention reflects queries waiting for table locks or transactions competing for storage bandwidth. Coherency captures an overhead of keeping everything synchronized. Like what it takes to maintain ACID properties across multiple database connections, or keeping cache coherent across parallel transactions. We can see this clearly in how the curves flatten out and later actually start dropping at higher connection counts. The `xlarge` instance, in particular, show this pattern beautifully.

Instead of conclusion, here's a practical guide to using USL: Start by running load tests on the current system with increasing concurrency (1, 2, 4, 8, 16, 32, 64 concurrent operations) and measure throughput for each level. Normalize these results with single-operation throughput as baseline 1.0, then fit the points to the USL formula. The resulting alpha and beta values reveal your next steps - if alpha (contention) dominates and your curve flattens early, the system is hitting resource contention and hardware upgrades might help. But if beta (coherency) dominates and performance actually drops at higher concurrency, the system is hitting fundamental coordination overhead that more hardware probably won't fix much - time to look at architectural changes instead. That's the beauty of USL - it tells you whether to spend money on infrastructure or invest time in optimization before you make the decision.

<script src="https://cdn.mathjax.org/mathjax/latest/MathJax.js?config=TeX-AMS-MML_HTMLorMML" type="text/javascript" async></script>
<script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
<script>
    const tpsLargeActualData = [
        {x: 1, y: 418}, {x: 2, y: 766}, {x: 4, y: 1275}, {x: 6, y: 1629}, {x: 8, y: 1851},
        {x: 10, y: 2145}, {x: 12, y: 2230}, {x: 14, y: 2353}, {x: 16, y: 2424}, {x: 18, y: 2312},
        {x: 20, y: 2487}, {x: 22, y: 2545}, {x: 24, y: 2228}, {x: 26, y: 2260}, {x: 28, y: 2529},
        {x: 30, y: 2226}, {x: 32, y: 2402}, {x: 34, y: 2328}, {x: 36, y: 2097}, {x: 38, y: 2004},
        {x: 40, y: 2379}, {x: 42, y: 2163}, {x: 44, y: 2407}, {x: 46, y: 2340}, {x: 48, y: 1998},
        {x: 50, y: 2367}, {x: 52, y: 2282}, {x: 54, y: 2179}, {x: 56, y: 2358}, {x: 58, y: 2212},
        {x: 60, y: 2103}, {x: 62, y: 2304}, {x: 64, y: 2141}, {x: 66, y: 2099}, {x: 68, y: 2188},
        {x: 70, y: 1960}, {x: 72, y: 2089}, {x: 74, y: 2218}, {x: 76, y: 2081}, {x: 78, y: 2188},
        {x: 80, y: 2263}, {x: 82, y: 1959}, {x: 84, y: 1970}, {x: 86, y: 2221}, {x: 88, y: 2025},
        {x: 90, y: 1997}, {x: 92, y: 2061}, {x: 94, y: 1874}, {x: 96, y: 2142}, {x: 98, y: 2198},
        {x: 100, y: 1713}, {x: 102, y: 1985}, {x: 104, y: 2065}, {x: 106, y: 1963}, {x: 108, y: 1996},
        {x: 110, y: 2119}, {x: 112, y: 1963}, {x: 114, y: 2178}, {x: 116, y: 2050}, {x: 118, y: 2039},
        {x: 120, y: 2096}, {x: 122, y: 1949}, {x: 124, y: 1649}, {x: 126, y: 1994}, {x: 128, y: 1931}
    ];

    const tpsLargeEstData = [
        {x: 1, y: 418}, {x: 2, y: 741}, {x: 4, y: 1205}, {x: 6, y: 1517}, {x: 8, y: 1738},
        {x: 10, y: 1899}, {x: 12, y: 2020}, {x: 14, y: 2112}, {x: 16, y: 2183}, {x: 18, y: 2237},
        {x: 20, y: 2279}, {x: 22, y: 2312}, {x: 24, y: 2337}, {x: 26, y: 2355}, {x: 28, y: 2368},
        {x: 30, y: 2377}, {x: 32, y: 2383}, {x: 34, y: 2386}, {x: 36, y: 2386}, {x: 38, y: 2385},
        {x: 40, y: 2381}, {x: 42, y: 2376}, {x: 44, y: 2370}, {x: 46, y: 2363}, {x: 48, y: 2355},
        {x: 50, y: 2346}, {x: 52, y: 2337}, {x: 54, y: 2326}, {x: 56, y: 2316}, {x: 58, y: 2305},
        {x: 60, y: 2293}, {x: 62, y: 2282}, {x: 64, y: 2270}, {x: 66, y: 2258}, {x: 68, y: 2246},
        {x: 70, y: 2233}, {x: 72, y: 2221}, {x: 74, y: 2208}, {x: 76, y: 2195}, {x: 78, y: 2183},
        {x: 80, y: 2170}, {x: 82, y: 2157}, {x: 84, y: 2145}, {x: 86, y: 2132}, {x: 88, y: 2119},
        {x: 90, y: 2107}, {x: 92, y: 2094}, {x: 94, y: 2082}, {x: 96, y: 2069}, {x: 98, y: 2057},
        {x: 100, y: 2045}, {x: 102, y: 2032}, {x: 104, y: 2020}, {x: 106, y: 2008}, {x: 108, y: 1996},
        {x: 110, y: 1984}, {x: 112, y: 1973}, {x: 114, y: 1961}, {x: 116, y: 1949}, {x: 118, y: 1938},
        {x: 120, y: 1926}, {x: 122, y: 1915}, {x: 124, y: 1904}, {x: 126, y: 1893}, {x: 128, y: 1882}
    ];

    const tpsXlargeActualData = [
        {x: 1, y: 317}, {x: 2, y: 617}, {x: 4, y: 1073}, {x: 6, y: 1484}, {x: 8, y: 1926},
        {x: 10, y: 2316}, {x: 12, y: 2601}, {x: 14, y: 2938}, {x: 16, y: 3174}, {x: 18, y: 3445},
        {x: 20, y: 3706}, {x: 22, y: 3856}, {x: 24, y: 3994}, {x: 26, y: 4183}, {x: 28, y: 4268},
        {x: 30, y: 4412}, {x: 32, y: 4423}, {x: 34, y: 4468}, {x: 36, y: 4507}, {x: 38, y: 4610},
        {x: 40, y: 4579}, {x: 42, y: 4611}, {x: 44, y: 4481}, {x: 46, y: 4512}, {x: 48, y: 4602},
        {x: 50, y: 4654}, {x: 52, y: 4638}, {x: 54, y: 4609}, {x: 56, y: 4698}, {x: 58, y: 4597},
        {x: 60, y: 4446}, {x: 62, y: 4558}, {x: 64, y: 4452}, {x: 66, y: 4421}, {x: 68, y: 4551},
        {x: 70, y: 4618}, {x: 72, y: 4571}, {x: 74, y: 4304}, {x: 76, y: 4381}, {x: 78, y: 4397},
        {x: 80, y: 4432}, {x: 82, y: 4385}, {x: 84, y: 4347}, {x: 86, y: 4322}, {x: 88, y: 4438},
        {x: 90, y: 4475}, {x: 92, y: 4411}, {x: 94, y: 4325}, {x: 96, y: 4481}, {x: 98, y: 4292},
        {x: 100, y: 4391}, {x: 102, y: 4235}, {x: 104, y: 4171}, {x: 106, y: 4278}, {x: 108, y: 4238},
        {x: 110, y: 4252}, {x: 112, y: 4033}, {x: 114, y: 4029}, {x: 116, y: 4154}, {x: 118, y: 4168},
        {x: 120, y: 4268}, {x: 122, y: 4227}, {x: 124, y: 4277}, {x: 126, y: 4138}, {x: 128, y: 4160}
    ];

    const tpsXlargeEstData = [
        {x: 1, y: 317}, {x: 2, y: 612}, {x: 4, y: 1145}, {x: 6, y: 1609}, {x: 8, y: 2014},
        {x: 10, y: 2368}, {x: 12, y: 2678}, {x: 14, y: 2950}, {x: 16, y: 3188}, {x: 18, y: 3396},
        {x: 20, y: 3579}, {x: 22, y: 3739}, {x: 24, y: 3879}, {x: 26, y: 4001}, {x: 28, y: 4107},
        {x: 30, y: 4200}, {x: 32, y: 4280}, {x: 34, y: 4349}, {x: 36, y: 4408}, {x: 38, y: 4458},
        {x: 40, y: 4501}, {x: 42, y: 4536}, {x: 44, y: 4565}, {x: 46, y: 4588}, {x: 48, y: 4607},
        {x: 50, y: 4620}, {x: 52, y: 4630}, {x: 54, y: 4636}, {x: 56, y: 4639}, {x: 58, y: 4638},
        {x: 60, y: 4635}, {x: 62, y: 4630}, {x: 64, y: 4622}, {x: 66, y: 4612}, {x: 68, y: 4601},
        {x: 70, y: 4588}, {x: 72, y: 4574}, {x: 74, y: 4558}, {x: 76, y: 4541}, {x: 78, y: 4524},
        {x: 80, y: 4505}, {x: 82, y: 4485}, {x: 84, y: 4465}, {x: 86, y: 4444}, {x: 88, y: 4423},
        {x: 90, y: 4401}, {x: 92, y: 4379}, {x: 94, y: 4356}, {x: 96, y: 4333}, {x: 98, y: 4310},
        {x: 100, y: 4286}, {x: 102, y: 4263}, {x: 104, y: 4239}, {x: 106, y: 4215}, {x: 108, y: 4191},
        {x: 110, y: 4167}, {x: 112, y: 4143}, {x: 114, y: 4119}, {x: 116, y: 4094}, {x: 118, y: 4070},
        {x: 120, y: 4046}, {x: 122, y: 4022}, {x: 124, y: 3998}, {x: 126, y: 3974}, {x: 128, y: 3951}
    ];

    const tps2xlargeActualData = [
        {x: 1, y: 255}, {x: 2, y: 478}, {x: 4, y: 919}, {x: 6, y: 1241}, {x: 8, y: 1573},
        {x: 10, y: 1907}, {x: 12, y: 2205}, {x: 14, y: 2533}, {x: 16, y: 2880}, {x: 18, y: 3169},
        {x: 20, y: 3463}, {x: 22, y: 3751}, {x: 24, y: 4010}, {x: 26, y: 4302}, {x: 28, y: 4550},
        {x: 30, y: 4793}, {x: 32, y: 5042}, {x: 34, y: 5278}, {x: 36, y: 5459}, {x: 38, y: 5587},
        {x: 40, y: 5793}, {x: 42, y: 6023}, {x: 44, y: 6172}, {x: 46, y: 6317}, {x: 48, y: 6421},
        {x: 50, y: 6637}, {x: 52, y: 6745}, {x: 54, y: 6835}, {x: 56, y: 6942}, {x: 58, y: 6765},
        {x: 60, y: 6726}, {x: 62, y: 6984}, {x: 64, y: 7047}, {x: 66, y: 6880}, {x: 68, y: 6813},
        {x: 70, y: 7206}, {x: 72, y: 7431}, {x: 74, y: 7460}, {x: 76, y: 7382}, {x: 78, y: 7327},
        {x: 80, y: 7407}, {x: 82, y: 7482}, {x: 84, y: 7364}, {x: 86, y: 7425}, {x: 88, y: 7411},
        {x: 90, y: 7491}, {x: 92, y: 7604}, {x: 94, y: 7504}, {x: 96, y: 7456}, {x: 98, y: 7432},
        {x: 100, y: 7375}, {x: 102, y: 7337}, {x: 104, y: 7329}, {x: 106, y: 7243}, {x: 108, y: 7201},
        {x: 110, y: 7388}, {x: 112, y: 7502}, {x: 114, y: 7364}, {x: 116, y: 7228}, {x: 118, y: 7093},
        {x: 120, y: 7100}, {x: 122, y: 6981}, {x: 124, y: 6873}, {x: 126, y: 6894}, {x: 128, y: 7349}
    ];

    const tps2xlargeEstData = [
        {x: 1, y: 255}, {x: 2, y: 502}, {x: 4, y: 975}, {x: 6, y: 1419}, {x: 8, y: 1837},
        {x: 10, y: 2229}, {x: 12, y: 2597}, {x: 14, y: 2943}, {x: 16, y: 3267}, {x: 18, y: 3570},
        {x: 20, y: 3855}, {x: 22, y: 4121}, {x: 24, y: 4371}, {x: 26, y: 4604}, {x: 28, y: 4822},
        {x: 30, y: 5026}, {x: 32, y: 5217}, {x: 34, y: 5394}, {x: 36, y: 5560}, {x: 38, y: 5715},
        {x: 40, y: 5859}, {x: 42, y: 5993}, {x: 44, y: 6117}, {x: 46, y: 6233}, {x: 48, y: 6340},
        {x: 50, y: 6439}, {x: 52, y: 6531}, {x: 54, y: 6616}, {x: 56, y: 6695}, {x: 58, y: 6767},
        {x: 60, y: 6833}, {x: 62, y: 6894}, {x: 64, y: 6950}, {x: 66, y: 7001}, {x: 68, y: 7047},
        {x: 70, y: 7089}, {x: 72, y: 7127}, {x: 74, y: 7161}, {x: 76, y: 7191}, {x: 78, y: 7218},
        {x: 80, y: 7242}, {x: 82, y: 7262}, {x: 84, y: 7280}, {x: 86, y: 7295}, {x: 88, y: 7308},
        {x: 90, y: 7318}, {x: 92, y: 7326}, {x: 94, y: 7332}, {x: 96, y: 7336}, {x: 98, y: 7338},
        {x: 100, y: 7338}, {x: 102, y: 7337}, {x: 104, y: 7334}, {x: 106, y: 7329}, {x: 108, y: 7323},
        {x: 110, y: 7316}, {x: 112, y: 7308}, {x: 114, y: 7298}, {x: 116, y: 7288}, {x: 118, y: 7276},
        {x: 120, y: 7263}, {x: 122, y: 7250}, {x: 124, y: 7235}, {x: 126, y: 7220}, {x: 128, y: 7204}
    ];

    const ratioXLData = [
        {x: 1, y: 0.8}, {x: 2, y: 0.8}, {x: 4, y: 0.8}, {x: 6, y: 0.9}, {x: 8, y: 1.0},
        {x: 10, y: 1.1}, {x: 12, y: 1.2}, {x: 14, y: 1.2}, {x: 16, y: 1.3}, {x: 18, y: 1.5},
        {x: 20, y: 1.5}, {x: 22, y: 1.5}, {x: 24, y: 1.8}, {x: 26, y: 1.9}, {x: 28, y: 1.7},
        {x: 30, y: 2.0}, {x: 32, y: 1.8}, {x: 34, y: 1.9}, {x: 36, y: 2.1}, {x: 38, y: 2.3},
        {x: 40, y: 1.9}, {x: 42, y: 2.1}, {x: 44, y: 1.9}, {x: 46, y: 1.9}, {x: 48, y: 2.3},
        {x: 50, y: 2.0}, {x: 52, y: 2.0}, {x: 54, y: 2.1}, {x: 56, y: 2.0}, {x: 58, y: 2.1},
        {x: 60, y: 2.1}, {x: 62, y: 2.0}, {x: 64, y: 2.1}, {x: 66, y: 2.1}, {x: 68, y: 2.1},
        {x: 70, y: 2.4}, {x: 72, y: 2.2}, {x: 74, y: 1.9}, {x: 76, y: 2.1}, {x: 78, y: 2.0},
        {x: 80, y: 2.0}, {x: 82, y: 2.2}, {x: 84, y: 2.2}, {x: 86, y: 1.9}, {x: 88, y: 2.2},
        {x: 90, y: 2.2}, {x: 92, y: 2.1}, {x: 94, y: 2.3}, {x: 96, y: 2.1}, {x: 98, y: 2.0},
        {x: 100, y: 2.6}, {x: 102, y: 2.1}, {x: 104, y: 2.0}, {x: 106, y: 2.2}, {x: 108, y: 2.1},
        {x: 110, y: 2.0}, {x: 112, y: 2.1}, {x: 114, y: 1.8}, {x: 116, y: 2.0}, {x: 118, y: 2.0},
        {x: 120, y: 2.0}, {x: 122, y: 2.2}, {x: 124, y: 2.6}, {x: 126, y: 2.1}, {x: 128, y: 2.2}
    ];

    const ratio2XLData = [
        {x: 1, y: 0.6}, {x: 2, y: 0.6}, {x: 4, y: 0.7}, {x: 6, y: 0.8}, {x: 8, y: 0.8},
        {x: 10, y: 0.9}, {x: 12, y: 1.0}, {x: 14, y: 1.1}, {x: 16, y: 1.2}, {x: 18, y: 1.4},
        {x: 20, y: 1.4}, {x: 22, y: 1.5}, {x: 24, y: 1.8}, {x: 26, y: 1.9}, {x: 28, y: 1.8},
        {x: 30, y: 2.2}, {x: 32, y: 2.1}, {x: 34, y: 2.3}, {x: 36, y: 2.6}, {x: 38, y: 2.8},
        {x: 40, y: 2.4}, {x: 42, y: 2.8}, {x: 44, y: 2.6}, {x: 46, y: 2.7}, {x: 48, y: 3.2},
        {x: 50, y: 2.8}, {x: 52, y: 3.0}, {x: 54, y: 3.1}, {x: 56, y: 2.9}, {x: 58, y: 3.1},
        {x: 60, y: 3.2}, {x: 62, y: 3.0}, {x: 64, y: 3.3}, {x: 66, y: 3.3}, {x: 68, y: 3.1},
        {x: 70, y: 3.7}, {x: 72, y: 3.6}, {x: 74, y: 3.4}, {x: 76, y: 3.5}, {x: 78, y: 3.3},
        {x: 80, y: 3.3}, {x: 82, y: 3.8}, {x: 84, y: 3.7}, {x: 86, y: 3.3}, {x: 88, y: 3.7},
        {x: 90, y: 3.8}, {x: 92, y: 3.7}, {x: 94, y: 4.0}, {x: 96, y: 3.5}, {x: 98, y: 3.4},
        {x: 100, y: 4.3}, {x: 102, y: 3.7}, {x: 104, y: 3.5}, {x: 106, y: 3.7}, {x: 108, y: 3.6},
        {x: 110, y: 3.5}, {x: 112, y: 3.8}, {x: 114, y: 3.4}, {x: 116, y: 3.5}, {x: 118, y: 3.5},
        {x: 120, y: 3.4}, {x: 122, y: 3.6}, {x: 124, y: 4.2}, {x: 126, y: 3.5}, {x: 128, y: 3.8}
    ];

    const tpsData = {
        datasets: [
            {
                label: 'db.m6g.large',
                data: tpsLargeActualData,
                borderColor: 'lime',
                backgroundColor: 'transparent',
                borderWidth: 2,
                borderDash: [5, 5], 
                tension: 0.4,
                pointRadius: 0,
                pointHoverRadius: 4
            },
            {
                label: 'db.m6g.large (aprox.)',
                data: tpsLargeEstData,
                borderColor: 'lime',
                backgroundColor: 'transparent',
                borderWidth: 1,
                tension: 0.4,
                pointRadius: 0,
                pointHoverRadius: 4
            },
            {
                label: 'db.m6g.xlarge',
                data: tpsXlargeActualData,
                borderColor: 'red',
                backgroundColor: 'transparent',
                borderWidth: 2,
                borderDash: [5, 5], 
                tension: 0.4,
                pointRadius: 0,
                pointHoverRadius: 4
            },
            {
                label: 'db.m6g.xlarge (aprox.)',
                data: tpsXlargeEstData,
                borderColor: 'red',
                backgroundColor: 'transparent',
                borderWidth: 1,
                tension: 0.4,
                pointRadius: 0,
                pointHoverRadius: 4
            },
            {
                label: 'db.m6g.2xlarge',
                data: tps2xlargeActualData,
                borderColor: 'deepskyblue',
                backgroundColor: 'transparent',
                borderWidth: 2,
                borderDash: [5, 5], 
                tension: 0.4,
                pointRadius: 0,
                pointHoverRadius: 4
            },
            {
                label: 'db.m6g.2xlarge (aprox.)',
                data: tps2xlargeEstData,
                borderColor: 'deepskyblue',
                backgroundColor: 'transparent',
                borderWidth: 1,
                tension: 0.4,
                pointRadius: 0,
                pointHoverRadius: 4
            }
        ]
    };

    const textColor = getComputedStyle(document.getElementsByClassName('chart')[0]).getPropertyValue('color');
    const tpsChartConfig = {
        type: 'line',
        data: tpsData,
        options: {
            responsive: true,
            maintainAspectRatio: true,
            plugins: {
                legend: {
                    display: true,
                    position: 'bottom',
                    labels: {
                        color: textColor
                    }
                },
                title: {
                    display: true,
                    text: 'AWS RDS for PostgresSQL Benchmark for TPS',
                    color: textColor,
                    font: {
                        size: 18
                    }
                }
            },
            scales: {
                x: {
                    type: 'linear',
                    title: {
                        display: true,
                        text: 'Clients/Connections',
                        color: textColor,
                        font: {
                            size: 18
                        }
                    },
                    grid: {
                        color: 'color-mix(in srgb, white 30%, transparent)'
                    },
                    ticks: {
                        color: textColor,
                        font: {
                            size: 18
                        }
                    }
                },
                y: {
                    title: {
                        display: true,
                        text: 'Transactions per Second',
                        color: textColor,
                        font: {
                            size: 18
                        }
                    },
                    grid: {
                        color: 'color-mix(in srgb, white 30%, transparent)'
                    },
                    ticks: {
                        color: textColor,
                        font: {
                            size: 18
                        }
                    }
                }
            }
        }
    };

    const ratioChartConfig = {
        type: 'line',
        data: {
            datasets: [
                {
                    label: 'xlarge/large (2x)',
                    data: ratioXLData,
                    borderColor: 'red',
                    backgroundColor: 'transparent',
                    borderWidth: 1.5,
                    tension: 0.1,
                    pointRadius: 0,
                    pointHoverRadius: 4
                },
                {
                    label: '2xlarge/large (4x)',
                    data: ratio2XLData,
                    borderColor: 'deepskyblue',
                    backgroundColor: 'transparent',
                    borderWidth: 1.5,
                    tension: 0.1,
                    pointRadius: 0,
                    pointHoverRadius: 4
                }
            ]
        },
        options: {
            responsive: true,
            maintainAspectRatio: true,
            plugins: {
                legend: {
                    display: true,
                    position: 'bottom',
                    labels: {
                        color: textColor
                    }
                },
                title: {
                    display: true,
                    text: 'TPS ratio for different RDS instances',
                    color: textColor,
                    font: {
                        size: 18
                    }
                }
            },
            scales: {
                x: {
                    type: 'linear',
                    title: {
                        display: true,
                        text: 'Clients/Connections',
                        color: textColor,
                        font: {
                            size: 18
                        }
                    },
                    grid: {
                        color: 'color-mix(in srgb, white 30%, transparent)'
                    },
                    ticks: {
                        color: textColor,
                        font: {
                            size: 18
                        }
                    }
                },
                y: {
                    title: {
                        display: true,
                        text: 'Ratio',
                        color: textColor,
                        font: {
                            size: 18
                        }
                    },
                    grid: {
                        color: 'color-mix(in srgb, white 30%, transparent)'
                    },
                    ticks: {
                        color: textColor,
                        font: {
                            size: 18
                        }
                    }
                }
            }
        }
    };

    new Chart(document.getElementById('benchmark-results-tps'), tpsChartConfig);
    new Chart(document.getElementById('benchmark-results-ratio'), ratioChartConfig);
</script>

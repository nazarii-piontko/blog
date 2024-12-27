---
layout:    "single"
classes:   "wide"
title:     "Capacity Planning: Understanding the 80% Server Utilization Rule"
excerpt:   "Why there is a recommendation of keeping server utilization below 80%? Using basic queueing theory, we explore how request latency grows exponentially as servers get busier, and why modern autoscaling systems trigger even earlier at 60-70%."
tags:      "capacity-planning queueing-theory"
date:      "2024-12-27"
header:
 teaser: /assets/posts/capacity-planning/utilization/logo.png
---

I plan to start a series of articles about capacity planning. While it's usually heavy on math, I'll try to keep things simple and focus on stuff we can actually use day-to-day. Being a practical software engineer myself, I care more about real-world applications than theoretical concepts.

Despite being rooted in queueing theory, there aren't many books that explain capacity planning in a more or less simpler way. I'd recommend two (still it is not very simple):

* [Mor Harchol-Balter. (2013). Performance modeling and design of computer systems : queueing theory in action. Cambridge University Press.](https://www.amazon.com/Performance-Modeling-Design-Computer-Systems/dp/1107027500)

* [Gunther, N. J., & Springerlink (Online Service. (2007). Guerrilla Capacity Planning : A Tactical Approach to Planning for Highly Scalable Applications and Services. Springer Berlin Heidelberg.](https://www.amazon.com/Guerrilla-Capacity-Planning-Tactical-Applications/dp/3540261389)

In this first article, I would like to focus on what I call the "magic 80% utilization rule". Simply put, it states that each server or containerized service instance (which is even more relevant in orchestrated environments) should stay below 70-80% of its utilization. Usually, we are primarily referring to CPU utilization, but not only that — for example, I/O matters for databases. For autoscaling setups, you'll probably want to trigger scaling even slightly earlier—around 60-70% CPU utilization.

**Why these specific numbers?**

**Why should we avoid, let's say, 90%+ CPU utilization?**

The answer is that services don't behave linearly under load. A service instance running at 85% CPU utilization doesn't just perform the same or 5% worse than at 80%; it might perform dramatically worse. 

For services with autoscaling enabled, you'll want to be even more conservative. Why? Because scaling takes time. By the time your autoscaler detects high CPU utilization, makes a scaling decision, and brings up new instances, several minutes might have passed. Starting your scaling actions at 60-70% gives your system enough headroom to handle traffic spikes while new capacity comes online.

While these numbers might sound like "magic" to some people, and others have built practical intuition around them, there are more formal mathematical theory behind them.

Let's start by establishing some terminology.

Consider a service instance with 1 vCPU processing incoming requests (it could be HTTP requests for example):

* λ (lambda) represents the average incoming request rate per unit of time, usually per minute or per second.
* μ (mu) is the service rate - service's processing rate per unit of time. On the other hand, `1/μ` is the service time — the time needed to process a request. In modern services calculation "real" service rate or service time is tricky due to the spend time waiting for other services' responses (e.g.  database query). We are interested only in resources (CPU, RAM, and I/O) which are actively involved in processing. So, in terms of CPU, we are interested in CPU time spent on processing, not waiting, because a service typically is able to process other requests while waiting for responses from other servers (though this is only typical, as maintaining waiting connections also has costs).

Another important note, λ and μ are averages - in reality, both rates fluctuate. λ varies with user activity patterns, while μ changes due to factors like request complexity and system processes (such as garbage collection and background tasks). Applying queueing theory, each incoming request joins a queue before processing, waits some time in the queue depending on resource occupation, and then proceeds to processing.

And the last term for today is system utilization ρ (rho) which can be calculated as `ρ = λ/μ`. This ratio tells us what fraction of our service's capacity we're using. For example, if λ = 50 requests/minute and μ = 100 requests/minute, then ρ = 0.5, meaning we're using 50% of our capacity.

To formally analyze this system using queueing theory - whether we want to calculate average incoming queue length or understand how long requests spend in our system (queuing + processing) - we need λ and μ to follow specific statistical patterns. Specifically, λ (incoming requests) should follow a Poisson distribution, μ (service rate) should follow an exponential distribution. If these conditions aren't met, we can't apply the formulas from queueing theory — we'd need to fall back to simulation instead. Luckily, many real-world services naturally fit these patterns, or at least come close enough to use this math as a reference point. Think of Poisson distribution like this: requests come independently of each other, and we can predict their average rate, but can't predict exact arrival times. And exponential distribution means most requests are processed quickly, with a long tail of slower ones - pretty typical for web services.

Let's get back to practical matters. As software engineers, we care a lot about SLOs (Service Level Objectives) and SLIs (Service Level Indicators). One of the most common SLOs is request latency, which has two major components (ignoring network of course). The first one is processing time - how long the request spends being processed. The second one is queue time - how long it waits in line before processing starts. The longer our queue, the longer each request waits, driving up overall latency. Queueing theory gives us a brilliant formula to calculate the average incoming queue length for a single instance: `(ρ*ρ)/(1-ρ)`. The graphical representation of it is below: 

<div class="chart">
    <canvas id="mm1-avg-queue-chart"></canvas>
</div>

Looking at the graph, we can see why that 80% threshold is critical. The queue length starts growing very fast around 70-80% utilization. Let's put some numbers to this:

* At 70% utilization: average queue length is 1.6 requests
* At 80% utilization: 3.2 requests
* At 90% utilization: whopping 8.1 requests!

This explosive growth explains why high utilization kills our latency so quickly. Each request in the queue is a delayed response to our users.

But that's not the whole story, in clustered environments, we rarely run just one instance. Ideally, traffic gets distributed evenly across replicas (though in reality, it's not that simple). Queueing theory helps us here too - for multiple servers, the average queue length equals `Erlang-C * ρ/(1-ρ)`. [`Erlang-C`](https://en.wikipedia.org/wiki/Erlang_(unit)#Erlang_C_formula) is one of the most famous formulas in queueing theory. It's quite complex, so instead of writing it out, I'll show you a graph that tells the story better:

<div class="chart">
    <canvas id="mmc-avg-queue-chart"></canvas>
</div>

The graph reveals something interesting: the more instances we have, the further right our "rapid growth" point moves. In other words, with more instances, we can sustain higher utilization before things go crazy. This doesn't necessarily mean we should wait longer to scale - but it does mean that systems with more instances tend to be more stable at a given utilization level.

So that's the math behind the "magic 80% rule". The takeaway is simple: don't push your services past 80% utilization, and start scaling earlier if you can. This isn't just some arbitrary number - it's backed by queueing theory and tested in production environments.

<script src="https://cdn.mathjax.org/mathjax/latest/MathJax.js?config=TeX-AMS-MML_HTMLorMML" type="text/javascript"></script>
<script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
<script>
    function factorial(n) {
        if (n === 0 || n === 1)
            return 1;
        
        let result = 1;
        for(let i = 2; i <= n; i++)
            result *= i;

        return result;
    }

    function erlangC(k, p) {
        const kp = k * p;
        const numerator = Math.pow(kp, k) / (factorial(k) * (1 - p));
        
        let sum = 0;
        for(let i = 0; i <= k-1; i++) {
            sum += Math.pow(kp, i) / factorial(i);
        }
        sum += Math.pow(kp, k) / (factorial(k) * (1 - p));
        
        return numerator / sum;
    }

    function calcQueueLen(k, p) {
        const pb = erlangC(k, p);
        return pb * (p / (1 - p));
    }

    function getChartQueueLenOptions() {
        const textColor = getComputedStyle(document.getElementsByClassName('chart')[0]).getPropertyValue('color');
        return {
            responsive: true,
            maintainAspectRatio: true,
            plugins: {
                legend: {
                    display: false
                },
                title: {
                    display: true,
                    text: 'Average Incoming Queue Length vs Utilization',
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
                        text: 'Utilization (%)',
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
                        text: 'Average Incoming Queue Length',
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
    }

    function drawMM1QueueLenChart() {
        const data = [];
        for (let x = 0; x <= .95; x += 0.01) {
            const y = calcQueueLen(1, x);
            if (y > 10)
                break;
            data.push({x: x * 100, y: y});
        }

        const ctx = document.getElementById('mm1-avg-queue-chart');
        new Chart(ctx, {
            type: 'line',
            data: {
                datasets: [{
                    data: [
                        {x: 50, y: calcQueueLen(1, 0.5).toFixed(2)},
                        {x: 60, y: calcQueueLen(1, 0.6).toFixed(2)},
                        {x: 70, y: calcQueueLen(1, 0.7).toFixed(2)},
                        {x: 80, y: calcQueueLen(1, 0.8).toFixed(2)},
                        {x: 90, y: calcQueueLen(1, 0.9).toFixed(2)}
                    ],
                    pointBackgroundColor: 'green',
                    pointBorderColor: 'green',
                    pointRadius: 10,
                    showLine: false,
                    pointHoverRadius: 10
                }, {
                    data: data,
                    borderColor: 'lime',
                    borderWidth: 7,
                    pointRadius: 0,
                    fill: false
                }]
            },
            options: getChartQueueLenOptions()
        });
    }

    function drawMMCQueueLenChart() {
        const datasets = [];
        [{k: 1, color: '#00ff00'},
         {k: 3, color: '#00ffff'},
         {k: 5, color: '#ff1493'},
         {k: 10, color: '#ffff00'},
         {k: 20, color: '#ff6600'},
         {k: 30, color: '#9933ff'}].forEach(item => {
            const data = []
            for (let x = 0; x <= .95; x += 0.01) {
                const y = calcQueueLen(item.k, x);
                if (y > 10)
                    break;
                data.push({x: x * 100, y: y});
            }
            datasets.push({
                data: data,
                borderColor: item.color,
                borderWidth: 2,
                pointRadius: 0,
                fill: false,
                label: `${item.k} Instances`
            });
        });

        const ctx = document.getElementById('mmc-avg-queue-chart');
        new Chart(ctx, {
            type: 'line',
            data: {
                datasets: datasets
            },
            options: getChartQueueLenOptions()
        });
    }

    drawMM1QueueLenChart();
    drawMMCQueueLenChart();

    window.onbeforeprint = () => {
        drawMM1QueueLenChart();
        drawMMCQueueLenChart();
    }
</script>

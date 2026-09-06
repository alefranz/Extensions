// WantsACracker differential compatibility harness (preview-path step 5; see smoke/README.md).
//
// Runs the full independently authored P0 HTTP scenario set — all 24 behavioural facts of
// the standard-handler surface — against BOTH sides of the source-level compatibility
// claim, at the shared public seam: a named HttpClient wired with AddStandardResilienceHandler().
//
// This single source file encodes BOTH sides: every line that legitimately differs between the
// two package sets (genuine surface differences) appears as a paired marker block, where the
// WantsACracker line is the active line in the checked-in file (marked with a trailing
// "WAC marker" comment) and the 8.4.2 counterpart is carried as a "POLLY marker" comment line
// with the 8.4.2-side code. The exact marker spelling is the one smoke/run-differential.sh
// matches on; the markers are not used anywhere else in this file.
// smoke/run-differential.sh builds:
//
//   * the WantsACracker side — exactly as checked in, package-referencing the three
//     WantsACracker 0.1.0-preview.1 packages (smoke/differential/wantsacracker.csproj);
//   * the Polly 8.4.2 side — the same file transformed mechanically: every active line with a
//     WAC marker is removed and every POLLY marker line is uncommented in place
//     (smoke/differential/polly.csproj references Microsoft.Extensions.Http.Resilience 10.9.0).
//
// The request sequences and the observable expectations are byte-identical for both sides;
// only the marked configuration lines differ, each one recording a genuine surface difference
// between the 8.4.2 reference model and the 0.1.0-preview.1 surface (documented in
// smoke/README.md).
//
// Each scenario runs against a fresh in-process loopback server (an HttpListener, or a
// raw-TCP server for the two connection-abort scenarios — see ScenarioServer) and a fresh
// ServiceCollection (fully offline; no external server). The program prints one line per
// scenario:
//
//   <scenario>: <observation>[,<observation>...] (server-attempts=<n>)
//
// where an observation is "response:<status>" or "exception:<ExceptionType>" or a
// scenario-specific token (for example "honoured-retry-after:yes"), and <n> is the number
// of requests the server actually received. The program always exits 0 after all scenarios
// have run; the pass/fail judgement (per-side expected outcomes, known documented
// differences, and the final verdict) is the script's job.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.RateLimiting;
using System.Threading.Tasks;
using Microsoft.Extensions.DependencyInjection;

// Surface difference: the options type namespace. The reference package (10.9.0, which
// carries Polly 8.4.2) exposes Microsoft.Extensions.Http.Resilience.HttpStandardResilienceOptions;
// the preview exposes WantsACracker.Extensions.Http.Resilience.HttpStandardResilienceOptions
// (same type name, different package).
using StandardResilienceOptions = WantsACracker.Extensions.Http.Resilience.HttpStandardResilienceOptions; // @@WAC@@
//@@POLLY@@ using StandardResilienceOptions = Microsoft.Extensions.Http.Resilience.HttpStandardResilienceOptions;

// --- Retry facts -------------------------------------------------------------

await RunAsync(
    "retry-503-then-success",
    options =>
    {
        // Identical on both sides: the retry option names match 8.4.2.
        options.Retry.MaxRetryAttempts = 3;
        options.Retry.Delay = TimeSpan.FromMilliseconds(50);
        options.Retry.MaxDelay = TimeSpan.FromMilliseconds(50);
    },
    (client, _) => SendOnceAsync(client),
    attempt => attempt == 1 ? Respond(503, body: "busy") : Respond(200));

await RunAsync(
    "retry-408-then-success",
    options =>
    {
        // Identical on both sides (same retry configuration as the first scenario).
        options.Retry.MaxRetryAttempts = 3;
        options.Retry.Delay = TimeSpan.FromMilliseconds(50);
        options.Retry.MaxDelay = TimeSpan.FromMilliseconds(50);
    },
    (client, _) => SendOnceAsync(client),
    attempt => attempt == 1 ? Respond(408, body: "busy") : Respond(200));

await RunAsync(
    "retry-429-retry-after",
    options =>
    {
        // Identical on both sides. The base backoff is deliberately small and MaxDelay is
        // left at each side's default (null on the preview, 30 s on the 8.4.2 reference),
        // so an observed wait of ~1 s can only come from the Retry-After header — the
        // honoured-retry-after token proves the header is honoured.
        options.Retry.MaxRetryAttempts = 3;
        options.Retry.Delay = TimeSpan.FromMilliseconds(50);
    },
    async (client, _) =>
    {
        var stopwatch = Stopwatch.StartNew();
        try
        {
            using HttpResponseMessage response = await client.GetAsync("/", CancellationToken.None);
            stopwatch.Stop();
            string honoured = stopwatch.Elapsed >= TimeSpan.FromMilliseconds(800)
                ? "honoured-retry-after:yes"
                : "honoured-retry-after:no";
            return new[] { "response:" + (int)response.StatusCode, honoured };
        }
        catch (Exception e)
        {
            return new[] { "exception:" + e.GetType().Name };
        }
    },
    attempt => attempt == 1 ? Respond(429, body: "slow down", retryAfterSeconds: 1) : Respond(200));

await RunAsync(
    "retry-connection-abort-then-success",
    options =>
    {
        // Identical on both sides (same retry configuration as the first scenario).
        // Socket-seam variant of the "transient connection failure is retried" fact: at
        // this seam the failure a client actually observes is a connection abort (an
        // HttpRequestException carrying an IOException/SocketException inner), not a bare
        // HttpRequestException (see the limitations in smoke/README.md). The scenario runs
        // on the raw-TCP transport: the first attempt's connection is closed without being
        // read or answered, which is what the client observes as the abort. The recovery
        // (server-attempts=2) is the transport's own transparent connection retry, not a
        // resilience retry, so the resilience layer observes a single success.
        options.Retry.MaxRetryAttempts = 3;
        options.Retry.Delay = TimeSpan.FromMilliseconds(50);
        options.Retry.MaxDelay = TimeSpan.FromMilliseconds(50);
    },
    (client, _) => SendOnceAsync(client),
    attempt => attempt == 1 ? Respond(503, abort: true) : Respond(200),
    rawTcp: true);

await RunAsync(
    "no-retry-404",
    options =>
    {
        // Identical on both sides (same retry configuration as the first scenario):
        // 404 (unlike 408 and 429) is not transient and must not be retried.
        options.Retry.MaxRetryAttempts = 3;
        options.Retry.Delay = TimeSpan.FromMilliseconds(50);
        options.Retry.MaxDelay = TimeSpan.FromMilliseconds(50);
    },
    (client, _) => SendOnceAsync(client),
    attempt => Respond(404, body: "missing"));

await RunAsync(
    "retry-exhaustion-last-response",
    options =>
    {
        // Identical on both sides: the retry budget (2) is exhausted and the LAST
        // response (the 503) must surface — never a fabricated one.
        options.Retry.MaxRetryAttempts = 2;
        options.Retry.Delay = TimeSpan.FromMilliseconds(50);
        options.Retry.MaxDelay = TimeSpan.FromMilliseconds(50);
    },
    (client, _) => SendOnceAsync(client),
    attempt => Respond(503, body: "busy"));

await RunAsync(
    "retry-exhaustion-last-error",
    options =>
    {
        // Identical on both sides (same budget as the previous scenario): when the
        // pipeline's last attempt fails with an exception rather than a response, the
        // caller observes the error itself — never a fabricated response with a body.
        // Raw-TCP transport: every attempt's connection is aborted (closed without being
        // read or answered), so the last attempt fails with the connection error. The
        // expected server count is 12, not 3: each of the 3 resilience attempts is a
        // replayable GET, and SocketsHttpHandler transparently retries an aborted
        // connection on up to 3 further connections before surfacing the failure —
        // 4 accepted connections per attempt (a non-replayable POST control opens
        // exactly 1), so 3 attempts x 4 connections = 12.
        options.Retry.MaxRetryAttempts = 2;
        options.Retry.Delay = TimeSpan.FromMilliseconds(50);
        options.Retry.MaxDelay = TimeSpan.FromMilliseconds(50);
    },
    async (client, _) =>
    {
        try
        {
            return await SendOnceAsync(client);
        }
        catch (Exception e)
        {
            return new[] { "exception:" + e.GetType().Name };
        }
    },
    attempt => Respond(503, abort: true),
    rawTcp: true);

await RunAsync(
    "retry-cancellation-during-backoff",
    options =>
    {
        // Identical on both sides: the backoff (30 s) far exceeds the caller's patience
        // (300 ms): the delay must be cancellation-aware and no second attempt may start.
        // MaxDelay is left at each side's default (null on the preview, 30 s on the 8.4.2
        // reference), so the first backoff is 30 s on both sides.
        options.Retry.MaxRetryAttempts = 3;
        options.Retry.Delay = TimeSpan.FromSeconds(30);
    },
    async (client, _) =>
    {
        using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(300));
        try
        {
            using HttpResponseMessage response = await client.SendAsync(new HttpRequestMessage(HttpMethod.Get, "/"), cts.Token);
            return new[] { "response:" + (int)response.StatusCode };
        }
        catch (Exception e)
        {
            return new[] { "exception:" + e.GetType().Name };
        }
    },
    attempt => attempt == 1 ? Respond(503, body: "busy") : Respond(200));

// --- Timeout facts -----------------------------------------------------------

await RunAsync(
    "attempt-timeout-then-retry",
    options =>
    {
        // Identical on both sides: the per-attempt timeout. The 10.9.0 reference exposes
        // AttemptTimeout.Timeout (a Polly.Timeout.TimeoutStrategyOptions member); the
        // preview mirrors that name. (The 8.4.0/8.5.0 line of the reference package uses
        // Timeout.AttemptTimeoutDuration instead — see smoke/README.md.)
        options.AttemptTimeout.Timeout = TimeSpan.FromMilliseconds(400);
        options.Retry.MaxRetryAttempts = 3;
        options.Retry.Delay = TimeSpan.FromMilliseconds(50);
        options.Retry.MaxDelay = TimeSpan.FromMilliseconds(50);
    },
    (client, _) => SendOnceAsync(client),
    attempt => attempt == 1 ? Respond(503, delayMs: 1500, body: "slow") : Respond(200));

await RunAsync(
    "attempt-timeout-rejects",
    options =>
    {
        // Identical on both sides: the per-attempt timeout (200 ms) always fires (the
        // server takes 5 s), and the timeout rejection itself is transient, so it is
        // retried once and then surfaces as the dedicated resilience timeout exception —
        // not a cancellation, not a plain timeout. (The core fact uses
        // MaxRetryAttempts = 0; the 8.4.2 reference's options validation rejects 0 — a
        // documented validation divergence, the preview allows it — so the seam uses 1,
        // the lowest value both sides accept.)
        options.AttemptTimeout.Timeout = TimeSpan.FromMilliseconds(200);
        options.Retry.MaxRetryAttempts = 1;
        options.Retry.Delay = TimeSpan.FromMilliseconds(50);
        options.Retry.MaxDelay = TimeSpan.FromMilliseconds(50);
    },
    async (client, _) =>
    {
        try
        {
            return await SendOnceAsync(client);
        }
        catch (Exception e)
        {
            return new[] { "exception:" + e.GetType().Name };
        }
    },
    attempt => Respond(200, delayMs: 5000, body: "slow"));

await RunAsync(
    "total-timeout-fails",
    options =>
    {
        // Identical on both sides: the total-request timeout and the per-attempt timeout
        // (same property names as the 10.9.0 reference). Both sides validate that the
        // total timeout exceeds the attempt timeout, so the attempt timeout is set
        // (900 ms, above the server's 700 ms delay so only the total timeout can fire).
        options.TotalRequestTimeout.Timeout = TimeSpan.FromMilliseconds(1200);
        options.AttemptTimeout.Timeout = TimeSpan.FromMilliseconds(900);
        options.Retry.MaxRetryAttempts = 3;
        options.Retry.Delay = TimeSpan.FromMilliseconds(50);
        options.Retry.MaxDelay = TimeSpan.FromMilliseconds(50);
    },
    async (client, _) =>
    {
        try
        {
            return await SendOnceAsync(client);
        }
        catch (Exception e)
        {
            return new[] { "exception:" + e.GetType().Name };
        }
    },
    attempt => Respond(503, delayMs: 700, body: "busy"));

await RunAsync(
    "total-timeout-dominates-client-timeout",
    options =>
    {
        // Identical on both sides: the total-request timeout (1.2 s) cuts off a retry
        // storm (50 allowed attempts) long before the client's own timeout could. The
        // registration sets HttpClient.Timeout to infinite on both sides, so the
        // resilience total timeout is the only timeout in force — this scenario must not
        // override client.Timeout after creation, and the client-timeout token records
        // that it is infinite. The per-attempt timeout (200 ms) stays above the server's
        // 100 ms delay, so only the total timeout can fire. The exact attempt count
        // varies with the exponential-backoff jitter, so the script expects a band
        // (server-attempts:4-6) that both sides must fall in.
        options.TotalRequestTimeout.Timeout = TimeSpan.FromMilliseconds(1200);
        options.AttemptTimeout.Timeout = TimeSpan.FromMilliseconds(200);
        options.Retry.MaxRetryAttempts = 50;
        options.Retry.Delay = TimeSpan.FromMilliseconds(40);
    },
    async (client, _) =>
    {
        string timeout = client.Timeout == Timeout.InfiniteTimeSpan
            ? "client-timeout:infinite"
            : "client-timeout:finite";
        try
        {
            using HttpResponseMessage response = await client.GetAsync("/", CancellationToken.None);
            return new[] { "response:" + (int)response.StatusCode, timeout };
        }
        catch (Exception e)
        {
            string dominated = e.GetType().Name == "TimeoutRejectedException"
                ? "total-timeout-dominated:yes"
                : "total-timeout-dominated:no";
            return new[] { "exception:" + e.GetType().Name, timeout, dominated };
        }
    },
    attempt => Respond(500, delayMs: 100, body: "busy"));

await RunAsync(
    "caller-cancellation-not-timeout",
    options =>
    {
        // Identical on both sides: a very generous attempt timeout (30 s) and an
        // explicit total timeout (60 s — the default total is 30 s, which the reference's
        // validation rejects as equal to the attempt timeout) guarantee it is the caller's
        // cancellation, not any resilience timeout, that ends the request — the surfaced
        // exception must not be the dedicated resilience timeout exception. (The core
        // fact uses MaxRetryAttempts = 0; the reference's options validation rejects 0,
        // so the seam uses 1, the lowest value both sides accept.) The breaker sampling
        // window (30 s on both sides by default) must be at least double the attempt
        // timeout for both sides' options validation, so it is widened to 60 s.
        options.TotalRequestTimeout.Timeout = TimeSpan.FromSeconds(60);
        options.AttemptTimeout.Timeout = TimeSpan.FromSeconds(30);
        options.CircuitBreaker.SamplingDuration = TimeSpan.FromSeconds(60);
        options.Retry.MaxRetryAttempts = 1;
    },
    async (client, _) =>
    {
        using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(200));
        try
        {
            using HttpResponseMessage response = await client.SendAsync(new HttpRequestMessage(HttpMethod.Get, "/"), cts.Token);
            return new[] { "response:" + (int)response.StatusCode };
        }
        catch (Exception e)
        {
            return new[] { "exception:" + e.GetType().Name };
        }
    },
    attempt => Respond(200, delayMs: 30000, body: "slow"));

// --- Circuit-breaker facts ---------------------------------------------------

await RunAsync(
    "circuit-breaker-opens",
    options =>
    {
        // Identical on both sides: the circuit-breaker options share the same names (the
        // preview mirrors the 8.4.2 surface — FailureRatio / MinimumThroughput /
        // SamplingDuration / BreakDuration; the older FailureThreshold-style names do not
        // exist in 8.4.2). The configuration is calibrated to the same behaviour on both
        // sides: the breaker opens after 2 failed executions and stays open for the whole
        // scenario. Both sides also validate that the sampling window is at least double the
        // attempt timeout, so the attempt timeout is set (1 s, far below the 10 s sampling
        // window). Retry is 1 on both sides: the reference's options validation rejects 0 (a
        // documented validation divergence — the preview allows it), so 1 is the lowest
        // value both sides accept. The proven result is a MATCH: the breaker-open rejection
        // is BrokenCircuitException on both sides (Polly.Core's name —
        // CircuitBreakerOpenException is the legacy Polly v7 name and does not exist on
        // the 8.4.2 surface; the earlier assumption of a difference here is superseded,
        // see smoke/README.md).
        options.CircuitBreaker.FailureRatio = 1.0;
        options.CircuitBreaker.MinimumThroughput = 2;
        options.CircuitBreaker.SamplingDuration = TimeSpan.FromSeconds(10);
        options.CircuitBreaker.BreakDuration = TimeSpan.FromSeconds(10);
        options.AttemptTimeout.Timeout = TimeSpan.FromSeconds(1);
        options.Retry.MaxRetryAttempts = 1;
    },
    (client, _) => MultiSendAsync(client, 5, 150),
    attempt => Respond(503, body: "busy"));

await RunAsync(
    "circuit-breaker-fails-fast",
    options =>
    {
        // Identical on both sides: five executions cross the 5 / 0.5 threshold. With
        // retry = 1 each send makes two failed attempts, so the breaker opens on the third
        // send's first attempt (the fifth failure); its retry and the three following
        // sends fail fast without reaching the server. The 10 s break duration keeps it
        // open for the whole scenario.
        ConfigureBreaker(options, TimeSpan.FromSeconds(10));
    },
    (client, _) => MultiSendAsync(client, 6, 150),
    attempt => Respond(503, body: "busy"));

var failing = true;
await RunAsync(
    "circuit-breaker-half-open-recovery",
    options =>
    {
        // Identical on both sides: the breaker opens on the third send's first attempt
        // (the fifth failure) and the fourth send fails fast while open. After the 1 s
        // break duration elapses the breaker is half-open and admits a probe; with the
        // server fixed, the probe succeeds and the circuit recovers.
        ConfigureBreaker(options, TimeSpan.FromSeconds(1));
    },
    async (client, _) =>
    {
        var observations = new List<string>();
        for (int i = 0; i < 4; i++)
        {
            observations.Add(await OneShotAsync(client));
            await Task.Delay(150);
        }

        await Task.Delay(1200); // break duration elapsed -> half-open
        failing = false;

        observations.Add(await OneShotAsync(client)); // the probe
        return observations.ToArray();
    },
    attempt => failing ? Respond(503, body: "busy") : Respond(200));

var stillFailing = true;
await RunAsync(
    "circuit-breaker-successful-probe-closes",
    options =>
    {
        // Identical on both sides: the breaker opens on the third send's first attempt
        // (the fifth failure); sends four and five fail fast while open. After the break
        // duration elapses the half-open breaker admits a probe; with the server fixed the
        // probe succeeds and the circuit closes — the burst of six further requests must
        // all reach the server (a still half-open circuit would admit only the probe).
        ConfigureBreaker(options, TimeSpan.FromSeconds(1));
    },
    async (client, _) =>
    {
        var observations = new List<string>();
        for (int i = 0; i < 5; i++)
        {
            observations.Add(await OneShotAsync(client));
            await Task.Delay(150);
        }

        await Task.Delay(1200); // break duration elapsed -> half-open
        stillFailing = false;

        observations.Add(await OneShotAsync(client)); // the probe; a success closes the circuit
        for (int i = 0; i < 6; i++)
        {
            observations.Add(await OneShotAsync(client)); // a closed circuit admits the burst
        }

        return observations.ToArray();
    },
    attempt => stillFailing ? Respond(503, body: "busy") : Respond(200));

await RunAsync(
    "circuit-breaker-below-ratio-stays-closed",
    options =>
    {
        // Identical on both sides: two failed attempts (the first send's attempt and its
        // retry) out of the seven total executions (0.29) stay below the 0.5 ratio: the
        // circuit must never open, and every send after the first reaches the server.
        ConfigureBreaker(options, TimeSpan.FromSeconds(10));
    },
    (client, _) => MultiSendAsync(client, 6, 150),
    attempt => attempt <= 2 ? Respond(503, body: "busy") : Respond(200));

// --- Rate-limiter facts ------------------------------------------------------

await RunAsync(
    "rate-limiter-queues-beyond-limit",
    options =>
    {
        // Identical on both sides: one permit and a large queue — the second request
        // waits for the first permit instead of failing. The rate-limiter options carry
        // the same names on both sides, and DefaultRateLimiterOptions is the BCL
        // ConcurrencyLimiterOptions on both sides.
        options.RateLimiter.DefaultRateLimiterOptions = new ConcurrencyLimiterOptions
        {
            PermitLimit = 1,
            QueueLimit = 1000,
        };
    },
    async (client, _) =>
    {
        var tasks = new[]
        {
            client.SendAsync(new HttpRequestMessage(HttpMethod.Get, "/"), CancellationToken.None),
            client.SendAsync(new HttpRequestMessage(HttpMethod.Get, "/"), CancellationToken.None),
        };
        var responses = await Task.WhenAll(tasks);
        var observations = new string[responses.Length];
        for (int i = 0; i < responses.Length; i++)
        {
            using HttpResponseMessage response = responses[i];
            observations[i] = "response:" + (int)response.StatusCode;
        }

        return observations;
    },
    attempt => Respond(200, delayMs: 300, body: "ok"));

await RunAsync(
    "rate-limiter-queue-overload-rejection",
    options =>
    {
        // Identical on both sides: one permit and no queue — while the first request
        // holds the permit, the second is rejected immediately with a cancellation that
        // identifies the full queue, distinct from a plain caller cancellation.
        options.RateLimiter.DefaultRateLimiterOptions = new ConcurrencyLimiterOptions
        {
            PermitLimit = 1,
            QueueLimit = 0,
        };
    },
    async (client, _) =>
    {
        var first = client.SendAsync(new HttpRequestMessage(HttpMethod.Get, "/"), CancellationToken.None);
        await Task.Delay(50); // the first request holds the permit before the second arrives

        string rejection;
        try
        {
            using HttpResponseMessage response = await client.SendAsync(new HttpRequestMessage(HttpMethod.Get, "/"), CancellationToken.None);
            rejection = "response:" + (int)response.StatusCode; // not expected: the queue is full
        }
        catch (Exception e)
        {
            string queueNamed = e is OperationCanceledException oce
                && oce.Message.Contains("queue", StringComparison.OrdinalIgnoreCase)
                ? "queue-rejection:yes"
                : "queue-rejection:no";
            rejection = "exception:" + e.GetType().Name + "," + queueNamed;
        }

        using HttpResponseMessage done = await first;
        return new[] { rejection, "response:" + (int)done.StatusCode };
    },
    attempt => Respond(200, delayMs: 300, body: "ok"));

await RunAsync(
    "rate-limiter-queue-cancellation",
    options =>
    {
        // Identical on both sides: one permit and a queue — the second request waits in
        // the queue, and the caller's own cancellation must surface (with the caller's
        // token), which distinguishes queue cancellation from the overload rejection.
        options.RateLimiter.DefaultRateLimiterOptions = new ConcurrencyLimiterOptions
        {
            PermitLimit = 1,
            QueueLimit = 100,
        };
    },
    async (client, _) =>
    {
        var first = client.SendAsync(new HttpRequestMessage(HttpMethod.Get, "/"), CancellationToken.None);
        await Task.Delay(50); // the first request holds the permit before the second queues

        using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(200));
        string cancellation;
        try
        {
            using HttpResponseMessage response = await client.SendAsync(new HttpRequestMessage(HttpMethod.Get, "/"), cts.Token);
            cancellation = "response:" + (int)response.StatusCode; // not expected: the wait is cancelled
        }
        catch (Exception e)
        {
            string callerToken = e is OperationCanceledException oce && oce.CancellationToken == cts.Token
                ? "caller-token:yes"
                : "caller-token:no";
            cancellation = "exception:" + e.GetType().Name + "," + callerToken;
        }

        using HttpResponseMessage done = await first;
        return new[] { cancellation, "response:" + (int)done.StatusCode };
    },
    attempt => Respond(200, delayMs: 500, body: "ok"));

await RunAsync(
    "rate-limiter-permits-no-leak",
    options =>
    {
        // Identical on both sides: one permit — three failed (400) requests must release
        // their permits as well, so the fourth completes without waiting on a leaked
        // permit (the fast-recovery token records that it did).
        options.RateLimiter.DefaultRateLimiterOptions = new ConcurrencyLimiterOptions
        {
            PermitLimit = 1,
            QueueLimit = 1000,
        };
    },
    async (client, _) =>
    {
        var observations = new List<string>();
        for (int i = 0; i < 3; i++)
        {
            using HttpResponseMessage failed = await client.GetAsync("/", CancellationToken.None);
            observations.Add("response:" + (int)failed.StatusCode);
        }

        var recovered = client.SendAsync(new HttpRequestMessage(HttpMethod.Get, "/"), CancellationToken.None);
        var finished = await Task.WhenAny(recovered, Task.Delay(TimeSpan.FromSeconds(5)));
        if (finished != recovered)
        {
            observations.Add("fast-recovery:no"); // a leaked permit: the 4th request is still waiting
        }
        else
        {
            using HttpResponseMessage done = await recovered;
            observations.Add("response:" + (int)done.StatusCode);
            observations.Add("fast-recovery:yes");
        }

        return observations.ToArray();
    },
    attempt => attempt <= 3 ? Respond(400, body: "bad") : Respond(200));

// --- Request-content replay facts --------------------------------------------

await RunAsync(
    "no-retry-non-replayable",
    options =>
    {
        // Identical on both sides (same retry configuration as the first scenario).
        options.Retry.MaxRetryAttempts = 3;
        options.Retry.Delay = TimeSpan.FromMilliseconds(50);
        options.Retry.MaxDelay = TimeSpan.FromMilliseconds(50);
    },
    async (client, _) =>
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/")
        {
            // A non-seekable stream: the canonical non-replayable request-content shape.
            Content = new StreamContent(new UnseekableStream(new MemoryStream(new byte[] { 1, 2, 3, 4 })))
        };

        try
        {
            using HttpResponseMessage response = await client.SendAsync(request);
            return new[] { "response:" + (int)response.StatusCode };
        }
        catch (Exception e)
        {
            return new[] { "exception:" + e.GetType().Name };
        }
    },
    attempt => Respond(503, body: "busy"));

await RunAsync(
    "replay-bufferable-content",
    options =>
    {
        // Identical on both sides (same retry configuration as the exhaustion scenarios):
        // bufferable content (StringContent) may be replayed — the retry must re-send the
        // identical body, which the server must observe on both attempts (bodies token).
        options.Retry.MaxRetryAttempts = 2;
        options.Retry.Delay = TimeSpan.FromMilliseconds(50);
        options.Retry.MaxDelay = TimeSpan.FromMilliseconds(50);
    },
    async (client, server) =>
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/")
        {
            Content = new StringContent("payload"),
        };

        try
        {
            using HttpResponseMessage response = await client.SendAsync(request);
            var bodies = server.Bodies;
            return new[] { "response:" + (int)response.StatusCode, "bodies:" + string.Join(",", bodies) };
        }
        catch (Exception e)
        {
            return new[] { "exception:" + e.GetType().Name };
        }
    },
    attempt => attempt == 1 ? Respond(503, body: "busy") : Respond(200));

return 0;

// Runs one scenario end to end: a fresh loopback server (an HttpListener, or the raw-TCP
// transport when rawTcp — the two connection-abort scenarios), a fresh ServiceProvider with
// a named HttpClient through AddStandardResilienceHandler(configure), the sends, one result
// line.
static async Task RunAsync(
    string name,
    Action<StandardResilienceOptions> configure,
    Func<HttpClient, ScenarioServer, Task<string[]>> send,
    Func<int, (int Status, int DelayMs, string Body, int RetryAfterSeconds, bool Abort)> respond,
    bool rawTcp = false)
{
    var server = new ScenarioServer(respond, rawTcp);
    server.StartLoop();
    try
    {
        var serviceCollection = new ServiceCollection();
        _ = serviceCollection.AddHttpClient(name).AddStandardResilienceHandler(configure);
        ServiceProvider provider = serviceCollection.BuildServiceProvider();
        using (provider)
        using (HttpClient client = provider.GetRequiredService<IHttpClientFactory>().CreateClient(name))
        {
            client.BaseAddress = new Uri(server.BaseAddress);
            string[] observations = await send(client, server);
            Console.WriteLine($"{name}: {string.Join(",", observations)} (server-attempts={server.Attempts})");
        }
    }
    finally
    {
        // Stop() ends the serving loop; every send has completed by the time it is called,
        // so no background handling outlives the scenario.
        server.Stop();
    }
}

static async Task<string[]> SendOnceAsync(HttpClient client)
{
    using HttpResponseMessage response = await client.GetAsync("/", CancellationToken.None);
    return new[] { "response:" + (int)response.StatusCode };
}

// One send, observed as a single token: "response:<status>" or "exception:<ExceptionType>".
static async Task<string> OneShotAsync(HttpClient client)
{
    try
    {
        return (await SendOnceAsync(client))[0];
    }
    catch (Exception e)
    {
        return "exception:" + e.GetType().Name;
    }
}

// <count> sequential sends with a <pauseMs> ms pause between them (the breaker scenarios
// keep the pauses short enough that a short break duration has not elapsed between sends).
static async Task<string[]> MultiSendAsync(HttpClient client, int count, int pauseMs)
{
    var observations = new string[count];
    for (int i = 0; i < count; i++)
    {
        observations[i] = await OneShotAsync(client);
        if (i < count - 1)
        {
            await Task.Delay(pauseMs);
        }
    }

    return observations;
}

// The shared circuit-breaker calibration (the "circuit-breaker-opens" scenario above
// carries its own, older, calibration). MinimumThroughput = 5 with FailureRatio = 0.5
// means five failures within the 10 s sampling window cross the threshold; the window is
// at least double the 1 s attempt timeout, which both sides' validation requires.
// Retry = 1 is the lowest value both sides accept (the 8.4.2 reference's options
// validation rejects 0 — a documented validation divergence — while the preview allows
// it), and the 50 ms backoff keeps the scenarios fast. Identical on both sides: the
// option names match the 8.4.2 surface.
static void ConfigureBreaker(StandardResilienceOptions options, TimeSpan breakDuration)
{
    options.CircuitBreaker.FailureRatio = 0.5;
    options.CircuitBreaker.MinimumThroughput = 5;
    options.CircuitBreaker.SamplingDuration = TimeSpan.FromSeconds(10);
    options.CircuitBreaker.BreakDuration = breakDuration;
    options.AttemptTimeout.Timeout = TimeSpan.FromSeconds(1);
    options.Retry.MaxRetryAttempts = 1;
    options.Retry.Delay = TimeSpan.FromMilliseconds(50);
    options.Retry.MaxDelay = TimeSpan.FromMilliseconds(50);
}

// The respond tuple for the loopback server: the status to answer with, the delay before
// answering (ms), the body, an optional Retry-After header value (whole seconds), and the
// abort flag (terminate the connection without responding — the connection-failure shape;
// on the raw-TCP transport the connection is closed without being read or answered).
static (int Status, int DelayMs, string Body, int RetryAfterSeconds, bool Abort) Respond(
    int status, int delayMs = 0, string body = "ok", int retryAfterSeconds = 0, bool abort = false)
    => (status, delayMs, body, retryAfterSeconds, abort);

// A small in-process loopback server. The respond callback is invoked with the 1-based attempt
// number and returns (status, delay-before-responding-ms, body, Retry-After-seconds, abort).
// Two transports: the default HttpListener, and a raw-TCP mode (rawTcp) for the
// connection-abort scenarios, where an aborted attempt closes the connection without reading
// the request or answering. All write failures are swallowed: a resilience strategy may
// cancel or abandon the underlying connection.
sealed class ScenarioServer
{
    private readonly HttpListener? _listener;
    private readonly TcpListener? _tcpListener;
    private readonly bool _rawTcp;
    private readonly Func<int, (int Status, int DelayMs, string Body, int RetryAfterSeconds, bool Abort)> _respond;
    private readonly string _prefix;
    private readonly List<string> _bodies = new();
    private readonly object _gate = new();
    private int _attempts;

    public ScenarioServer(
        Func<int, (int Status, int DelayMs, string Body, int RetryAfterSeconds, bool Abort)> respond,
        bool rawTcp = false)
    {
        _respond = respond;
        _rawTcp = rawTcp;
        int port = GetFreePort();
        _prefix = $"http://127.0.0.1:{port}/";
        if (rawTcp)
        {
            _tcpListener = new TcpListener(IPAddress.Loopback, port);
            _tcpListener.Start();
        }
        else
        {
            _listener = new HttpListener();
            _listener.Prefixes.Add(_prefix);
            _listener.Start();
        }
    }

    public string BaseAddress => _prefix;

    public int Attempts => Volatile.Read(ref _attempts);

    // Request bodies observed per attempt (non-empty only), in arrival order.
    public string[] Bodies
    {
        get
        {
            lock (_gate)
            {
                return _bodies.ToArray();
            }
        }
    }

    public void StartLoop()
    {
        if (_rawTcp)
        {
            _ = Task.Run(RawLoopAsync);
        }
        else
        {
            _ = Task.Run(LoopAsync);
        }
    }

    public void Stop()
    {
        if (_rawTcp)
        {
            _tcpListener!.Stop();
        }
        else
        {
            _listener!.Stop();
        }
    }

    private async Task LoopAsync()
    {
        var listener = _listener!;
        while (listener.IsListening)
        {
            HttpListenerContext context;
            try
            {
                context = await listener.GetContextAsync();
            }
            catch (Exception)
            {
                // The listener was stopped; end the serving loop.
                break;
            }

            // Handle each request on its own task so a slow (delayed) response cannot queue
            // up the next request — a resilience strategy's retry arrives while the previous
            // attempt is still being answered.
            _ = Task.Run(() => HandleAsync(context));
        }
    }

    private Task HandleAsync(HttpListenerContext context)
    {
        try
        {
            int attempt = Interlocked.Increment(ref _attempts);

            // Capture the request body (draining it fully) so non-replayable content is
            // fully consumed per attempt and replay behaviour can be observed.
            string requestBody = string.Empty;
            try
            {
                using var reader = new StreamReader(context.Request.InputStream, Encoding.UTF8, detectEncodingFromByteOrderMarks: false, bufferSize: 4096, leaveOpen: true);
                requestBody = reader.ReadToEnd();
            }
            catch (Exception)
            {
            }

            if (requestBody.Length > 0)
            {
                lock (_gate)
                {
                    _bodies.Add(requestBody);
                }
            }

            (int status, int delayMs, string body, int retryAfterSeconds, bool abort) = _respond(attempt);
            if (delayMs > 0)
            {
                Thread.Sleep(delayMs);
            }

            if (abort)
            {
                // Terminate the connection without responding: the client observes a
                // connection failure (HttpRequestException) for this attempt.
                context.Response.Abort();
                return Task.CompletedTask;
            }

            context.Response.StatusCode = status;
            if (retryAfterSeconds > 0)
            {
                context.Response.AddHeader("Retry-After", retryAfterSeconds.ToString());
            }

            var bytes = Encoding.UTF8.GetBytes(body);
            context.Response.OutputStream.Write(bytes);
            context.Response.Close();
        }
        catch (Exception)
        {
            // The client cancelled or abandoned the attempt; nothing to do.
        }

        return Task.CompletedTask;
    }

    private async Task RawLoopAsync()
    {
        var listener = _tcpListener!;
        while (true)
        {
            TcpClient connection;
            try
            {
                connection = await listener.AcceptTcpClientAsync();
            }
            catch (Exception)
            {
                // The listener was stopped; end the serving loop.
                break;
            }

            // Handle each connection on its own task so a slow (delayed) response cannot
            // queue up the next connection — a resilience strategy's retry arrives while
            // the previous attempt is still being answered.
            _ = Task.Run(() => RawHandleAsync(connection));
        }
    }

    private async Task RawHandleAsync(TcpClient connection)
    {
        using (connection)
        {
            try
            {
                int attempt = Interlocked.Increment(ref _attempts);
                (int status, int delayMs, string body, int retryAfterSeconds, bool abort) = _respond(attempt);
                if (delayMs > 0)
                {
                    await Task.Delay(delayMs);
                }

                if (abort)
                {
                    // Terminate the connection without reading the request or answering: with
                    // the request still in flight, closing the socket resets the connection
                    // and the client observes a connection failure (HttpRequestException) for
                    // this attempt immediately. Leaving the request unread is what makes the
                    // abort reliable — a connection that was fully read first and then closed
                    // is not surfaced by the client until its own timeout (see the
                    // limitations in smoke/README.md).
                    return;
                }

                var stream = new NetworkStream(connection.Client, ownsSocket: false);
                var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: false, bufferSize: 4096, leaveOpen: true);

                // Read the request headers (and the body, when present) so the connection can
                // be answered and replay behaviour can be observed.
                _ = await reader.ReadLineAsync(); // the request line
                var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                string? line;
                while ((line = await reader.ReadLineAsync()) != null && line.Length > 0)
                {
                    int split = line.IndexOf(':');
                    if (split > 0)
                    {
                        headers[line[..split].Trim()] = line[(split + 1)..].Trim();
                    }
                }

                string requestBody = string.Empty;
                if (headers.TryGetValue("Content-Length", out var lengthText) && int.TryParse(lengthText, out int contentLength) && contentLength > 0)
                {
                    var buffer = new byte[contentLength];
                    int read = 0;
                    while (read < contentLength)
                    {
                        int n = await stream.ReadAsync(buffer.AsMemory(read, contentLength - read));
                        if (n <= 0)
                        {
                            break;
                        }

                        read += n;
                    }

                    requestBody = Encoding.UTF8.GetString(buffer, 0, read);
                }

                if (requestBody.Length > 0)
                {
                    lock (_gate)
                    {
                        _bodies.Add(requestBody);
                    }
                }

                var reason = status switch
                {
                    200 => "OK",
                    400 => "Bad Request",
                    404 => "Not Found",
                    408 => "Request Timeout",
                    429 => "Too Many Requests",
                    500 => "Internal Server Error",
                    503 => "Service Unavailable",
                    _ => "OK",
                };
                var response = new StringBuilder()
                    .Append("HTTP/1.1 ")
                    .Append(status)
                    .Append(' ')
                    .Append(reason)
                    .Append("\r\nContent-Length: ")
                    .Append(Encoding.UTF8.GetByteCount(body))
                    .Append("\r\nConnection: close\r\n");
                if (retryAfterSeconds > 0)
                {
                    response.Append("Retry-After: ").Append(retryAfterSeconds).Append("\r\n");
                }

                response.Append("\r\n");
                var bytes = Encoding.UTF8.GetBytes(response.ToString() + body);
                await stream.WriteAsync(bytes);
                await stream.FlushAsync();
            }
            catch (Exception)
            {
                // The client cancelled or abandoned the attempt; nothing to do.
            }
        }
    }

    private static int GetFreePort()
    {
        var probe = new TcpListener(IPAddress.Loopback, 0);
        probe.Start();
        int port = ((IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();
        return port;
    }
}

// A non-seekable stream: the canonical non-replayable request-content shape.
sealed class UnseekableStream : Stream
{
    private readonly Stream _inner;

    public UnseekableStream(Stream inner)
        => _inner = inner;

    public override bool CanRead => _inner.CanRead;

    public override bool CanSeek => false;

    public override bool CanWrite => false;

    public override long Length => _inner.Length;

    public override long Position
    {
        get => throw new NotSupportedException();
        set => throw new NotSupportedException();
    }

    public override void Flush() => _inner.Flush();

    public override int Read(byte[] buffer, int offset, int count) => _inner.Read(buffer, offset, count);

    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();

    public override void SetLength(long value) => throw new NotSupportedException();

    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
}

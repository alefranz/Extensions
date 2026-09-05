// WantsACracker differential compatibility harness (preview-path step 5; see smoke/README.md).
//
// Runs a representative subset of the independently authored P0 HTTP scenarios against BOTH
// sides of the source-level compatibility claim, at the shared public seam: a named HttpClient
// wired with AddStandardResilienceHandler().
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
//     (smoke/differential/polly.csproj references Microsoft.Extensions.Http.Resilience 8.4.2).
//
// The request sequences and the observable expectations are byte-identical for both sides;
// only the marked configuration lines differ, each one recording a genuine surface difference
// between the 8.4.2 reference model and the 0.1.0-preview.1 surface (documented in
// smoke/README.md).
//
// Each scenario runs against a fresh in-process loopback HttpListener and a fresh
// ServiceCollection (fully offline; no external server). The program prints one line per
// scenario:
//
//   <scenario>: <observation>[,<observation>...] (server-attempts=<n>)
//
// where an observation is "response:<status>" or "exception:<ExceptionType>" and
// <n> is the number of requests the server actually received. The program always exits 0
// after all scenarios have run; the pass/fail judgement (per-side expected outcomes, known
// documented differences, and the final verdict) is the script's job.

using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.DependencyInjection;

// Surface difference: the options type namespace. The reference package (10.9.0, which
// carries Polly 8.4.2) exposes Microsoft.Extensions.Http.Resilience.HttpStandardResilienceOptions;
// the preview exposes WantsACracker.Extensions.Http.Resilience.HttpStandardResilienceOptions
// (same type name, different package).
using StandardResilienceOptions = WantsACracker.Extensions.Http.Resilience.HttpStandardResilienceOptions; // @@WAC@@
//@@POLLY@@ using StandardResilienceOptions = Microsoft.Extensions.Http.Resilience.HttpStandardResilienceOptions;

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
    attempt => attempt == 1 ? (Status: 503, DelayMs: 0, Body: "busy") : (Status: 200, DelayMs: 0, Body: "ok"));

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
    attempt => attempt == 1 ? (Status: 503, DelayMs: 1500, Body: "slow") : (Status: 200, DelayMs: 0, Body: "ok"));

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
    attempt => (Status: 503, DelayMs: 700, Body: "busy"));

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
        // value both sides accept. The documented difference this scenario exposes is the
        // rejection exception name once the breaker is open: 8.4.2
        // CircuitBreakerOpenException vs preview BrokenCircuitException.
        options.CircuitBreaker.FailureRatio = 1.0;
        options.CircuitBreaker.MinimumThroughput = 2;
        options.CircuitBreaker.SamplingDuration = TimeSpan.FromSeconds(10);
        options.CircuitBreaker.BreakDuration = TimeSpan.FromSeconds(10);
        options.AttemptTimeout.Timeout = TimeSpan.FromSeconds(1);
        options.Retry.MaxRetryAttempts = 1;
    },
    async (client, _) =>
    {
        var observations = new string[5];
        for (int i = 0; i < observations.Length; i++)
        {
            try
            {
                observations[i] = (await SendOnceAsync(client))[0];
            }
            catch (Exception e)
            {
                observations[i] = "exception:" + e.GetType().Name;
            }

            if (i < observations.Length - 1)
            {
                await Task.Delay(150);
            }
        }

        return observations;
    },
    attempt => (Status: 503, DelayMs: 0, Body: "busy"));

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
    attempt => (Status: 503, DelayMs: 0, Body: "busy"));

return 0;

// Runs one scenario end to end: a fresh loopback server, a fresh ServiceProvider with a named
// HttpClient through AddStandardResilienceHandler(configure), the sends, one result line.
static async Task RunAsync(
    string name,
    Action<StandardResilienceOptions> configure,
    Func<HttpClient, ScenarioServer, Task<string[]>> send,
    Func<int, (int Status, int DelayMs, string Body)> respond)
{
    var server = new ScenarioServer(respond);
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
        // Stop() blocks until pending request handling completes, so no background work
        // outlives the scenario.
        server.Stop();
    }
}

static async Task<string[]> SendOnceAsync(HttpClient client)
{
    using HttpResponseMessage response = await client.GetAsync("/", CancellationToken.None);
    return new[] { "response:" + (int)response.StatusCode };
}

// A small in-process loopback server. The respond callback is invoked with the 1-based attempt
// number and returns (status, delay-before-responding-ms, body). All write failures are
// swallowed: a resilience strategy may cancel or abandon the underlying connection.
sealed class ScenarioServer
{
    private readonly HttpListener _listener;
    private readonly Func<int, (int Status, int DelayMs, string Body)> _respond;
    private readonly string _prefix;
    private int _attempts;

    public ScenarioServer(Func<int, (int Status, int DelayMs, string Body)> respond)
    {
        _respond = respond;
        _listener = new HttpListener();
        _prefix = $"http://127.0.0.1:{GetFreePort()}/";
        _listener.Prefixes.Add(_prefix);
        _listener.Start();
    }

    public string BaseAddress => _prefix;

    public int Attempts => Volatile.Read(ref _attempts);

    public void StartLoop() => _ = Task.Run(LoopAsync);

    public void Stop() => _listener.Stop();

    private async Task LoopAsync()
    {
        while (_listener.IsListening)
        {
            HttpListenerContext context;
            try
            {
                context = await _listener.GetContextAsync();
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

            // Drain the request body so non-replayable content is fully consumed per attempt.
            try
            {
                var discard = new byte[4096];
                while (context.Request.InputStream.Read(discard) > 0)
                {
                }
            }
            catch (Exception)
            {
            }

            (int status, int delayMs, string body) = _respond(attempt);
            if (delayMs > 0)
            {
                Thread.Sleep(delayMs);
            }

            context.Response.StatusCode = status;
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

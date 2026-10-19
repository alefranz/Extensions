// WantsACracker clean-consumer smoke scenario (see smoke/README.md).
//
// A minimal, fully offline consumer of the three 0.1.0-preview.1 packages,
// run on both target runtimes (net8.0 and net10.0 — smoke/run-clean-consumer.sh
// runs the built app for each) against small in-process loopback HttpListener
// endpoints. No network or external server is required.
//
// The scenarios prove the advertised migration with package references only:
//
//   1. named-retry — a named HttpClient wired through the real
//      AddHttpClient("smoke") + AddStandardResilienceHandler() registration
//      path: the first request fails with a transient 503, the standard
//      handler's retry recovers, and the server saw exactly 2 attempts.
//   2. named-cancellation — a slow server; the caller cancels after the server
//      has received the request (gated on the request count; the 200 ms before
//      the cancel is comfortably inside the server's 2 s answer and the 10 s
//      per-attempt timeout). The cancellation is classified as caller
//      cancellation — an OperationCanceledException carrying the caller's own
//      token, never the resilience TimeoutRejectedException — exactly 1 attempt
//      reaches the server (caller cancellation is not retried), and the next
//      request on the same client succeeds normally: the cancelled attempt was
//      cleaned up and the pipeline keeps working.
//   3. typed-retry — a typed client resolved from DI (AddHttpClient<T>()
//      constructs a plain class); it carries the same resilience pipeline,
//      proven by the same observable behaviour: a 503 is retried into a 200
//      with exactly 2 server attempts.
//
// Call-site delta versus the Polly 8.4.2 baseline (the differential harness
// smoke/differential/ is that baseline reference): the standard-handler setup
// is identical to the reference setup except for the declared package and the
// namespace — the reference's Microsoft.Extensions.Http.Resilience 10.9.0
// (which pins Polly 8.4.2) becomes the three WantsACracker 0.1.0-preview.1
// packages, and `using Microsoft.Extensions.Http.Resilience;` becomes
// `using WantsACracker.Extensions.Http.Resilience;` (the options type keeps
// its name, HttpStandardResilienceOptions, in both namespaces). The
// registration calls (AddHttpClient(name) / AddHttpClient<T>() with
// AddStandardResilienceHandler and the same option names), the typed-client
// class, and every request call are unchanged.
//
// The app prints one line per scenario and exits 0 only if every scenario
// passes; otherwise it prints the failing facts and exits 1.

using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.DependencyInjection;
using WantsACracker.Extensions.Http.Resilience;

var failures = new List<string>();

// One named client and one typed client, both wired with the standard
// resilience handler through the real registration path. The configuration
// uses the same option names the 8.4.2 reference exposes (see the call-site
// delta in the header); the 50 ms backoff keeps the scenarios fast without
// changing which attempt succeeds.
var serviceCollection = new ServiceCollection();
_ = serviceCollection.AddHttpClient("smoke").AddStandardResilienceHandler(ConfigureRetry);
_ = serviceCollection.AddHttpClient<SmokeClient>().AddStandardResilienceHandler(ConfigureRetry);
IServiceProvider services = serviceCollection.BuildServiceProvider();
HttpClient named = services.GetRequiredService<IHttpClientFactory>().CreateClient("smoke");
SmokeClient typed = services.GetRequiredService<SmokeClient>();

// --- 1. Named client: 503 -> 200 retry, exactly 2 attempts -------------------
{
    using var server = new LoopbackServer(attempt => attempt == 1
        ? (Status: (int)HttpStatusCode.ServiceUnavailable, DelayMs: 0, Body: "busy")
        : (Status: (int)HttpStatusCode.OK, DelayMs: 0, Body: "ok"));
    server.Start();
    using HttpResponseMessage response = await named.GetAsync(server.Url);
    string body = response.Content is not null ? await response.Content.ReadAsStringAsync() : string.Empty;
    int attempts = server.Requests;
    response.Dispose();
    server.Stop();

    if (response.StatusCode == HttpStatusCode.OK && body == "ok" && attempts == 2)
    {
        Console.WriteLine($"named-retry: response:200 (server-attempts={attempts})");
    }
    else
    {
        failures.Add($"named-retry: expected 200 'ok' with exactly 2 server attempts, got {(int)response.StatusCode} '{body}' with {attempts} attempt(s)");
    }
}

// --- 2. Named client: caller cancellation is classified and cleaned up ------
{
    // A slow first answer (2 s — comfortably longer than the 200 ms before the
    // caller cancels and far inside the 10 s per-attempt timeout); the next
    // answer is immediate.
    using var server = new LoopbackServer(attempt => attempt == 1
        ? (Status: (int)HttpStatusCode.OK, DelayMs: 2000, Body: "ok")
        : (Status: (int)HttpStatusCode.OK, DelayMs: 0, Body: "ok"));
    server.Start();
    using var cts = new CancellationTokenSource();
    Task call = named.SendAsync(new HttpRequestMessage(HttpMethod.Get, server.Url), cts.Token);

    // Liveness gate (a 10 s watchdog that fails instead of hangs): the server
    // has received the request. Not a wall-clock assertion — the behaviour
    // under test (the classification) does not depend on this bound.
    bool received = await WaitUntilAsync(() => server.Requests >= 1, TimeSpan.FromSeconds(10));
    if (!received)
    {
        cts.Cancel();
        server.Stop();
        failures.Add("named-cancellation: the server never saw the request within the liveness gate");
    }
    else
    {
        await Task.Delay(TimeSpan.FromMilliseconds(200)); // comfortably inside the server's 2 s answer
        cts.Cancel();
        Exception? caught = null;
        try
        {
            await call;
        }
        catch (Exception e)
        {
            caught = e;
        }

        bool classified = caught is OperationCanceledException oce && oce.CancellationToken == cts.Token;
        if (classified)
        {
            Console.WriteLine($"named-cancellation: exception:OperationCanceledException,caller-token:yes (server-attempts={server.Requests})");
        }
        else
        {
            failures.Add($"named-cancellation: expected an OperationCanceledException carrying the caller's own token (never the resilience timeout), got {(caught?.GetType().FullName ?? "no exception")}");
        }

        if (server.Requests != 1)
        {
            failures.Add($"named-cancellation: caller cancellation is not retried — expected exactly 1 server attempt, the server saw {server.Requests}");
        }

        // The next request on the same client succeeds normally (the cancelled
        // attempt was cleaned up and the pipeline keeps working).
        if (classified)
        {
            using HttpResponseMessage response = await named.SendAsync(new HttpRequestMessage(HttpMethod.Get, server.Url), CancellationToken.None);
            string body = response.Content is not null ? await response.Content.ReadAsStringAsync() : string.Empty;
            if (response.StatusCode == HttpStatusCode.OK && body == "ok" && server.Requests == 2)
            {
                Console.WriteLine($"named-cancellation-recovery: response:200 (server-attempts={server.Requests})");
            }
            else
            {
                failures.Add($"named-cancellation-recovery: the next request must succeed normally with 200 'ok' (exactly 1 further attempt), got {(int)response.StatusCode} '{body}' with {server.Requests} total attempt(s)");
            }
            response.Dispose();
        }
    }
    server.Stop();
}

// --- 3. Typed client: DI resolution + the same observable retry behaviour ----
{
    using var server = new LoopbackServer(attempt => attempt == 1
        ? (Status: (int)HttpStatusCode.ServiceUnavailable, DelayMs: 0, Body: "busy")
        : (Status: (int)HttpStatusCode.OK, DelayMs: 0, Body: "ok"));
    server.Start();
    using HttpResponseMessage response = await typed.PingAsync(server.Url);
    string body = response.Content is not null ? await response.Content.ReadAsStringAsync() : string.Empty;
    int attempts = server.Requests;
    response.Dispose();
    server.Stop();

    if (response.StatusCode == HttpStatusCode.OK && body == "ok" && attempts == 2)
    {
        Console.WriteLine($"typed-retry: response:200 (server-attempts={attempts})");
    }
    else
    {
        failures.Add($"typed-retry: the DI-resolved typed client must carry the resilience pipeline — expected 200 'ok' with exactly 2 server attempts, got {(int)response.StatusCode} '{body}' with {attempts} attempt(s)");
    }
}

if (failures.Count > 0)
{
    foreach (string failure in failures)
    {
        Console.Error.WriteLine($"consumer: FAILED — {failure}");
    }
    return 1;
}

Console.WriteLine(
    "consumer: OK (named client retried 503 -> 200 with exactly 2 attempts; caller cancellation "
    + "classified with the caller's token, not retried, next request 200; typed client retried "
    + "503 -> 200 with exactly 2 attempts)");
return 0;

// The standard-handler configuration (the same option names the 8.4.2
// reference exposes — see the call-site delta in the header).
static void ConfigureRetry(HttpStandardResilienceOptions options)
{
    options.Retry.MaxRetryAttempts = 1;
    options.Retry.Delay = TimeSpan.FromMilliseconds(50);
    options.Retry.MaxDelay = TimeSpan.FromMilliseconds(50);
}

// Polls <condition> every 10 ms until it is true or <timeout> elapses (a
// liveness bound that fails instead of hangs, not an assertion on the
// behaviour under test).
static async Task<bool> WaitUntilAsync(Func<bool> condition, TimeSpan timeout)
{
    using var cts = new CancellationTokenSource(timeout);
    while (!condition())
    {
        try
        {
            await Task.Delay(10, cts.Token);
        }
        catch (OperationCanceledException)
        {
            return false;
        }
    }
    return true;
}

// The in-process loopback endpoint (the existing fixture's listener style,
// generalized): one HttpListener, a per-attempt response specification, and a
// request count. The serving loop keeps serving through aborted client
// connections (the cancellation scenario) and ends only when the listener
// stops; Stop() waits (with a bounded watchdog) for the serving loop to end,
// so no background work outlives the scenario.
sealed class LoopbackServer : IDisposable
{
    int _requests;
    bool _stopped;
    readonly HttpListener _listener = new();
    readonly Func<int, (int Status, int DelayMs, string Body)> _respond;
    Task? _serving;

    public LoopbackServer(Func<int, (int Status, int DelayMs, string Body)> respond)
    {
        _respond = respond;
        int port = GetFreePort();
        _listener.Prefixes.Add($"http://127.0.0.1:{port}/");
        Url = $"http://127.0.0.1:{port}/";
    }

    public string Url { get; }

    public int Requests => Volatile.Read(ref _requests);

    public void Start()
    {
        _listener.Start();
        _serving = Task.Run(ServeAsync);
    }

    public void Stop()
    {
        if (_stopped)
        {
            return;
        }
        _stopped = true;
        _listener.Stop();
        if (_serving is not null)
        {
            if (!_serving.Wait(TimeSpan.FromSeconds(15)))
            {
                throw new TimeoutException("the loopback serving loop did not end after the listener stopped");
            }
        }
        _listener.Close();
    }

    static int GetFreePort()
    {
        var probe = new TcpListener(IPAddress.Loopback, 0);
        probe.Start();
        int p = ((IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();
        return p;
    }

    public void Dispose() => Stop();

    async Task ServeAsync()
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
                // An aborted client connection (the cancellation scenario), or
                // the listener was stopped. Keep serving while the listener is
                // up; the loop condition ends it after Stop().
                await Task.Delay(10);
                continue;
            }

            try
            {
                int attempt = Interlocked.Increment(ref _requests);
                (int status, int delayMs, string body) = _respond(attempt);
                if (delayMs > 0)
                {
                    await Task.Delay(delayMs);
                }
                context.Response.StatusCode = status;
                byte[] bytes = Encoding.UTF8.GetBytes(body);
                await context.Response.OutputStream.WriteAsync(bytes);
                context.Response.Close();
            }
            catch (Exception)
            {
                // The client went away while the answer was being prepared (the
                // cancellation scenario) — the request count already records
                // that the attempt reached the server.
            }
        }
    }
}

// The typed client: a plain class constructed by AddHttpClient<T>() through
// DI; its only knowledge is the standard HttpClient it is handed.
sealed class SmokeClient
{
    readonly HttpClient _client;

    public SmokeClient(HttpClient client)
    {
        _client = client;
    }

    public Task<HttpResponseMessage> PingAsync(string url, CancellationToken cancellationToken = default)
        => _client.GetAsync(url, cancellationToken);
}

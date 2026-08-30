// A minimal, fully offline sample for WantsACracker.Extensions.Http.Resilience:
// a named HttpClient wired with the standard resilience handler (the canonical
// usage pattern for the package), exercised against a small in-process
// HttpListener. The first request fails with a transient 503, which the standard
// handler's retry strategy recovers from; a second request then succeeds on the
// first attempt. No network or external server is required.

using System;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.DependencyInjection;
using WantsACracker.Extensions.Http.Resilience;

// In-process endpoint: a transient 503 on the first request, 200 afterwards.
int requestCount = 0;
int port = GetFreePort();
var listener = new HttpListener();
listener.Prefixes.Add($"http://127.0.0.1:{port}/");
listener.Start();
_ = Task.Run(() => ServeAsync(listener));

// A named HttpClient wired with the standard resilience handler.
var serviceCollection = new ServiceCollection();
_ = serviceCollection.AddHttpClient("sample").AddStandardResilienceHandler();
IServiceProvider services = serviceCollection.BuildServiceProvider();
var client = services.GetRequiredService<IHttpClientFactory>().CreateClient("sample");

// Request 1: the server answers 503; the standard handler retries and recovers.
var firstResponse = await client.GetAsync($"http://127.0.0.1:{port}/", CancellationToken.None);
Console.WriteLine(
    $"request 1: HTTP {(int)firstResponse.StatusCode} {firstResponse.StatusCode} " +
    $"(the server saw {Volatile.Read(ref requestCount)} attempt(s) — the 503 was retried by the standard handler)");

// Request 2: succeeds on the first attempt.
var secondResponse = await client.GetAsync($"http://127.0.0.1:{port}/", CancellationToken.None);
Console.WriteLine(
    $"request 2: HTTP {(int)secondResponse.StatusCode} {secondResponse.StatusCode} " +
    $"(the server saw {Volatile.Read(ref requestCount)} attempt(s) in total)");

// Stop the endpoint; Stop() blocks until the pending request handling completes,
// so no background work outlives the sample.
listener.Stop();

var ok = firstResponse.StatusCode == HttpStatusCode.OK && secondResponse.StatusCode == HttpStatusCode.OK;
Console.WriteLine(ok ? "sample: OK" : "sample: FAILED");
return ok ? 0 : 1;

static int GetFreePort()
{
    var tcp = new TcpListener(IPAddress.Loopback, 0);
    tcp.Start();
    var freePort = ((IPEndPoint)tcp.LocalEndpoint).Port;
    tcp.Stop();
    return freePort;
}

async Task ServeAsync(HttpListener listener)
{
    while (true)
    {
        HttpListenerContext context;
        try
        {
            context = await listener.GetContextAsync().ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is HttpListenerException or ObjectDisposedException)
        {
            return; // the listener was stopped
        }

        var attempt = Interlocked.Increment(ref requestCount);
        var payload = Encoding.UTF8.GetBytes(attempt == 1 ? "transient failure" : "ok");
        context.Response.StatusCode = attempt == 1 ? 503 : 200;
        context.Response.ContentType = "text/plain";
        await context.Response.OutputStream.WriteAsync(payload).ConfigureAwait(false);
        context.Response.Close();
    }
}

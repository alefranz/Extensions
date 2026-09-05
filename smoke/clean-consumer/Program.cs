// WantsACracker clean-consumer smoke scenario (see smoke/README.md).
//
// A minimal, fully offline consumer of the three 0.1.0-preview.1 packages:
// a named HttpClient wired through the real AddStandardResilienceHandler()
// registration path, exercised against a small in-process loopback
// HttpListener. The first request fails with a transient 503, which the
// standard handler's retry strategy recovers from, and the app exits 0 only
// if the retried response is 200. No network or external server is required.

using System;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.DependencyInjection;
using WantsACracker.Extensions.Http.Resilience;

// In-process endpoint: a 503 for the first request, 200 afterwards.
int requestCount = 0;
int port = GetFreePort();
var listener = new HttpListener();
listener.Prefixes.Add($"http://127.0.0.1:{port}/");
listener.Start();
_ = Task.Run(() => ServeAsync(listener));

// A named HttpClient wired with the standard resilience handler.
var serviceCollection = new ServiceCollection();
_ = serviceCollection.AddHttpClient("smoke").AddStandardResilienceHandler();
IServiceProvider services = serviceCollection.BuildServiceProvider();
var client = services.GetRequiredService<IHttpClientFactory>().CreateClient("smoke");

// The request: the server answers 503, the standard handler retries, and the
// retried attempt must come back 200.
HttpResponseMessage response;
try
{
    response = await client.GetAsync($"http://127.0.0.1:{port}/", CancellationToken.None);
}
finally
{
    // Stop() blocks until the pending request handling completes, so no
    // background work outlives the consumer.
    listener.Stop();
}

int attempts = Volatile.Read(ref requestCount);
string body = response.Content is not null ? await response.Content.ReadAsStringAsync() : string.Empty;
response.Dispose();

if (response.StatusCode == HttpStatusCode.OK && attempts == 2 && body == "ok")
{
    Console.WriteLine($"consumer: OK (first attempt 503, retry succeeded — the server saw {attempts} attempt(s))");
    return 0;
}

Console.Error.WriteLine(
    $"consumer: FAILED (HTTP {(int)response.StatusCode} {response.StatusCode}, server saw {attempts} attempt(s), body '{body}')");
return 1;

static int GetFreePort()
{
    var probe = new TcpListener(IPAddress.Loopback, 0);
    probe.Start();
    int p = ((IPEndPoint)probe.LocalEndpoint).Port;
    probe.Stop();
    return p;
}

async Task ServeAsync(HttpListener listener)
{
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

        int attempt = Interlocked.Increment(ref requestCount);
        var payload = attempt == 1 ? (int)HttpStatusCode.ServiceUnavailable : (int)HttpStatusCode.OK;
        context.Response.StatusCode = payload;
        var bytes = Encoding.UTF8.GetBytes(attempt == 1 ? "busy" : "ok");
        await context.Response.OutputStream.WriteAsync(bytes);
        context.Response.Close();
    }
}

// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using FluentAssertions;
using Microsoft.Extensions.DependencyInjection;
using WantsACracker.Extensions.Http.Resilience.Test.Helpers;
using Xunit;

namespace WantsACracker.Extensions.Http.Resilience.Test;

/// <summary>
/// Non-replayable request-body safety for the standard-handler path: the pipeline
/// created by <c>AddStandardResilienceHandler()</c> must never re-send a request
/// body that cannot safely be replayed (for example a non-seekable
/// <see cref="StreamContent"/>) when the first response is transient. The
/// replayable rule exercised here is: content is replayable only when it is null
/// or one of the built-in bufferable <see cref="HttpContent"/> types
/// (<see cref="StringContent"/>, <see cref="ByteArrayContent"/>,
/// <see cref="FormUrlEncodedContent"/>, <see cref="System.Net.Http.Json.JsonContent"/>,
/// and <see cref="MultipartContent"/> — the latter only when every child,
/// including nested <see cref="MultipartContent"/>, is itself replayable,
/// because the parent re-serialises its children on every send); every other
/// content shape, including <see cref="StreamContent"/>, custom
/// <see cref="HttpContent"/> subclasses, and a <see cref="MultipartContent"/>
/// with a one-shot child, is non-replayable and must be sent at most once.
/// </summary>
public sealed class NonReplayableContentTests
{
    private static readonly byte[] _payload = [1, 2, 3, 4];

    [Fact]
    public async Task AddStandardResilienceHandler_NonReplayableStreamContent_SentAtMostOnce()
    {
        var attempts = 0;
        using var client = CreateStandardClient((_, _) =>
        {
            attempts++;
            return new HttpResponseMessage(HttpStatusCode.ServiceUnavailable);
        });

        using var request = CreatePostRequest(new StreamContent(new UnseekableStream(_payload)));

        using var response = await client.Client.SendAsync(request);

        response.StatusCode.Should().Be(HttpStatusCode.ServiceUnavailable);
        attempts.Should().Be(1, "a non-replayable body must not be re-sent even though the first response is transient");
    }

    [Fact]
    public async Task AddStandardResilienceHandler_CustomHttpContent_SentAtMostOnce()
    {
        var attempts = 0;
        using var client = CreateStandardClient((_, _) =>
        {
            attempts++;
            return new HttpResponseMessage(HttpStatusCode.ServiceUnavailable);
        });

        using var request = CreatePostRequest(new CustomContent());

        using var response = await client.Client.SendAsync(request);

        response.StatusCode.Should().Be(HttpStatusCode.ServiceUnavailable);
        attempts.Should().Be(1, "content that is not one of the built-in bufferable types must not be re-sent");
    }

    [Fact]
    public async Task AddStandardResilienceHandler_ReplayableContent_IsRetried()
    {
        var attempts = 0;
        using var client = CreateStandardClient((_, _) =>
        {
            attempts++;
            return new HttpResponseMessage(HttpStatusCode.ServiceUnavailable);
        });

        using var request = CreatePostRequest(new ByteArrayContent(_payload));

        using var response = await client.Client.SendAsync(request);

        response.StatusCode.Should().Be(HttpStatusCode.ServiceUnavailable);
        attempts.Should().Be(4, "replayable content keeps the ordinary retry behavior (1 + MaxRetryAttempts)");
    }

    [Fact]
    public async Task AddStandardResilienceHandler_MultipartWithOneShotChild_SentAtMostOnce()
    {
        var attempts = 0;
        using var client = CreateStandardClient((_, _) =>
        {
            attempts++;
            return new HttpResponseMessage(HttpStatusCode.ServiceUnavailable);
        });

        // The multipart body re-serialises its children on every send, so a
        // one-shot child (a stream that can be read exactly once) makes the
        // whole body non-replayable: re-sending it would carry a drained,
        // silently changed second body. It must therefore go through the
        // no-retry pipeline and be sent at most once.
        using var bufferable = new StringContent("buffered");
        using var oneShot = new StreamContent(new UnseekableStream(_payload));
        using var multipart = new MultipartContent("form-data");
        multipart.Add(bufferable);
        multipart.Add(oneShot);

        using var request = CreatePostRequest(multipart);

        using var response = await client.Client.SendAsync(request);

        response.StatusCode.Should().Be(HttpStatusCode.ServiceUnavailable);
        attempts.Should().Be(1, "a multipart body with a one-shot child must not be re-sent, even though the first response is transient");
    }

    private static HttpRequestMessage CreatePostRequest(HttpContent content)
        => new(HttpMethod.Post, "https://dummy")
        {
            Content = content
        };

    /// <summary>
    /// A standard-resilience client plus the service provider that owns the
    /// pipeline registry; the provider must stay alive for the lifetime of the
    /// client because the pipeline is resolved per request.
    /// </summary>
    private sealed record StandardClient(HttpClient Client, ServiceProvider Provider) : IDisposable
    {
        public void Dispose()
        {
            Client.Dispose();
            Provider.Dispose();
        }
    }

    private static StandardClient CreateStandardClient(Func<HttpRequestMessage, CancellationToken, HttpResponseMessage> handler)
    {
        var builder = new ServiceCollection()
            .AddLogging()
            .AddMetrics()
            .AddHttpClient("test");

        _ = builder.AddStandardResilienceHandler(options =>
        {
            options.Retry.Delay = TimeSpan.Zero;
            options.Retry.MaxRetryAttempts = 3;
        });

        // The stub is registered after the resilience handler, so it sits
        // innermost in the chain and counts the attempts the pipeline sends.
        _ = builder.AddHttpMessageHandler(() => new TestHandlerStub((request, cancellationToken) => Task.FromResult(handler(request, cancellationToken))));

        var provider = builder.Services.BuildServiceProvider();
        return new StandardClient(provider.GetRequiredService<IHttpClientFactory>().CreateClient("test"), provider);
    }

    private sealed class UnseekableStream : Stream
    {
        private readonly byte[] _data;
        private int _position;

        public UnseekableStream(byte[] data)
        {
            _data = data;
        }

        public override bool CanRead => true;

        public override bool CanSeek => false;

        public override bool CanWrite => false;

        public override long Length => _data.Length;

        public override long Position
        {
            get => _position;
            set => throw new NotSupportedException();
        }

        public override void Flush()
        {
        }

        public override int Read(byte[] buffer, int offset, int count)
        {
            var readable = Math.Min(count, _data.Length - _position);
            Array.Copy(_data, _position, buffer, offset, readable);
            _position += readable;
            return readable;
        }

        public override long Seek(long offset, SeekOrigin origin)
            => throw new NotSupportedException();

        public override void SetLength(long value)
            => throw new NotSupportedException();

        public override void Write(byte[] buffer, int offset, int count)
            => throw new NotSupportedException();
    }

    private sealed class CustomContent : HttpContent
    {
        protected override bool TryComputeLength(out long length)
        {
            length = 0;
            return false;
        }

        protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context)
            => stream.WriteAsync(_payload, 0, _payload.Length, default);
    }
}

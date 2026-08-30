// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System;
using System.Net.Http;
using System.Threading.Tasks;
using FluentAssertions;
using Moq;
using WantsACracker;
using WantsACracker.Extensions.Http.Resilience.Internal;
using Xunit;

namespace WantsACracker.Extensions.Http.Resilience.Test.Internal;

public class RequestMessageSnapshotStrategyTests
{
    [Fact]
    public async Task ExecuteAsync_EnsureSnapshotAttached()
    {
        var strategy = Create();
        var context = ResilienceContextPool.Shared.Get();
        using var request = new HttpRequestMessage();
        context.SetRequestMessage(request);

        using var response = await strategy.ExecuteAsync(
            (ResilienceContext ctx, object? state) =>
            {
                ctx.Properties.GetValue(ResilienceKeys.RequestSnapshot).Should().NotBeNull();
                return new ValueTask<HttpResponseMessage>(new HttpResponseMessage());
            },
            context,
            default);
    }

    [Fact]
    public void ExecuteAsync_RequestMessageNotFound_Throws()
    {
        var strategy = Create();

        strategy.Invoking(s => s.Execute((ResilienceContext c, object? state) => true, ResilienceContextPool.Shared.Get(), default)).Should().Throw<InvalidOperationException>();
    }

    [Fact]
    public void ExecuteAsync_RequestMessageIsNull_Throws()
    {
        var strategy = Create();
        var context = ResilienceContextPool.Shared.Get();
        context.SetRequestMessage(null);

        strategy.Invoking(s => s.Execute((ResilienceContext c, object? state) => true, context, default)).Should().Throw<InvalidOperationException>();
    }

    private static ResiliencePipeline Create() => new ResiliencePipelineBuilder().AddStrategy(_ => new RequestMessageSnapshotStrategy(), Mock.Of<ResilienceStrategyOptions>()).Build();
}

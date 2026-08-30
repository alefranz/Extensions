// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System;
using System.Collections.Generic;
using System.Diagnostics.CodeAnalysis;

namespace WantsACracker.Extensions.Http.Resilience.Internal;

/// <summary>
/// Identifies a resilience pipeline by name and instance name.
/// </summary>
/// <param name="Name">The name of the pipeline.</param>
/// <param name="InstanceName">The name of the pipeline instance.</param>
/// <remarks>
/// Exposed publicly (despite living in the <c>Internal</c> namespace) so that the
/// pipeline-provider key can be used by test proxies and consumers; the type is
/// part of the public API surface of this package.
/// </remarks>
public readonly record struct HttpKey(string Name, string InstanceName)
{
    /// <summary>
    /// Gets a comparer that compares <see cref="HttpKey"/> instances by <see cref="Name"/> only.
    /// </summary>
    /// <remarks>
    /// Used by the pipeline registry to group pipeline instances that share the
    /// same pipeline name but differ by instance name.
    /// </remarks>
    public static readonly IEqualityComparer<HttpKey> BuilderComparer = new BuilderEqualityComparer();

    private sealed class BuilderEqualityComparer : IEqualityComparer<HttpKey>
    {
        public bool Equals(HttpKey x, HttpKey y) => StringComparer.Ordinal.Equals(x.Name, y.Name);

        public int GetHashCode([DisallowNull] HttpKey obj) => StringComparer.Ordinal.GetHashCode(obj.Name);
    }
}

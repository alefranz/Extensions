using System.Collections.Generic;
using Microsoft.Extensions.Primitives;

namespace Microsoft.Extensions.Http.HeaderPropagation
{
    public interface IContextValuesAccessor
    {
        IDictionary<string, StringValues> ContextValues { get; }
    }
}

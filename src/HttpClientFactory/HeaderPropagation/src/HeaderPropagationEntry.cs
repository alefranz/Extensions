using Microsoft.Extensions.Primitives;
using System;
using System.Collections.Generic;
using System.Net.Http;

namespace Microsoft.Extensions.Http.HeaderPropagation
{
    public class HeaderPropagationEntry
    {
        public string InputName { get; set; }
        public string OutputName { get; set; }
        public StringValues DefaultValues { get; set; }
        public Func<HttpRequestMessage, IDictionary<string, StringValues>, StringValues> DefaultValuesGenerator { get; set; }
        public bool AlwaysAdd { get; set; }
    }
}

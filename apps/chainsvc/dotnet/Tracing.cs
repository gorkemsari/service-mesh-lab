using System.Security.Cryptography;
using System.Text.Json;
using System.Threading.Channels;

namespace ChainSvc;

/// <summary>B3 iz bağlamı. Başlıklar her zaman taşınır; span'ler yalnızca TRACING_ZIPKIN doluysa gönderilir.</summary>
public readonly record struct TraceCtx(string TraceId, string SpanId, string ParentId, string Sampled)
{
    static string NewId(int bytes) => Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(bytes));

    public static TraceCtx Extract(Func<string, string?> get)
    {
        var tc = new TraceCtx(get("X-B3-TraceId") ?? "", get("X-B3-SpanId") ?? "", get("X-B3-ParentSpanId") ?? "", get("X-B3-Sampled") ?? "");
        if (tc.TraceId == "") tc = new TraceCtx(NewId(16), NewId(8), "", "1");
        if (tc.Sampled == "") tc = tc with { Sampled = "1" };
        return tc;
    }

    public TraceCtx Child() => new(TraceId, NewId(8), SpanId, Sampled);

    public void Inject(Action<string, string> set)
    {
        set("X-B3-TraceId", TraceId);
        set("X-B3-SpanId", SpanId);
        if (ParentId != "") set("X-B3-ParentSpanId", ParentId);
        set("X-B3-Sampled", Sampled);
    }
}

/// <summary>Zipkin v2 span gönderici: kuyruk (10 000, doluysa düşürür), 200'lük gruplar veya saniyede bir gönderim.</summary>
public sealed class ZipkinTracer
{
    readonly string _url;
    readonly Channel<Dictionary<string, object>> _ch =
        Channel.CreateBounded<Dictionary<string, object>>(new BoundedChannelOptions(10_000) { FullMode = BoundedChannelFullMode.DropWrite });
    readonly HttpClient _http = new();

    public ZipkinTracer(string url)
    {
        _url = url;
        if (url != "") _ = Task.Run(Loop);
    }

    public void Span(TraceCtx tc, string kind, string service, string name, DateTimeOffset start, TimeSpan d)
    {
        if (_url == "" || tc.Sampled == "0") return;
        var s = new Dictionary<string, object>
        {
            ["traceId"] = tc.TraceId, ["id"] = tc.SpanId, ["kind"] = kind.ToUpperInvariant(), ["name"] = name,
            ["timestamp"] = (start.UtcTicks - DateTimeOffset.UnixEpoch.UtcTicks) / 10, ["duration"] = d.Ticks / 10,
            ["localEndpoint"] = new Dictionary<string, string> { ["serviceName"] = service },
        };
        if (tc.ParentId != "") s["parentId"] = tc.ParentId;
        _ch.Writer.TryWrite(s);   // kuyruk doluysa düşer (yükü etkilemesin)
    }

    async Task Loop()
    {
        var batch = new List<Dictionary<string, object>>(200);
        while (true)
        {
            using (var cts = new CancellationTokenSource(TimeSpan.FromSeconds(1)))
            {
                try
                {
                    while (batch.Count < 200 && await _ch.Reader.WaitToReadAsync(cts.Token))
                        while (batch.Count < 200 && _ch.Reader.TryRead(out var s)) batch.Add(s);
                }
                catch (OperationCanceledException) { }
            }
            if (batch.Count == 0) continue;
            try
            {
                // tamponlanmış gövde (Content-Length); PostAsJsonAsync chunked gönderir
                using var body = new ByteArrayContent(JsonSerializer.SerializeToUtf8Bytes(batch));
                body.Headers.ContentType = new("application/json");
                using var _ = await _http.PostAsync(_url, body);
            }
            catch (Exception) { /* trace kaybı ölçümü etkilemez */ }
            batch.Clear();
        }
    }
}

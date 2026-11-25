using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;
using Grpc.Core;
using Grpc.Net.Client;
using ChainSvc.Proto;

namespace ChainSvc;

/// <summary>HTTP JSON cevabı (sözleşme: ../README.md). Alan adları ve sırası Go uygulamasıyla aynı.</summary>
public sealed class Reply
{
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("uri")] public string Uri { get; set; } = "";
    [JsonPropertyName("type")] public string Type { get; set; } = "";
    [JsonPropertyName("ip_addresses")] public List<string>? IpAddresses { get; set; }
    [JsonPropertyName("start_time")] public string StartTime { get; set; } = "";
    [JsonPropertyName("end_time")] public string EndTime { get; set; } = "";
    [JsonPropertyName("duration")] public string Duration { get; set; } = "";
    [JsonPropertyName("body"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public string? Body { get; set; }
    [JsonPropertyName("upstream_calls"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public List<Reply>? UpstreamCalls { get; set; }
    [JsonPropertyName("code")] public int Code { get; set; }
    [JsonPropertyName("error"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public string? Error { get; set; }

    public static readonly JsonSerializerOptions Indented = new() { WriteIndented = true, Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
    public static readonly JsonSerializerOptions Compact = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    public static Reply? TryParse(string s)
    {
        try { return JsonSerializer.Deserialize<Reply>(s, Compact); }
        catch (JsonException) { return null; }
    }

    public Response ToPb()
    {
        var o = new Response
        {
            Name = Name, Uri = Uri, Type = Type, StartTime = StartTime, EndTime = EndTime, Duration = Duration,
            Body = Body ?? "", Code = Code, Error = Error ?? "",
        };
        if (IpAddresses != null) o.IpAddresses.Add(IpAddresses);
        if (UpstreamCalls != null) o.UpstreamCalls.Add(UpstreamCalls.Select(u => u.ToPb()));
        return o;
    }

    public static Reply FromPb(Response r) => new()
    {
        Name = r.Name, Uri = r.Uri, Type = r.Type, IpAddresses = [.. r.IpAddresses], StartTime = r.StartTime,
        EndTime = r.EndTime, Duration = r.Duration, Body = r.Body == "" ? null : r.Body,
        UpstreamCalls = r.UpstreamCalls.Count == 0 ? null : [.. r.UpstreamCalls.Select(FromPb)],
        Code = r.Code, Error = r.Error == "" ? null : r.Error,
    };
}

/// <summary>Tek isteğin işlenmesi (HTTP ve gRPC ortak): hata enjeksiyonu, upstream çağrıları, yapay işlem süresi.</summary>
public sealed class ChainHandler
{
    const int GrpcInternal = (int)StatusCode.Internal;
    readonly Config _cfg;
    readonly ZipkinTracer _tracer;
    readonly List<string> _localIps = LocalIPv4();
    readonly ConcurrentDictionary<string, Lazy<Chain.ChainClient>> _grpc = new();

    // HTTP keep-alive havuzu (Go: MaxIdleConnsPerHost 200, IdleConnTimeout 60 sn, bağlantı zaman aşımı 3 sn)
    readonly HttpClient _http = new(new SocketsHttpHandler
    {
        PooledConnectionIdleTimeout = TimeSpan.FromSeconds(60),
        ConnectTimeout = TimeSpan.FromSeconds(3),
        UseProxy = false,
        AllowAutoRedirect = false,
    }) { Timeout = System.Threading.Timeout.InfiniteTimeSpan };

    public ChainHandler(Config cfg, ZipkinTracer tracer)
    {
        _cfg = cfg;
        _tracer = tracer;
    }

    public Config Config => _cfg;
    public ZipkinTracer Tracer => _tracer;

    static List<string> LocalIPv4() =>
        [.. NetworkInterface.GetAllNetworkInterfaces()
            .SelectMany(i => i.GetIPProperties().UnicastAddresses)
            .Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a.Address))
            .Select(a => a.Address.ToString())];

    static string Now() => DateTime.Now.ToString("yyyy-MM-dd'T'HH:mm:ss.ffffff", CultureInfo.InvariantCulture);

    /// <summary>İşlem süresi: yüzdelik değerler arasında doğrusal dağılım (Go uygulamasıyla aynı).</summary>
    TimeSpan Sample()
    {
        var r = Random.Shared.NextDouble();
        static TimeSpan Lerp(TimeSpan a, TimeSpan b, double f) => a + (b - a) * f;
        return r switch
        {
            < 0.5 => Lerp(TimeSpan.Zero, _cfg.P50, r / 0.5),
            < 0.9 => Lerp(_cfg.P50, _cfg.P90, (r - 0.5) / 0.4),
            < 0.99 => Lerp(_cfg.P90, _cfg.P99, (r - 0.9) / 0.09),
            _ => _cfg.P99,
        };
    }

    /// <summary>
    /// Task.Delay milisaniye çözünürlüğündedir (kesirli kısmı atar). Ortalama süre hedefle aynı kalsın diye kesir
    /// olasılıksal yuvarlanır: 1.3 ms -> %70 olasılıkla 1 ms, %30 olasılıkla 2 ms.
    /// </summary>
    static Task Sleep(TimeSpan d)
    {
        if (d <= TimeSpan.Zero) return Task.CompletedTask;
        var ms = d.TotalMilliseconds;
        var whole = (int)ms;
        if (Random.Shared.NextDouble() < ms - whole) whole++;
        return whole == 0 ? Task.CompletedTask : Task.Delay(whole);
    }

    public async Task<(Reply Reply, bool Ok)> Handle(string path, TraceCtx tc, CancellationToken ct)
    {
        var sw = Stopwatch.StartNew();
        var start = Now();
        var resp = new Reply
        {
            Name = _cfg.Name, Uri = path, Type = _cfg.Grpc ? "gRPC" : "HTTP", IpAddresses = _localIps,
            Body = _cfg.Message, Code = _cfg.Grpc ? 0 : 200,
        };
        var ok = true;
        var injectDelay = TimeSpan.Zero;
        if (_cfg.ErrorRate > 0 && Random.Shared.NextDouble() < _cfg.ErrorRate)
        {
            if (_cfg.ErrorType == "delay") injectDelay = _cfg.ErrorDelay;
            else
            {
                ok = false;
                resp.Error = "Service error automatically injected";
                resp.Code = _cfg.Grpc ? GrpcInternal : _cfg.ErrorCode;
            }
        }
        if (ok && _cfg.Upstreams.Count > 0)
        {
            var calls = new Reply[_cfg.Upstreams.Count];
            using var sem = new SemaphoreSlim(_cfg.Workers);
            await Task.WhenAll(_cfg.Upstreams.Select(async (u, i) =>
            {
                await sem.WaitAsync(CancellationToken.None);
                try { calls[i] = await CallUpstream(u, path, tc, ct); }
                finally { sem.Release(); }
            }));
            resp.UpstreamCalls = [.. calls];
            foreach (var uc in calls)
            {
                var good = uc.Code == 200 || (uc.Type == "gRPC" && uc.Code == 0);
                if (good) continue;
                ok = false;
                resp.Error = $"Error processing upstream request: {uc.Uri}, {uc.Error}";
                resp.Code = _cfg.Grpc ? GrpcInternal : 500;
            }
        }
        await Sleep(Sample() + injectDelay);
        resp.StartTime = start;
        resp.EndTime = Now();
        resp.Duration = GoDuration.Format(sw.Elapsed);
        return (resp, ok);
    }

    string UpstreamPath(string path) => _cfg.AppendRequest && path != "" ? path : "/";

    async Task<Reply> CallUpstream(string uri, string path, TraceCtx tc, CancellationToken ct)
    {
        var child = tc.Child();
        var started = DateTimeOffset.UtcNow;
        var sw = Stopwatch.StartNew();
        var r = uri.StartsWith("grpc://", StringComparison.Ordinal)
            ? await CallGrpc(uri["grpc://".Length..], path, child, ct)
            : await CallHttp(uri, path, child, ct);
        _tracer.Span(child, "client", _cfg.Name, uri, started, sw.Elapsed);
        return r;
    }

    async Task<Reply> CallHttp(string baseUri, string path, TraceCtx tc, CancellationToken ct)
    {
        var u = baseUri.TrimEnd('/') + UpstreamPath(path);
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(_cfg.Timeout);
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, u);
            tc.Inject((k, v) => req.Headers.TryAddWithoutValidation(k, v));
            using var res = await _http.SendAsync(req, HttpCompletionOption.ResponseContentRead, cts.Token);
            var body = await res.Content.ReadAsStringAsync(cts.Token);   // gövde her zaman okunur -> bağlantı havuza temiz döner
            var code = (int)res.StatusCode;
            var o = Reply.TryParse(body);
            if (o == null || o.Name == "")
                return new Reply { Uri = u, Type = "HTTP", Code = code, Error = $"expected code 200, got {code}" };
            o.Uri = u;
            o.Code = code;
            if (code != 200 && o.Error == null) o.Error = $"expected code 200, got {code}";
            return o;
        }
        catch (Exception e) when (e is HttpRequestException or OperationCanceledException or IOException)
        {
            return new Reply { Uri = u, Type = "HTTP", Code = -1, Error = $"Get \"{u}\": {e.Message}" };
        }
    }

    /// <summary>Hedef başına tek kalıcı HTTP/2 bağlantısı (istemci tarafı yük dengeleme yok; Go: passthrough).</summary>
    Chain.ChainClient GrpcClient(string target) => _grpc.GetOrAdd(target, t => new Lazy<Chain.ChainClient>(() =>
        new Chain.ChainClient(GrpcChannel.ForAddress("http://" + t, new GrpcChannelOptions
        {
            Credentials = ChannelCredentials.Insecure,
            HttpHandler = new SocketsHttpHandler
            {
                EnableMultipleHttp2Connections = false,
                PooledConnectionIdleTimeout = System.Threading.Timeout.InfiniteTimeSpan,
                ConnectTimeout = TimeSpan.FromSeconds(3),
                UseProxy = false,
            },
        })))).Value;

    async Task<Reply> CallGrpc(string target, string path, TraceCtx tc, CancellationToken ct)
    {
        var uri = "grpc://" + target;
        var md = new Metadata();
        tc.Inject((k, v) => md.Add(k.ToLowerInvariant(), v));
        Reply o;
        try
        {
            var res = await GrpcClient(target).CallAsync(new CallRequest { Path = UpstreamPath(path) },
                headers: md, deadline: DateTime.UtcNow + _cfg.Timeout, cancellationToken: ct);
            o = Reply.FromPb(res);
        }
        catch (RpcException e)
        {
            var msg = e.Status.Detail;
            var parsed = msg.StartsWith('{') ? Reply.TryParse(msg) : null;
            o = parsed ?? new Reply();
            o.Code = (int)e.StatusCode;
            o.Error = parsed != null ? parsed.Error : msg;
        }
        o.Uri = uri;
        o.Type = "gRPC";
        return o;
    }
}

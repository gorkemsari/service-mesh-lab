// chainsvc (.NET): service-mesh-lab servis zinciri test uygulaması.
//
// Davranış sözleşmesi ../README.md dosyasındadır; Go uygulamasıyla aynı ortam değişkenleri, aynı HTTP JSON cevabı ve
// aynı gRPC sözleşmesi (../proto/chain.proto). Barındırma ASP.NET Core / Kestrel varsayılanlarıyla yapılır:
//   SERVER_TYPE=http -> HTTP/1.1 (keep-alive), SERVER_TYPE=grpc -> HTTP/2 cleartext (h2c)
//   SIGTERM -> yeni bağlantı kabul edilmez, devam eden istekler en fazla 8 sn içinde tamamlanır
using System.Net;
using System.Text;
using System.Text.Json;
using ChainSvc;
using Grpc.Core;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using ChainSvc.Proto;

var cfg = Config.Load();
var builder = WebApplication.CreateBuilder(args);

builder.Logging.ClearProviders();
builder.Logging.AddSimpleConsole(o => o.SingleLine = true);
builder.Logging.SetMinimumLevel(cfg.LogLevel switch
{
    "trace" => LogLevel.Trace, "debug" => LogLevel.Debug, "warn" or "warning" => LogLevel.Warning,
    "error" => LogLevel.Error, _ => LogLevel.Information,
});
builder.Services.Configure<HostOptions>(o => o.ShutdownTimeout = TimeSpan.FromSeconds(8));

var listen = cfg.Listen.Split(':');
var ip = listen[0] is "" or "0.0.0.0" ? IPAddress.Any : IPAddress.Parse(listen[0]);
builder.WebHost.ConfigureKestrel(k =>
{
    k.AddServerHeader = false;
    k.Limits.KeepAliveTimeout = TimeSpan.FromSeconds(90);       // Go: IdleTimeout
    k.Limits.RequestHeadersTimeout = TimeSpan.FromSeconds(5);   // Go: ReadHeaderTimeout
    k.Listen(ip, int.Parse(listen[^1]), l => l.Protocols = cfg.Grpc ? HttpProtocols.Http2 : HttpProtocols.Http1);
});

builder.Services.AddSingleton(cfg);
builder.Services.AddSingleton(new ZipkinTracer(cfg.Zipkin));
builder.Services.AddSingleton<ChainHandler>();
if (cfg.Grpc) builder.Services.AddGrpc();

var app = builder.Build();

if (cfg.Grpc)
{
    app.MapGrpcService<ChainGrpcService>();
}
else
{
    app.MapGet("/ready", () => Results.Text("OK\n"));
    app.MapGet("/health", () => Results.Text("OK\n"));
    app.Map("/{**path}", async (HttpContext ctx, ChainHandler chain) =>
    {
        await ctx.Request.Body.CopyToAsync(Stream.Null);
        var tc = TraceCtx.Extract(k => ctx.Request.Headers.TryGetValue(k, out var v) ? v.ToString() : null);
        var started = DateTimeOffset.UtcNow;
        var path = ctx.Request.Path.Value ?? "/";
        var (resp, ok) = await chain.Handle(path, tc, ctx.RequestAborted);
        chain.Tracer.Span(tc, "server", cfg.Name, $"{ctx.Request.Method} {path}", started, DateTimeOffset.UtcNow - started);
        var body = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(resp, Reply.Indented) + "\n");
        if (!ok) ctx.Response.StatusCode = resp.Code;
        ctx.Response.ContentType = "application/json";
        ctx.Response.ContentLength = body.Length;
        await ctx.Response.Body.WriteAsync(body);
    });
}

app.Run();

/// <summary>gRPC sunucusu: hata durumunda gRPC durum kodu + mesajda JSON cevap (çağıran zincir ayrıntısını görür).</summary>
sealed class ChainGrpcService(ChainHandler chain) : Chain.ChainBase
{
    public override async Task<Response> Call(CallRequest request, ServerCallContext context)
    {
        var tc = TraceCtx.Extract(k => context.RequestHeaders.GetValue(k.ToLowerInvariant()));
        var started = DateTimeOffset.UtcNow;
        var (resp, ok) = await chain.Handle(request.Path, tc, context.CancellationToken);
        chain.Tracer.Span(tc, "server", chain.Config.Name, "/chain.Chain/Call", started, DateTimeOffset.UtcNow - started);
        if (!ok) throw new RpcException(new Status((StatusCode)resp.Code, JsonSerializer.Serialize(resp, Reply.Compact)));
        return resp.ToPb();
    }
}

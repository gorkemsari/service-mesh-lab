using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace ChainSvc;

/// <summary>Ortam değişkenlerinden yapılandırma (sözleşme: ../README.md). Varsayılanlar Go uygulamasıyla aynıdır.</summary>
public sealed record Config
{
    public string Name { get; init; } = "service";
    public string Message { get; init; } = "Hello World";
    public string Listen { get; init; } = "0.0.0.0:9090";
    public bool Grpc { get; init; }
    public IReadOnlyList<string> Upstreams { get; init; } = [];
    public int Workers { get; init; } = 1;
    public TimeSpan P50 { get; init; }
    public TimeSpan P90 { get; init; }
    public TimeSpan P99 { get; init; }
    public double ErrorRate { get; init; }
    public string ErrorType { get; init; } = "http_error";
    public int ErrorCode { get; init; } = 500;
    public TimeSpan ErrorDelay { get; init; }
    public TimeSpan Timeout { get; init; } = TimeSpan.FromSeconds(10);
    public bool AppendRequest { get; init; } = true;
    public string Zipkin { get; init; } = "";
    public string LogLevel { get; init; } = "info";

    static string Env(string key, string def)
    {
        var v = Environment.GetEnvironmentVariable(key);
        return string.IsNullOrEmpty(v) ? def : v;
    }

    public static Config Load()
    {
        var p50 = GoDuration.Parse(Env("TIMING_50_PERCENTILE", "0s"));
        var p90 = GoDuration.Parse(Env("TIMING_90_PERCENTILE", GoDuration.Format(p50)));
        var p99 = GoDuration.Parse(Env("TIMING_99_PERCENTILE", GoDuration.Format(p90)));
        var zipkin = Env("TRACING_ZIPKIN", "");
        if (zipkin != "" && !zipkin.Contains("/api/"))
            zipkin = zipkin.TrimEnd('/') + "/api/v2/spans";
        _ = int.TryParse(Env("UPSTREAM_WORKERS", "1"), out var workers);
        _ = double.TryParse(Env("ERROR_RATE", "0"), NumberStyles.Float, CultureInfo.InvariantCulture, out var errRate);
        _ = int.TryParse(Env("ERROR_CODE", "500"), out var errCode);
        return new Config
        {
            Name = Env("NAME", "service"),
            Message = Env("MESSAGE", "Hello World"),
            Listen = Env("LISTEN_ADDR", "0.0.0.0:9090"),
            Grpc = Env("SERVER_TYPE", "http") == "grpc",
            Upstreams = Env("UPSTREAM_URIS", "").Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries),
            Workers = Math.Max(1, workers),
            P50 = p50, P90 = p90, P99 = p99,
            ErrorRate = errRate,
            ErrorType = Env("ERROR_TYPE", "http_error"),
            ErrorCode = errCode,
            ErrorDelay = GoDuration.Parse(Env("ERROR_DELAY", "0s")),
            Timeout = GoDuration.Parse(Env("HTTP_CLIENT_REQUEST_TIMEOUT", "10s")),
            AppendRequest = Env("HTTP_CLIENT_APPEND_REQUEST", "true") == "true",
            Zipkin = zipkin,
            LogLevel = Env("LOG_LEVEL", "info"),
        };
    }
}

/// <summary>Go time.Duration ile aynı ayrıştırma ("1.5ms", "200ms", "1m30s") ve biçimlendirme ("1.234567ms").</summary>
public static partial class GoDuration
{
    [GeneratedRegex(@"^(\d+(?:\.\d*)?|\.\d+)(ns|us|µs|μs|ms|s|m|h)")]
    private static partial Regex Part();

    /// <summary>Geçersiz değerde Go uygulaması gibi 0 döner.</summary>
    public static TimeSpan Parse(string s)
    {
        if (s == "0") return TimeSpan.Zero;
        double ns = 0;
        var rest = s;
        if (rest.Length == 0) return TimeSpan.Zero;
        while (rest.Length > 0)
        {
            var m = Part().Match(rest);
            if (!m.Success) return TimeSpan.Zero;
            var v = double.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture);
            ns += v * m.Groups[2].Value switch
            {
                "ns" => 1, "us" or "µs" or "μs" => 1e3, "ms" => 1e6, "s" => 1e9, "m" => 60e9, _ => 3600e9,
            };
            rest = rest[m.Length..];
        }
        return TimeSpan.FromTicks((long)Math.Round(ns / 100));
    }

    public static string Format(TimeSpan d)
    {
        long ns = d.Ticks * 100;
        if (ns == 0) return "0s";
        var neg = ns < 0;
        ulong u = (ulong)Math.Abs(ns);
        string s;
        if (u < 1_000) s = $"{u}ns";
        else if (u < 1_000_000) s = Frac(u, 1_000) + "µs";
        else if (u < 1_000_000_000) s = Frac(u, 1_000_000) + "ms";
        else
        {
            var sb = new StringBuilder();
            ulong h = u / 3_600_000_000_000, m = u / 60_000_000_000 % 60, sec = u % 60_000_000_000;
            if (h > 0) sb.Append(h).Append('h');
            if (h > 0 || m > 0) sb.Append(m).Append('m');
            sb.Append(Frac(sec, 1_000_000_000)).Append('s');
            s = sb.ToString();
        }
        return neg ? "-" + s : s;
    }

    static string Frac(ulong v, ulong unit)
    {
        var whole = v / unit;
        var rem = v % unit;
        if (rem == 0) return whole.ToString(CultureInfo.InvariantCulture);
        var digits = unit.ToString(CultureInfo.InvariantCulture).Length - 1;
        return $"{whole}.{rem.ToString(CultureInfo.InvariantCulture).PadLeft(digits, '0').TrimEnd('0')}";
    }
}

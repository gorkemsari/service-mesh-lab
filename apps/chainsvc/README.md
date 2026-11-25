# chainsvc: test servisi ve dil sözleşmesi

`chainsvc`, servis zincirindeki (shop) her servisi oluşturan küçük bir HTTP / gRPC servisidir. Aynı davranış
birden fazla dilde uygulanır; testler hangi dilin çalıştığını bilmez, yalnızca bu sözleşmeye güvenir.
Böylece mesh testleri her dil için aynen koşulur ve fark yalnızca uygulama çalışma zamanından gelir.

| Dil | Dizin | İmaj | Yığın |
|---|---|---|---|
| Go | [`go/`](go/) | `smlab/chainsvc-go:1.0.0` (scratch, ~17 MB) | Go 1.26.11, net/http, grpc-go 1.75.0 |
| .NET | [`dotnet/`](dotnet/) | `smlab/chainsvc-dotnet:1.0.0` (Ubuntu chiseled, ~184 MB) | .NET 10.0.15, ASP.NET Core Kestrel, Grpc.AspNetCore 2.85.0 |

```
apps/chainsvc/
  proto/chain.proto       gRPC sözleşmesi (tüm diller buradan kod üretir)
  proto/gen-go.sh         Go kodunu üretir (go/chainpb/, repoda tutulur)
  go/                     Go uygulaması + Dockerfile
  dotnet/                 .NET uygulaması + Dockerfile (proto kodu derlemede Grpc.Tools ile üretilir)
  conformance/run.sh      sözleşme testi (smlab app conformance)
```

İmajlar `apps/chainsvc` bağlamıyla derlenir (`docker build -f <dil>/Dockerfile apps/chainsvc`); `smlab setup`,
`smlab app use` ve `smlab app build` bunu kendiliğinden yapar.

## Sözleşme

### Ortam değişkenleri

| Değişken | Varsayılan | Anlamı |
|---|---|---|
| `NAME` | `service` | Servis adı (cevaptaki `name`) |
| `MESSAGE` | `Hello World` | Cevaptaki `body` |
| `LISTEN_ADDR` | `0.0.0.0:9090` | Dinleme adresi |
| `SERVER_TYPE` | `http` | `http`: HTTP/1.1 sunucu · `grpc`: HTTP/2 cleartext (h2c) gRPC sunucu |
| `UPSTREAM_URIS` | boş | Virgülle ayrılmış çağrılacak servisler: `http://host:port` veya `grpc://host:port` |
| `UPSTREAM_WORKERS` | `1` | Aynı anda en fazla kaç upstream çağrısı (paralel dallanma) |
| `TIMING_50_PERCENTILE` / `_90_` / `_99_` | `0s` / p50 / p90 | Yapay işlem süresinin yüzdelikleri (Go süre biçimi: `1ms`, `1.5s`) |
| `ERROR_RATE` | `0` | Hata / gecikme enjeksiyonu olasılığı (0..1) |
| `ERROR_TYPE` | `http_error` | `http_error`: hata döner · `delay`: `ERROR_DELAY` kadar ek gecikme |
| `ERROR_CODE` | `500` | Enjekte edilen HTTP hata kodu (gRPC sunucuda her zaman 13 / Internal) |
| `ERROR_DELAY` | `0s` | `ERROR_TYPE=delay` ek gecikmesi |
| `HTTP_CLIENT_REQUEST_TIMEOUT` | `10s` | Upstream çağrısı başına zaman aşımı (HTTP ve gRPC) |
| `HTTP_CLIENT_APPEND_REQUEST` | `true` | Gelen yol upstream çağrısına aktarılır |
| `TRACING_ZIPKIN` | boş | Zipkin adresi (`http://host:9411`); boşsa span gönderilmez, B3 başlıkları yine taşınır |
| `LOG_LEVEL` | `info` | Uygulama logu (zincirde `error`) |

### İstek işleme (her iki sunucu türünde aynı)

1. `ERROR_RATE` olasılığıyla hata (`code` = `ERROR_CODE`, `error` = `Service error automatically injected`)
   veya gecikme (`ERROR_TYPE=delay`) enjekte edilir. Hata enjekte edildiyse upstream çağrılmaz.
2. Upstream'ler en fazla `UPSTREAM_WORKERS` paralellikle çağrılır; cevaplar `upstream_calls` içinde **tanım
   sırasıyla** yer alır. Biri başarısızsa (HTTP ≠ 200, gRPC ≠ 0) servis de başarısız olur:
   `code` = 500 (gRPC sunucuda 13), `error` = `Error processing upstream request: <uri>, <upstream error>`.
3. Yapay işlem süresi beklenir: yüzdelikler arası doğrusal dağılım (`r<0.5`: 0..p50, `<0.9`: p50..p90,
   `<0.99`: p90..p99, kalan: p99) + varsa enjekte edilen gecikme.
   **Kural:** bekleme milisaniye çözünürlüğünde yapılır; kesirli kısım olasılıksal yuvarlanır (1.3 ms → %70
   olasılıkla 1 ms, %30 olasılıkla 2 ms). Gerekçe: Go zamanlayıcısı ms altı beklemeleri yukarı (+0.56 ms),
   .NET `Task.Delay` aşağı (−0.38 ms) yuvarlar; bu kural olmadan 1–5 ms dağılımda diller arasında hop başına
   ~1 ms fark oluşur ve dil kıyası yanıltıcı olur. Kuralla gerçekleşen ortalama her iki dilde ~1.37 ms (hedef 1.215 ms).

### HTTP sunucusu (`SERVER_TYPE=http`)

- `GET /ready`, `GET /health` → `200 OK\n` (`text/plain`)
- Diğer tüm yollar ve metotlar → zincir isteği. Cevap: girintili (2 boşluk) JSON + `\n`, `Content-Type: application/json`,
  `Content-Length` dolu, başarısızsa durum kodu = `code`. `Server` başlığı gönderilmez.
- HTTP/1.1 keep-alive (boşta 90 sn), başlık okuma zaman aşımı 5 sn.

```json
{
  "name": "gateway",
  "uri": "/",
  "type": "HTTP",
  "ip_addresses": ["10.20.1.17"],
  "start_time": "2026-11-25T12:00:00.123456",
  "end_time": "2026-11-25T12:00:00.135790",
  "duration": "12.334ms",
  "body": "gateway v1",
  "upstream_calls": [ { "name": "order", "uri": "http://order.shop.svc:9090/", "...": "..." } ],
  "code": 200
}
```

| Alan | Kural |
|---|---|
| `uri` | Sunucuda gelen yol; `upstream_calls` içinde çağrılan tam adres (çağıran doldurur) |
| `type` | `HTTP` veya `gRPC` |
| `start_time` / `end_time` | `yyyy-MM-ddTHH:mm:ss.ffffff`, yerel saat |
| `duration` | Go `time.Duration` biçimi (`850µs`, `12.334ms`, `1.5s`) |
| `body`, `upstream_calls`, `error` | Boşsa alan yazılmaz |
| `code` | HTTP durum kodu veya gRPC durum kodu (0 = OK). Bağlantı / zaman aşımı hatasında -1 |

### gRPC sunucusu (`SERVER_TYPE=grpc`)

- Servis `chain.Chain/Call` ([`proto/chain.proto`](proto/chain.proto)); `Response` mesajı JSON cevabıyla alan alana aynıdır.
- Hata: gRPC durum kodu (`code`) + durum mesajında **JSON olarak tam cevap**. Çağıran mesaj `{` ile başlıyorsa
  ayrıştırır; böylece zincir ayrıntısı (hangi alt servisin neden düştüğü) gRPC kademesinden de geçer.
- Hazırlık kontrolü TCP (port 9090).

### İstemci davranışı

| | Kural | Neden |
|---|---|---|
| HTTP | Bağlantı havuzu (keep-alive), boşta bağlantı 60 sn, bağlantı kurma zaman aşımı 3 sn, proxy / yönlendirme yok; cevap gövdesi her zaman sonuna kadar okunur | Gerçek servislerdeki gibi bağlantı yeniden kullanımı; mesh'in bağlantı başı maliyeti (mTLS el sıkışması) adil ölçülür |
| gRPC | Hedef başına **tek kalıcı HTTP/2 bağlantısı**, istemci tarafı yük dengeleme yok, DNS bir kez çözülür | L4 ve L7 yük dengeleme farkı (ambient L4'te istekler replikalara dağılmaz) gözlenebilsin |
| İz | Gelen B3 başlıkları (`X-B3-TraceId`, `-SpanId`, `-ParentSpanId`, `-Sampled`) okunur, yoksa yeni iz başlatılır; her upstream çağrısına çocuk span kimliğiyle aktarılır (gRPC'de metadata, küçük harf) | Mesh'lerin (Envoy / Linkerd) span'leri uygulama span'leriyle aynı ize bağlanır |
| Zipkin | `TRACING_ZIPKIN` doluysa SERVER ve CLIENT span'leri Zipkin v2 JSON olarak gruplar halinde (200 span veya 1 sn) gönderilir; kuyruk 10 000, doluysa düşürülür | Trace gönderimi yükü etkilemesin |

### Kapanış

SIGTERM'de yeni bağlantı kabul edilmez, devam eden istekler en fazla 8 sn içinde tamamlanır, sonra süreç çıkar.
(Pod `terminationGracePeriodSeconds: 10`.) R03 / R05 gibi pod kaybı ve güncelleme testlerinde ölçülen hataların
uygulamadan değil mesh'ten geldiğinden emin olmak için gereklidir.

## Sözleşme testi

```bash
bin/smlab app conformance all      # tüm diller + diller arası karışık zincir
bin/smlab app conformance dotnet   # tek dil
```

Cluster gerekmez; Docker ağında `front (HTTP) → mid (gRPC) → leaf (HTTP)` zinciri kurulur ve şunlar sınanır:
cevap alanları ve biçimleri, gRPC kademesi, paralel upstream sırası, yol aktarımı, keep-alive, `/ready`,
B3 yayılımı ve Zipkin span'leri (HTTP ve gRPC üzerinden), HTTP / gRPC hata enjeksiyonu, gRPC hata ayrıntısının
taşınması, gecikme enjeksiyonu, istemci zaman aşımı, yapay işlem süresinin ortalaması ve SIGTERM'de istek boşaltma.
Birden fazla dil verilirse `go → dotnet → go` ve `dotnet → go → dotnet` karışık zincirleriyle tel uyumu da sınanır.

## Yeni dil eklemek

1. `apps/chainsvc/<dil>/` dizini ve içinde `Dockerfile` oluşturun. Derleme bağlamı `apps/chainsvc`'dir
   (`COPY proto/ ...` ile ortak sözleşmeye erişilir). gRPC kodunu `proto/chain.proto`'dan üretin.
2. İmaja `LABEL smlab.lang="<dil>" smlab.runtime="<çalışma zamanı ve kütüphane sürümleri>"` ekleyin; rapor ve
   `meta.json` bu etiketi gösterir. Servis 9090'da dinlemeli, root olmayan kullanıcıyla çalışmalıdır.
3. Yukarıdaki sözleşmeyi uygulayın. Çalışma zamanı ayarlarını o dilin tipik servis varsayımında bırakın
   (amaç kurumdaki gerçek servislerin davranışını temsil etmek).
4. `config.env` → `APP_LANGS` listesine ekleyin (ör. `go,dotnet,java`) ve
   `report/generate.py` → `LANG_NAMES` içine görünen adını yazın.
5. `bin/smlab app conformance <dil>` ve ardından `bin/smlab app conformance all` tümüyle geçmeli.
6. Cluster'da: `bin/smlab app use <dil>` → `bin/smlab verify`; ardından testler
   (`bin/smlab test run ...` veya `bin/smlab suite --langs <dil>`).

Testlerde, ortamda ve mesh yapılandırmasında değişiklik gerekmez.

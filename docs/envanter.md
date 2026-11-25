# Envanter

PoC'de kullanılan tüm bileşenler, sürümleri ve nerede çalıştıkları. Sürümler [`config.env`](../config.env)'de ve
imaj etiketlerinde sabitlenmiştir; her test koşusu kullandığı sürümleri `results/<koşu>/meta.json` → `versions`
alanına yazar ve rapordaki envanter tablosu buradan gelir. Aşağıdaki çalışan sürümler ortamın kurulu hâlinden
okunmuştur (25.11.2026).

## Ortam

| Bileşen | Sürüm / değer | Not |
|---|---|---|
| Host | Linux, 12 çekirdek, 62 GB RAM | Tüm cluster'lar tek host'ta; ortam boşta ~6.5 GB RAM |
| Docker Engine | 29.9 | |
| kind | v0.33.0 | node imajı `KIND_NODE_IMAGE` |
| Kubernetes | v1.37.0 (`kindest/node:v1.37.0`) | |
| kubectl / helm | v1.37.2 / v4.3.2 | |
| CNI / NetworkPolicy | kindnet `v20260820-69b56db7` (kube-network-policies dahili) | S02, P07 (none) |
| CoreDNS | v1.14.6 | `ext.test` ve `ext.test.local` bölgeleri `smlab setup` tarafından eklenir |
| ingress-nginx | chart 4.15.1, controller v1.15.1 | Tüm cluster'lar |
| Edge LB | `haproxy:3.0-alpine` | |
| Postgres / Redis (sml-data) | `postgres:16-alpine` / `redis:7-alpine` | |

## Cluster'lar ve yerleşim

| Cluster / container | Node | CPU (cpuset) | Bellek (boşta) | Çalışan |
|---|---|---|---|---|
| sml-app | control-plane | 7-8 | ~1.8 GB | ingress-nginx, mesh kontrol düzlemi, Prometheus agent, kube-state-metrics, CoreDNS |
| | worker (`smlab.io/role=app`, taint) | 0-3 | ~1 GB (Go zincir) | shop servis zinciri, test istemcileri, waypoint |
| | worker2 (`smlab.io/role=loadgen`, taint) | 4-6 | ~150 MB | k6 pod'ları |
| sml-dmz-a / sml-dmz-b | control-plane | 9-11 | ~0.8 GB | ingress-nginx |
| sml-data | control-plane | 9-11 | ~0.8 GB | Postgres, Redis, ingress-nginx (TCP) |
| sml-mgmt | control-plane | 9-11 | ~1.1 GB | Prometheus, Grafana, Tempo, ingress-nginx |
| sml-edge-lb | container | 9-11 | ~45 MB | HAProxy |
| sml-ext-allowed / -denied | container | 9-11 | ~4 MB | nginx (egress hedefleri, `EGRESS_*_IP`) |

Ayrıntı ve diyagram: [mimari.md](mimari.md#3-clusterlar-ve-yerleşim).

## Service mesh'ler

| Mesh | Sürüm | Kurulum kaynağı | Bileşenler |
|---|---|---|---|
| Istio | 1.31.4 (R05 başlangıç: 1.30.8) | Release tarball içindeki Helm chart'ları (`.tools/istio-<sürüm>/`), imajlar `docker.io/istio` | base, istiod, (ambient) istio-cni + ztunnel, waypoint (Envoy) |
| Linkerd | edge-26.11.2 (R05 başlangıç: edge-26.10.2) | `linkerd` CLI (`.tools/`) | CRD'ler, linkerd-destination, -identity, -proxy-injector, linkerd2-proxy |
| Gateway API CRD'leri | v1.6.1 (standard) | kubernetes-sigs/gateway-api | Istio 1.31 (v1.6.0 ile derlenmiş) ve Linkerd'in ortak sürümü |

Kimlik (PKI, `lib/pki.sh`, `.state/pki/`):

| Mesh | Kök | Ara CA |
|---|---|---|
| Istio | RSA 4096, 10 yıl | RSA 2048, `cacerts` secret |
| Linkerd | ECDSA P-256 trust anchor | ECDSA P-256 issuer, 1 yıl |

S08 testi aynı kökle yeni ara CA üretip yük altında rotasyon yapar.

## Gözlem (sml-mgmt, `observability` namespace)

| Bileşen | Chart / imaj | Erişim |
|---|---|---|
| Prometheus | prometheus-community/prometheus 29.47.2, `prometheus:v3.16.0` | https://prometheus.localtest.me:9443, cluster'lardan `<mgmt>:9090` (remote-write) |
| Grafana | grafana/grafana 10.5.15, `grafana:12.3.1` | https://grafana.localtest.me:9443 (admin / smlab) |
| Tempo | grafana/tempo 1.24.4, `tempo:2.9.0` | Zipkin `<mgmt>:9411`, OTLP `<mgmt>:4317`, sorgu Grafana üzerinden |
| Prometheus agent (sml-app) | aynı chart, `--agent` | 5 sn toplama; dış etiketler `cluster`, `mesh`, `lang` |
| kube-state-metrics (sml-app) | chart bağımlılığı, `v2.20.0` | requests / limits, pod durumu |

Port 9443, `HOST_MGMT_HTTPS_PORT` ile değiştirilebilir.

## Test uygulaması ve yardımcılar

| Bileşen | İmaj | Görev | Kullanan testler |
|---|---|---|---|
| chainsvc (Go) | `smlab/chainsvc-go:1.0.0` — Go 1.26.11, net/http, grpc-go 1.75.0; scratch, ~17 MB | 8 servislik zincir (HTTP / gRPC), gecikme ve hata enjeksiyonu, B3 / Zipkin | Tümü |
| chainsvc (.NET) | `smlab/chainsvc-dotnet:1.0.0` — .NET 10.0.15, ASP.NET Core Kestrel, Grpc.AspNetCore 2.85.0; Ubuntu chiseled, ~184 MB | Aynı sözleşme ([apps/chainsvc](../apps/chainsvc/README.md)) | Tümü |
| Derleme imajları | `golang:1.26.11-alpine`, `mcr.microsoft.com/dotnet/sdk:10.0.404`, `mcr.microsoft.com/dotnet/aspnet:10.0.15-noble-chiseled` | Docker içinde derleme (host'ta SDK gerekmez) | — |
| k6 | `grafana/k6:2.4.0` | Yük üretici. Bench'te pod (loadgen node'u, mesh içinde); P04'te host'ta container (sml-edge) | P01–P05, S08, R01–R05, O01, O02 |
| netshoot | `nicolaka/netshoot:v0.14` | Test istemcileri (curl, openssl, tcpdump, socat, dig, grpcurl); sözleşme testinde istemci ve Zipkin toplayıcısı | S01–S08, T01–T03, P07 |
| banner (socat) | netshoot | Server-first TCP sunucusu | T02 |
| Egress hedefleri | `nginx:1.27-alpine` (docker, sml-app ağı, `EGRESS_ALLOWED_IP` / `EGRESS_DENIED_IP`) | `allowed.ext.test` / `denied.ext.test` HTTPS | S07 |
| Data servisleri | sml-data'daki Postgres / Redis | Cluster dışı TCP trafiği | T02 |

## Rol bazında kaynak ölçümü

[`lib/resources.sh`](../lib/resources.sh), cAdvisor serilerini maliyet kalemlerine ayırır:

| Rol | Seçici | Anlamı |
|---|---|---|
| app | `namespace=shop, container=app` | Uygulama (dilden bağımsız konteyner adı) |
| sidecar | `namespace=shop, container=~istio-proxy\|linkerd-proxy` | Pod içi proxy |
| ztunnel | `istio-system, pod=~ztunnel-.*` | Ambient node proxy'si |
| waypoint | `shop, pod=~waypoint-.*` | Ambient L7 proxy'si |
| cni | `istio-system, pod=~istio-cni-node-.*` | Ambient yönlendirme ajanı |
| control | `istio-system` / `linkerd` (yukarıdakiler hariç) | Kontrol düzlemi |
| ingress | `ingress-nginx` | Bench girişi (+ proxy'si) |
| loadgen | `loadgen` pod cgroup'u | k6 (+ proxy'si) |
| node_app / node_loadgen / node_control | `id="/"` | Node toplamı. app + proxy dışında kalan kernel ağ işleme yükü buradan görünür |

Tüm seriler `cluster="sml-app"` ve test penceresiyle filtrelenir; `mesh` ve `lang` dış etiketleri Grafana'da
profil / dil ayrımı için kullanılır.

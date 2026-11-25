# Mimari

Bu doküman PoC ortamının nasıl kurgulandığını anlatır: zone'lar ve cluster'lar, hangi bileşenin nerede
çalıştığı, servislerin birbirleriyle nasıl konuştuğu, mesh'lerin trafiğe nereden girdiği, gözlem verisinin
akışı ve testlerin hangi sırayla ilerlediği. Kurulum ve kullanım için: [kullanim-kilavuzu.md](kullanim-kilavuzu.md).

## 1. Yaklaşım

- Prod benzeri zone'lara ayrılmış bir ortam tek host üzerinde kurulur: her zone ayrı bir Docker network'ü,
  her cluster bir [kind](https://kind.sigs.k8s.io/) cluster'ı.
- Mesh'ler yalnızca **bench cluster'ına (`sml-app`)** kurulur. Diğer cluster'lar mesh'siz kalır ve gerçekçi bir
  giriş yolu (edge LB → DMZ), veri katmanı ve gözlem altyapısı sağlar.
- Aynı servis zinciri, aynı yük ve aynı testler 5 mesh profilinde koşulur:

  | Profil | Veri düzlemi |
  |---|---|
  | `none` | Mesh yok (referans ölçüm) |
  | `istio-l4` | Istio ambient: node başına ztunnel (L4, mTLS / HBONE) |
  | `istio-l7` | Istio ambient + shop namespace'i için waypoint (Envoy, L7) |
  | `istio-sidecar` | Istio: her pod'a Envoy sidecar |
  | `linkerd` | Linkerd: her pod'a linkerd2-proxy |

- Servis zinciri (`chainsvc`) birden fazla dilde aynı sözleşmeyle uygulanır (şu an Go ve .NET 10). Her mesh profili
  her dil için ayrı ölçülür; böylece hem mesh'ler hem de mesh etkisinin dile göre değişimi kıyaslanır.

## 2. Topoloji

```
                         host (127.0.0.1)
          :443 / :80  ─────────┐            ┌───── :9443 / :9080 (Grafana, Prometheus)
                               │            │
 sml-edge   172.29.5.0/24  ┌───▼──────────┐ │
 ("internet")              │ sml-edge-lb  │ │   HAProxy: L4 round-robin, sağlık kontrolü,
                           │ (container)  │ │   istemci IP'si PROXY protocol ile
                           └──┬────────┬──┘ │
 sml-dmz    172.29.10.0/24 ┌──▼─────┐ ┌▼───────┐ │
                           │sml-dmz-a│ │sml-dmz-b│  ingress-nginx: TLS sonlandırma, edge kuralları,
                           └──┬─────┘ └┬───────┘ │   /admin whitelisting (S05)
                              └────┬───┘         │
 sml-app    172.29.20.0/24  ┌──────▼──────────────────────────────┐   ┌───────────────────────┐
                            │ sml-app  (BENCH)                    │   │ sml-ext-allowed  .250 │ egress
                            │  mesh + test servis zinciri + k6    │──►│ sml-ext-denied   .251 │ hedefleri (S07)
                            └──────┬───────────────────┬──────────┘   └───────────────────────┘
                                   │ TCP 5432 / 6379   │ remote-write :9090, Zipkin :9411
 sml-data   172.29.30.0/24  ┌──────▼──────────┐ ┌──────▼─────────────────────────────┐
                            │ sml-data        │ │ sml-mgmt                           │  sml-mgmt
                            │ Postgres, Redis │ │ Prometheus, Grafana, Tempo         │◄─ 172.29.40.0/24
                            └─────────────────┘ │ (sml-dmz / sml-app / sml-data'ya   │   (+ diğer zone'lara
                                                │  da bağlı)                         │    bağlı)
                                                └────────────────────────────────────┘
```

Host portları `config.env` → `HOST_*_PORT` ile değiştirilebilir (varsayılanlar yukarıdaki gibi).
`*.localtest.me` herkese açık DNS'te 127.0.0.1'e çözülür; hosts dosyası gerekmez.

### Zone'lar ve segmentasyon

Docker farklı bridge network'leri arasında trafiğe izin vermez; bu yüzden her network firewall'lı bir segment gibi
davranır. Bir node başka bir zone'a ancak o network'e ayrıca bağlanırsa erişir (`env/up.sh` → `attach_networks`).

| Bileşen | Network'ler | Erişebildiği |
|---|---|---|
| sml-edge-lb | sml-edge, sml-dmz | DMZ ingress'leri |
| sml-dmz-a / sml-dmz-b | sml-dmz, sml-app | sml-app ingress'i |
| sml-app (3 node) | sml-app, sml-data | data ingress'i, egress hedefleri, mgmt (sml-app üzerinden) |
| sml-data | sml-data | — |
| sml-mgmt | sml-mgmt, sml-dmz, sml-app, sml-data | tüm API server'lar, gözlem verisi alıcısı |

`bin/smlab env verify` bu kuralları sınar: izinli yollar açık, `edge LB → app`, `dmz → data`, `data → app` kapalı olmalıdır.

Cluster'lar arası adresleme: karşı cluster'ın ingress'i yerel bir **selector'sız Service + EndpointSlice** ile temsil
edilir (IP'ler `docker inspect` ile bulunur). Örnek: DMZ'deki `edge/app-ingress` → sml-app node'unun `:80`'i;
sml-app'teki `shop/postgres` → sml-data node'unun `:5432`'si (data ingress-nginx'i TCP olarak Postgres'e iletir).
Uygulamalar yalnızca küme içi adları bilir (`postgres.shop.svc`).

## 3. Cluster'lar ve yerleşim

| Cluster | Node | CPU (cpuset) | Çalışan |
|---|---|---|---|
| **sml-app** | control-plane | `CPUSET_CONTROL` (7-8) | ingress-nginx, mesh kontrol düzlemi (istiod / linkerd), waypoint dışı mesh bileşenleri, Prometheus agent, kube-state-metrics, CoreDNS |
| | worker (`smlab.io/role=app`, taint) | `CPUSET_APP` (0-3) | shop servis zinciri, test istemcileri, waypoint (istio-l7) |
| | worker2 (`smlab.io/role=loadgen`, taint) | `CPUSET_LOADGEN` (4-6) | k6 yük üretici pod'ları |
| sml-dmz-a, sml-dmz-b | control-plane | `CPUSET_OTHER` (9-11) | ingress-nginx (TLS, edge kuralları) |
| sml-data | control-plane | `CPUSET_OTHER` | Postgres 16, Redis 7, ingress-nginx (TCP 5432/6379) |
| sml-mgmt | control-plane | `CPUSET_OTHER` | Prometheus (alıcı), Grafana, Tempo, ingress-nginx |
| sml-edge-lb, egress hedefleri | (container) | `CPUSET_OTHER` | HAProxy, 2 x nginx |

DaemonSet'ler (kube-proxy, kindnet, ztunnel, istio-cni) her node'da çalışır. CPU sabitleme ve taint'ler
`smlab setup` ile uygulanır; yük üretici ölçülen servislerle CPU paylaşmaz, kontrol düzlemi de ölçüm çekirdeklerinden
ayrıdır.

```
 sml-app
 ┌────────────────────────────┬─────────────────────────────────┬──────────────────────────┐
 │ control-plane  CPU 7-8     │ worker  CPU 0-3  (app)          │ worker2  CPU 4-6 (loadgen)│
 │                            │                                 │                          │
 │ ingress-nginx ─────────────┼─► shop: gateway ... ledger (x2) │ loadgen: k6-<test>       │
 │ istiod / linkerd-*         │    probe-gateway, probe-rogue   │   └─► gateway.shop:9090  │
 │ prom-agent, kube-state-m.  │    banner (socat)               │                          │
 │ CoreDNS (ext.test)         │ outside: probe-outside (mesh'siz)│                          │
 │                            │ waypoint (yalnız istio-l7)      │                          │
 │ ztunnel / istio-cni (her node, yalnız istio-l4 / istio-l7)                               │
 └──────────────────────────────────────────────────────────────────────────────────────────┘
```

## 4. Servis zinciri (shop)

Tek kaynak [`apps/shop/services.tsv`](../apps/shop/services.tsv); [`render.sh`](../apps/shop/render.sh) manifest'leri üretir.

```
  ingress-nginx / k6
        │ HTTP/1.1
        ▼
     gateway ──► order ──┬──► inventory ──► pricing ──► catalog          (HTTP/1.1, keep-alive)
                         │
                         └──► payment ══gRPC══► fraud ──► ledger           (gRPC: tek kalıcı HTTP/2 bağlantısı)
                              (order iki dalı paralel çağırır: UPSTREAM_WORKERS=2)
```

| Servis | Protokol | Çağırdığı | Replika | Kimlik (ServiceAccount) |
|---|---|---|---|---|
| gateway | HTTP | order | 2 | gateway |
| order | HTTP | inventory + payment (paralel) | 2 | order |
| inventory | HTTP | pricing | 2 | inventory |
| pricing | HTTP | catalog | 2 | pricing |
| catalog | HTTP | — | 2 | catalog |
| payment | HTTP | fraud (gRPC) | 2 | payment |
| fraud | **gRPC** | ledger | 2 | fraud |
| ledger | HTTP | — | 2 | ledger |

- 8 servis × 2 replika = **16 uygulama pod'u** (sml-app worker). Derinlik 5, bir giriş isteği zincirde 8 servis isteği üretir.
- Her servis yapay 1–5 ms işlem süresi uygular (p50 1 ms, p90 2 ms, p99 5 ms; `SVC_TIMING_*`).
- Uygulama konteynerinin adı her dilde `app`, imajı aktif dilin chainsvc imajıdır; pod'lar `smlab.io/lang=<dil>` etiketi taşır.
- Davranış sözleşmesi: [`apps/chainsvc/README.md`](../apps/chainsvc/README.md).

Diğer bileşenler:

| Bileşen | Yer | Görev | Kullanan testler |
|---|---|---|---|
| `probe-gateway` | shop, SA gateway, `shop.role=gateway` | İzinli çağıran (netshoot, `kubectl exec` ile) | S01–S04, S07, S08, T01, T02, P01, O01, R04, R05, doğrulama |
| `probe-rogue` | shop, SA rogue | Yetkisiz servis | S02–S04, S06, P07 |
| `probe-outside` | outside (mesh dışı), `shop.role=gateway` etiketi | Etiket taklidi ve mesh atlatma denemesi | S01–S03, S06, S08, T03 |
| `banner` | shop, port 7000 | Server-first TCP (bağlanınca önce sunucu yazar) | T02 |
| `postgres`, `redis` | shop (selector'sız) → sml-data | Mesh içinden cluster dışı TCP | T02 |
| `k6-<test>` | loadgen (worker2), mesh içinde | Yük üretici, sonuçları mgmt Prometheus'a da yazar | P01–P03, P05, R01–R05, S08, O01, O02 |
| Egress hedefleri | Docker container, sml-app ağında | `allowed.ext.test` / `denied.ext.test` (HTTPS), CoreDNS'te tanımlı | S07 |

## 5. İletişim

| Kaynak → hedef | Protokol / port | Not |
|---|---|---|
| host → edge LB | TCP 443 (`HOST_HTTPS_PORT`) | `https://shop.localtest.me` |
| edge LB → DMZ ingress | TCP 443 + PROXY protocol | TLS DMZ'de sonlanır; sağlık kontrolü `:80/healthz` |
| DMZ ingress → sml-app ingress | HTTP 80 | `Host: shop.localtest.me`, istemci IP'si `X-Forwarded-For` |
| sml-app ingress → gateway | HTTP 9090 | `service-upstream: true`: mesh'li profillerde Service IP'sine gider (proxy yönlendirmesi için) |
| servis → servis | HTTP/1.1 9090, keep-alive havuzu | `appProtocol: http` |
| payment → fraud | gRPC (h2c) 9090, tek kalıcı bağlantı | `appProtocol: kubernetes.io/h2c` |
| shop → postgres / redis | TCP 5432 / 6379 → sml-data ingress | `appProtocol: tcp` |
| k6 → gateway | HTTP 9090 | Cluster içi (P04 hariç: P04 host'ta, edge LB üzerinden) |
| prom-agent / k6 → mgmt | Prometheus remote-write 9090 | selector'sız Service → mgmt node IP → mgmt ingress TCP |
| chainsvc / mesh → Tempo | Zipkin 9411, OTLP 4317 | Yalnızca O01 sırasında açık |

### Mesh'lerin trafiğe girdiği yer

Bütün mesh'li profillerde mesh içi trafik **zorunlu mTLS**'tir (Istio `PeerAuthentication STRICT`, Linkerd
`default-inbound-policy=all-authenticated`) ve mesh dışından düz metin erişim reddedilir. Kimlik sertifikaları
mesh'in kendi CA'sından değil, `lib/pki.sh`'in ürettiği kök + ara CA'dan verilir (kurumsal CA'nın karşılığı).

```
 none            order ───────────────── HTTP ─────────────────► inventory

 istio-sidecar   order ► Envoy ═══════ mTLS (HTTP/2) ═══════► Envoy ► inventory        (her pod'da proxy, L7)

 linkerd         order ► linkerd2-proxy ═══ mTLS ═══► linkerd2-proxy ► inventory       (her pod'da proxy, L7)

 istio-l4        order ─► ztunnel(node) ═══ HBONE mTLS :15008 ═══► ztunnel(node) ─► inventory
                                                                                      (node başına proxy, yalnız L4)
 istio-l7        order ─► ztunnel ═══ HBONE ═══► waypoint (Envoy, L7) ═══ HBONE ═══► ztunnel ─► inventory
                                                  (shop namespace'i için tek waypoint)
```

- Sidecar / Linkerd: L7 politikalar (yol bazlı yetki, retry, fault injection, trafik bölme) her pod'un proxy'sinde uygulanır.
- `istio-l4`: yalnız kimlik ve L4 yetki; L7 özellikleri yoktur (testlerde `na` olarak raporlanır).
- `istio-l7`: L7 özellikleri waypoint'te; trafik hedef pod'a waypoint'ten gelir (bkz. S02 bulgusu).
- ingress-nginx ve k6 da mesh'e alınır (sidecar / Linkerd'de proxy enjeksiyonu, ambient'te namespace etiketi);
  böylece giriş → gateway kenarı da mTLS'tir.

## 6. Gözlem

```
 sml-app                                                    sml-mgmt
 ┌──────────────────────────────────────────┐               ┌─────────────────────────────────┐
 │ cAdvisor (kubelet), kube-state-metrics,  │  remote-write │ Prometheus (30 gün)             │
 │ mesh proxy'leri, kontrol düzlemi  ──► prom-agent ─────────► │   ▲            ▲               │
 │   (5 sn; dış etiketler cluster/mesh/lang)│      :9090    │   │ k6 metrikleri (test sırasında)│
 │ k6 ──────────────────────────────────────┼───────────────► │                                 │
 │ chainsvc + Envoy/Linkerd span'leri (O01) ┼── Zipkin 9411 ─► Tempo ◄── Grafana (pano: smlab) │
 └──────────────────────────────────────────┘               └─────────────────────────────────┘
```

- Testler ölçümlerini Prometheus'tan zaman penceresiyle sorgular (`lib/resources.sh`, `prom_query`); seriler
  `cluster`, `mesh` ve `lang` etiketleriyle ayrılır.
- Grafana panosu (`smlab — test izleme`) test sırasında canlı izleme içindir; rapor Prometheus'tan değil test
  sonuç dosyalarından üretilir.

## 7. Test akışı

### Tam değerlendirme (`smlab suite`)

```
 smlab suite --meshes none,istio-l4,istio-l7,istio-sidecar,linkerd --langs go,dotnet --profile full --repeat 3
   │
   for mesh in meshes:
   │  for dil in langs:
   │    ┌─ temiz kurulum (mesh use <mesh> --fresh) ─────────────────────────────────────────────┐
   │    │ 1. sml-app silinir, env/up.sh ile yeniden kurulur (DMZ / edge kayıtları güncellenir)   │
   │    │ 2. node yerleşimi + CPU sabitleme + taint'ler                                          │
   │    │ 3. Prometheus agent (mesh, lang etiketleri)                                            │
   │    │ 4. servis zinciri bu dilin imajıyla, egress hedefleri, CoreDNS                         │
   │    │ 5. mesh kurulumu (helm / linkerd CLI, PKI) → uygulama + ingress + k6 mesh'e alınır     │
   │    │ 6. ısınma yükü (APP_WARMUP_S, 50→200 RPS): JIT, bağlantı havuzları, proxy bağlantıları │
   │    │ 7. doğrulama: proxy'ler, mTLS zorunlu, zincir tam, uçtan uca, mesh metrikleri          │
   │    └────────────────────────────────────────────────────────────────────────────────────────┘
   │    test run <tüm testler> (sıra: P → S → T → O → R; R05 mesh'i yeniden kurduğu için en sonda)
   │
   └─► smlab report --session <oturum>  →  reports/<zaman>/{go,dotnet}/rapor.html + karsilastirma.html
```

Her (mesh, dil) çifti sıfırdan kurulmuş bench cluster'ında başlar: önceki mesh'ten kalıntı (CRD, iptables, webhook)
veya önceki testlerin yükünün bıraktığı durum kıyası etkilemez.

### Tek test koşusu (`smlab test run <ID>`)

```
 run_one(ID, tekrar)
   ├─ results/<zaman>_<ID>_<mesh>_<dil>_r<n>/meta.json   test tanımı, mesh, dil + imaj, sürümler, git commit
   ├─ ön kontrol: zincir sağlıklı mı? değilse shop yeniden başlatılır + ısınma (meta.json → precheck)
   ├─ tests/<ID>/run.sh  (alt kabukta; yardımcılar: check, metric, finding, na, k6_run, prom_query, on_exit ...)
   │     └─ politika uygula → yük / deneme → ölç → kontrol et
   ├─ on_exit temizlikleri (test hata verse de çalışır: politika, geçici deployment, ortam değişkeni)
   └─ result.json   durum (pass / fail / na / error), kontroller, metrikler, bulgular  +  log.txt, raw/
```

Testler mesh'e göre dallanır (ör. `istio-sidecar` için VirtualService, `linkerd` için HTTPRoute), dile göre
dallanmaz: dil yalnızca `APP_IMAGE`'i belirler. Test kataloğu: [test-senaryolari.md](test-senaryolari.md).

## 8. Dizin yapısı

```
bin/smlab                  tek giriş noktası (CLI)
config.env                 tüm ayarlar: sürümler, cluster / network / port, CPU yerleşimi, diller, prod varsayımları
env/                       test ortamı
  up.sh verify.sh down.sh    kur / doğrula / sil  (smlab env ...)
  kind/                      cluster tanımları (rol başına)
  ingress-nginx/             ortak + zone değerleri, args.sh (tüm kurulumlarda aynı helm argümanları)
  edge-lb/                   HAProxy yapılandırma şablonu
  workloads/                 DMZ girişi (shop.localtest.me), data servisleri (Postgres, Redis)
lib/                       common, app, mesh, observability, pki, policy, k6, resources, test, tools
apps/
  chainsvc/                  test servisi: sözleşme (README), proto, go/, dotnet/, conformance/
  shop/                      services.tsv (zincir tanımı) + render.sh
meshes/istio|linkerd/      mesh'e özel helm değerleri
observability/             Prometheus (mgmt + agent), Grafana, Tempo değerleri, Grafana panosu
tests/<ID>/                test.yaml (tanım) + run.sh (çalıştırıcı) + policies/ (mesh'e özel politikalar)
tests/k6/load.js           ortak yük script'i
report/                    generate.py (dil başına rapor), compare.py (diller arası kıyas), docs.py, scorecard.yaml, static.yaml
docs/                      bu dokümanlar
results/ reports/          test koşuları ve raporlar (git'te tutulur)
.state/ .tools/            üretilen dosyalar (PKI, sertifikalar, aktif mesh / dil) ve indirilen CLI'lar (git dışı)
```

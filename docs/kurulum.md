# Kurulum

Bu doküman `smlab setup` ve `smlab mesh use` adımlarının ne yaptığını, her kurulumdan sonra neyin nasıl doğrulandığını
ve kurulum sırasında tespit edilen konuları anlatır. Ortamın yapısı: [mimari.md](mimari.md) · günlük kullanım:
[kullanim-kilavuzu.md](kullanim-kilavuzu.md).

## Kurulum sırası

```bash
bin/smlab env up        # test ortamı (env/up.sh): network'ler, 5 kind cluster, ingress-nginx, data, DMZ, edge LB
bin/smlab tools         # istioctl (1.31.4, 1.30.8) ve linkerd CLI (edge-26.11.2, edge-26.10.2) -> .tools/
bin/smlab setup         # aşağıdaki adımlar
bin/smlab mesh use istio-l4 --fresh
```

### `env up` (env/up.sh)

1. Ön kontroller: araçlar, Docker, inotify limitleri, ingress-nginx Helm reposu.
2. Zone network'leri (`NET_*`, `NET_*_SUBNET`).
3. 5 kind cluster (`env/kind/<rol>.yaml`, node imajı `KIND_NODE_IMAGE`); her biri kendi zone'unda başlar, ek zone'lara
   `docker network connect` ile bağlanır.
4. ingress-nginx her cluster'da (`env/ingress-nginx/args.sh`: ortak + zone değerleri, güvenilen proxy aralığı
   config'den). DMZ cevaplarına `X-Dmz` başlığı eklenir.
5. sml-data: Postgres + Redis (`env/workloads/data`).
6. DMZ: `edge` namespace'i, TLS sertifikası (`.state/env/certs/`, self-signed `*.localtest.me`), `shop.localtest.me`
   kuralı, sml-app ingress'ini gösteren `app-ingress` Service + EndpointSlice.
7. Edge LB (HAProxy) container'ı, `.state/env/haproxy.cfg` (DMZ node IP'leriyle doldurulmuş şablon).

### `setup` (bin/smlab)

Her adım idempotenttir.

1. **Node yerleşimi ve CPU sabitleme** (`lib/app.sh: bench_nodes`)
   - `docker update --cpuset-cpus`: sml-app worker `CPUSET_APP`, worker2 `CPUSET_LOADGEN`, control-plane
     `CPUSET_CONTROL`; diğer cluster'lar, edge LB ve egress hedefleri `CPUSET_OTHER`.
   - Worker'lara taint (`smlab.io/role=app|loadgen:NoSchedule`), control-plane taint'i kaldırılır: test dışı her şey
     control-plane'de çalışır.
2. **Gözlem, mgmt** (`lib/observability.sh: obs_install_mgmt`)
   - Prometheus (remote-write alıcısı, 30 gün saklama), Tempo (Zipkin + OTLP), Grafana (pano: `smlab — test izleme`).
   - mgmt ingress-nginx'ine TCP 9090 / 9411 / 4317 portları.
3. **Gözlem, bench** (`obs_install_agent`)
   - Prometheus **agent** modunda; 5 sn aralıkla cAdvisor, kube-state-metrics, mesh proxy'leri ve kontrol düzlemi
     toplanır, mgmt'ye yazılır. Her seriye `cluster`, `mesh`, `lang` dış etiketleri eklenir.
   - Bench'ten mgmt'ye köprü: selector'sız `prometheus` / `tempo` Service'leri → mgmt node'unun sml-app IP'si.
4. **Servis zinciri** (`lib/app.sh: app_deploy`)
   - Aktif dilin chainsvc imajı derlenir (`apps/chainsvc/<dil>/Dockerfile`) ve kind node'larına yüklenir.
   - shop namespace'i (8 servis, test istemcileri, banner, data servisleri), outside ve loadgen namespace'leri,
     bench ingress kuralı, egress hedefleri ve CoreDNS kayıtları (`ext.test`).
   - Isınma yükü (`APP_WARMUP_S`, varsayılan 60 sn, 50 → 200 RPS). Zincirin pod'ları yeniden oluşturulduğu her
     yerde (setup, `app use`, mesh'e alma, test ön kontrolünde yeniden başlatma) uygulanır.
5. **Doğrulama** (`smlab verify`, aşağıda).

Servis zinciri, istemciler ve iletişim: [mimari.md](mimari.md#4-servis-zinciri-shop).

### Mesh profilleri

`bin/smlab mesh use <profil> [--fresh]` (`lib/mesh.sh`):

| Profil | Kurulum | Uygulamayı mesh'e alma |
|---|---|---|
| `none` | — | — |
| `istio-l4` | Helm: base, istiod (`profile=ambient`), istio-cni, ztunnel | `istio.io/dataplane-mode=ambient` (shop, loadgen, ingress-nginx), PeerAuthentication STRICT |
| `istio-l7` | ambient ile aynı | + `istioctl waypoint apply -n shop --enroll-namespace` |
| `istio-sidecar` | Helm: base, istiod | `istio-injection=enabled`, ingress-nginx pod'una sidecar (yalnız giden trafik), STRICT |
| `linkerd` | `linkerd install --crds` + `linkerd install` (kendi CA'mızla) | `linkerd.io/inject=enabled`, `default-inbound-policy=all-authenticated`, ingress-nginx `inject: ingress` |

Ortak ayarlar:
- **Gateway API CRD'leri:** v1.6.1, standard kanal.
- **Kimlik:** mesh'ler kendi CA'sını üretmez; `lib/pki.sh` kök + ara CA verir (`.state/pki/`). Istio: RSA, `cacerts` secret. Linkerd: ECDSA P-256 trust anchor + issuer. Bu, prod'da kurumsal CA (ör. Vault) kullanımının test ortamındaki karşılığıdır.
- **Varsayılandan sapmalar:** tek replika, autoscale kapalı, erişim logu ve tracing kapalı. Gerekçeleri [`meshes/istio/istiod-values.yaml`](../meshes/istio/istiod-values.yaml) ve [`meshes/linkerd/values.yaml`](../meshes/linkerd/values.yaml) içinde.
- **Kaynak istekleri** (proxy requests) mesh varsayılanında bırakıldı; raporda "ayrılan kapasite" olarak ayrıca gösterilir.
- **`--fresh`:** bench cluster'ını silip yeniden kurar, servis zincirini aktif dille dağıtır (~5 dk). Adil kıyas için `suite` her mesh x dil çiftinde bunu kullanır.

## Doğrulama: neyi, nasıl kontrol ediyoruz

`bin/smlab verify` her kurulumdan, `mesh use` ve `app use` sonrasında otomatik çalışır.

| Kontrol | Yöntem |
|---|---|
| Prometheus hazır | `/-/ready` |
| Remote-write çalışıyor | mgmt'de `count(up{cluster="sml-app"}) > 0` |
| cAdvisor / kube-state-metrics | ilgili seriler mevcut |
| Grafana + Tempo datasource | `/api/health`, datasource health |
| Zincir tam | probe-gateway → gateway: 8 servisin hepsi cevap veriyor (HTTP 200 / gRPC OK) |
| Uçtan uca | `https://shop.localtest.me` → edge LB → DMZ → sml-app → gateway |
| Server-first TCP | banner:7000 |
| Data erişimi | shop → postgres (sml-data) |
| Proxy'ler | sidecar / Linkerd: her shop pod'unda proxy; ambient: `ambient.istio.io/redirection=enabled` + ztunnel'de HBONE |
| Waypoint | istio-l7: waypoint var, trafik `reporter="waypoint"` ile görünüyor |
| mTLS zorunlu | mesh dışı namespace'ten düz HTTP **reddedilmeli** |
| Mesh metrikleri | `istio_requests_total` / `istio_tcp_connections_opened_total` / Linkerd `request_total` mgmt'de mevcut |

Ortamın kendisi ayrıca `bin/smlab env verify` ile doğrulanır (edge → DMZ → app yolu, data erişimi, segmentasyon,
mgmt → API server'lar). Test uygulaması sözleşmesi `bin/smlab app conformance` ile doğrulanır.

## Kurulum sırasında tespit edilenler

Mesh'lerle ilgili bu tespitler yapılandırmaya yansıtılmıştır ve rapora da girecek niteliktedir.

1. **Istio 1.31 sidecar'ı native sidecar olarak ekliyor.** `istio-proxy` init container olarak, `restartPolicy: Always` ile geliyor. Pod yaşam döngüsü (Job'lar, başlatma sırası) klasik sidecar'dan farklıdır.
2. **Linkerd'de `all-authenticated` politikası proxy'nin admin portunu da (4191) kapsıyor.** Mesh dışındaki
   Prometheus metrik toplayamıyor (`up=0`). Admin portu için bir `Server` tanımlamak ise Linkerd'ün kubelet
   probe'larına verdiği otomatik izni kaldırıyor: native sidecar olarak çalışan proxy'nin kendi startup probe'u
   (`/ready`) 403 alıyor ve **yeni pod'lar hiç hazır olmuyor**. Yol bazında (HTTPRoute) izin de admin sunucusunda
   uygulanmıyor. Çözüm Linkerd'ün kendi önerisi: Prometheus'u da mesh'e almak (`observability` namespace'i
   inject). Metrikler mTLS ile kimlikli toplanır ve admin portuna politika gerekmez.
3. **Linkerd, Service'teki `appProtocol: grpc` değerini tanımıyor.** gRPC trafiği opak TCP taşınıyor; L7 metrikler ve gRPC tipinde `Server` yetkisi çalışmıyor (bağlantı reddi). Kubernetes standardı `appProtocol: kubernetes.io/h2c` ile düzeldi. Prod'da protokol ipuçları mesh'e göre standartlaştırılmalı.
4. **Linkerd `RequestMirror` filtresini desteklemiyor.** Politika denetleyicisi logu: `RequestMirror filter is not supported`.
5. **Test ortamı DNS sorunu (mesh'ten bağımsız).** kind node'larının `resolv.conf`'u docker ağ geçidini (172.29.x.1) gösteriyor; orada DNS yok. Cluster içinden internet adları çözülemiyor, `search local` yüzünden her dış sorgu önce zaman aşımına uğruyor. `smlab setup` CoreDNS'e `ext.test` bölgesini ve `ext.test.local` için hızlı NXDOMAIN ekler (genel bir `local:53` bloğu `cluster.local`'ı da yakalar ve cluster DNS'ini bozar; geliştirme sırasında yaşandı). S07 internete bağımlı değildir.
6. **Istio Helm chart'ları.** Istio 1.31 chart'ları klasik Helm deposunda ve OCI registry'de yok (en yeni 1.30.8). Kurulum release tarball'ının içindeki chart'larla yapılır; imajlar docker.io'da mevcut.
7. **Grafana / Tempo Helm chart'ları "deprecated" uyarısı veriyor.** Topluluk depolarına taşınıyorlar. Lab için sorun değil; prod'da güncel chart kaynağı seçilmeli.

8. **Linkerd'ün varsayılan `clusterNetworks` değeri tüm özel IP bloklarını kapsıyor** (10/8, 172.16/12, 192.168/16).
   Bu yüzden cluster dışındaki ama özel IP'li hedefler (test ortamında NET_APP_SUBNET; prod'da kurum içi veri merkezi ağları)
   "cluster içi" sayılıyor ve `EgressNetwork` reddediliyor ("networks overlap with clusterNetworks"). Kural kabul
   edilmediği halde izinli hedefe giden trafik de kesildi. Linkerd bu yüzden gerçek pod/servis aralıklarıyla
   kurar (`meshes/linkerd/values.yaml`). Prod'da da aralıklar açıkça verilmelidir.

### Test uygulamasıyla ilgili tespitler

Bunlar mesh'le değil ölçüm aracıyla ilgilidir; sonuçların doğru yorumlanması için önemlidir.

9. **Hazır test uygulaması (fake-service) kullanılamadı; yerine `chainsvc` yazıldı.** fake-service (v0.26.2, son
   sürüm Ocak 2024) keep-alive açıkken, upstream'den hata aldığı bir istekten sonra kalıcı bağlantıya bozuk HTTP
   cevabı yazıyor (proxy logu: `invalid HTTP version parsed`); servis yeniden başlatılana kadar her istek 500 dönüyor.
   Keep-alive kapatılınca da her istek yeni bağlantı açtığı için sabit yükte gecikme sürekli artıyor. İkisi de mesh
   kıyasını bozduğu için aynı ortam değişkenlerini ve aynı JSON cevap biçimini kullanan `chainsvc` yazıldı
   ([sözleşme](../apps/chainsvc/README.md)). Ek önlem: her testten önce zincir sağlık kontrolü yapılır; bozuksa shop
   yeniden başlatılır ve koşu kaydına not düşülür (`meta.json` → `precheck`).
10. **Zamanlayıcı çözünürlüğü dile göre ters yönde sapıyor.** Yapay 1–5 ms işlem süresinde (hedef ortalama 1.215 ms)
    Go `time.Sleep` ms altı beklemeleri yukarı yuvarlıyor (gerçekleşen ~1.78 ms, +0.56 ms), .NET `Task.Delay` ise
    aşağı (~0.82 ms, −0.38 ms). Düzeltilmeseydi zincirde (8 hop) diller arasında ~3–4 ms'lik yapay bir gecikme farkı
    oluşur ve dil kıyası yanıltıcı olurdu. Sözleşmeye "bekleme ms çözünürlüğünde, kesir olasılıksal yuvarlanır" kuralı
    eklendi; iki dilde de gerçekleşen ortalama ~1.37 ms (`smlab app conformance` bunu ölçer ve sınar).
11. **SIGTERM'de istek boşaltma Go'da eksikti.** `http.Server.Shutdown()` başlar başlamaz `Serve()` döndüğü için süreç,
    devam eden istekleri beklemeden çıkıyordu (pod silinirken o anki istekler kesiliyordu). Ana akış artık kapanışın
    tamamlanmasını bekliyor (gRPC'de `GracefulStop`, en fazla 8 sn). Pod kaybı ve güncelleme testlerinde (R03, R05)
    ölçülen hataların mesh'ten geldiğinden emin olmak için gerekli; sözleşme testi her dilde sınar.
12. **.NET soğuk başlangıcı ilk ölçümleri bozuyor.** Pod'lar yeni oluşturulduktan hemen sonra 100 RPS'de .NET zincirinde
    p50 ~570 ms, p99 ~10 sn ve %3 hata görüldü (JIT ile derleme ve boş bağlantı havuzları); 60 sn ısınmadan sonra aynı
    yükte p50 ~17 ms, hata yok. Go'da JIT olmadığı için etki yok. Isınma olmadan her yeniden dağıtımdan sonraki ilk test
    .NET'i haksız biçimde cezalandırırdı; bu yüzden tüm dillere aynı ısınma uygulanır. Soğuk başlangıcın kendisi gerçek
    bir dil özelliğidir ve yeni pod oluşturan testlerde (P06 pod başlangıcı, R03 pod kaybı, R05 güncelleme) ölçülür.
    Test içinde ortam değişkeni değiştirip pod'ları yeniden oluşturan ve ardından gecikme / hata ölçen testlerde
    (R01, R02) aynı sebeple kısa bir ısınma (`test_warmup`, `TEST_WARMUP_S`) eklendi; testlerdeki tek dil kaynaklı değişiklik budur.
13. **.NET'te Server GC varsayılanı doğru seçim.** Aynı yükte workstation GC (`DOTNET_gcServer=0`) belirgin biçimde
    kötü sonuç verdi (ısınmış p99 ~670 ms, Server GC ile ~110 ms); ASP.NET Core varsayılanı (Server GC) korunmuştur.

Sorun giderme: [kullanim-kilavuzu.md](kullanim-kilavuzu.md#12-sık-karşılaşılanlar).

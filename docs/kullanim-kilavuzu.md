# Kullanım kılavuzu

Ortamın sıfırdan kurulması, mesh ve uygulama dili seçimi, testlerin (tek tek veya tamamı) çalıştırılması,
sonuçların incelenmesi ve raporun üretilmesi. Ortamın yapısı ve test akışı: [mimari.md](mimari.md) ·
kurulumun ayrıntıları ve doğrulamalar: [kurulum.md](kurulum.md) · testlerin ne ölçtüğü: [test-senaryolari.md](test-senaryolari.md).

Tüm komutlar repo kökünden çalıştırılır: `bin/smlab <komut>` (`bin/smlab help` tüm komutları listeler).

## 1. Gereksinimler

**Host**

| | Öneri | Not |
|---|---|---|
| İşletim sistemi | Linux (x86_64) | CPU sabitleme (`docker update --cpuset-cpus`) ve kind node'ları için. Değerlendirme Ubuntu'da yapıldı |
| CPU | 12 çekirdek | `config.env` → `CPUSET_*` 12 çekirdeğe göre; daha az çekirdekte değerleri küçültün |
| RAM | 32 GB (62 GB ile doğrulandı) | Ortam boşta ~6.5 GB; yük testleri, P07 (ölçek) ve .NET zinciri ek bellek ister |
| Disk | 30 GB boş | kind node imajı, mesh / uygulama imajları, Prometheus verisi |
| Ağ | İnternet erişimi | İlk kurulumda imajlar, Helm chart'ları ve mesh CLI'ları indirilir |

Host üzerinde ölçüm sırasında başka yoğun iş yükü çalışmamalıdır (sonuçların tekrarlanabilirliği için).

**Araçlar** (PATH'te olmalı)

| Araç | Doğrulanan sürüm | Kullanım |
|---|---|---|
| Docker Engine | 29.x | kind node'ları, edge LB, imaj derleme (Go ve .NET derlemesi Docker içinde yapılır; host'ta Go / .NET SDK gerekmez) |
| kind | v0.33.0 | cluster'lar |
| kubectl | v1.37 | |
| helm | v4.3 | ingress-nginx, Istio, gözlem chart'ları |
| jq, curl, openssl | | test çerçevesi, sertifikalar |
| python3 + PyYAML | 3.12 | test kataloğu, rapor (`pip install pyyaml` veya `apt install python3-yaml`) |

istioctl ve linkerd CLI'ları gerekmez: `bin/smlab tools` doğru sürümleri `.tools/` altına indirir.

**Kontrol**

```bash
docker info >/dev/null && kind version && kubectl version --client && helm version --short && jq --version \
  && python3 -c 'import yaml; print("pyyaml ok")'
```

## 2. İlk kurulum

```bash
git clone <repo> service-mesh-lab && cd service-mesh-lab

bin/smlab env up          # 1) test ortamı: network'ler, 5 kind cluster, ingress-nginx, data, DMZ, edge LB   (~10 dk)
bin/smlab env verify      # 2) ortam doğrulaması: edge -> DMZ -> app yolu, data erişimi, segmentasyon, mgmt
bin/smlab tools           # 3) istioctl 1.31.4 / 1.30.8, linkerd edge-26.11.2 / edge-26.10.2 -> .tools/
bin/smlab setup           # 4) CPU sabitleme, gözlem (mgmt + agent), servis zinciri (Go), doğrulama   (~5 dk)
```

`setup` sonunda `Doğrulama tamam (aktif mesh: none, dil: go)` görülmelidir. Ardından:

| Adres | Ne |
|---|---|
| https://shop.localtest.me | Servis zinciri, internet yolu (edge LB → DMZ → sml-app → gateway). Self-signed sertifika: `curl -k` |
| https://grafana.localtest.me:9443 | Grafana (admin / smlab), pano: `smlab — test izleme` |
| https://prometheus.localtest.me:9443 | Prometheus |
| http://127.0.0.1:9404 | Edge LB istatistikleri |

kubectl context'leri: `kind-sml-app` (bench), `kind-sml-mgmt`, `kind-sml-data`, `kind-sml-dmz-a`, `kind-sml-dmz-b`.

**Portlar doluysa** (makinede 80/443 başka bir servis tarafından kullanılıyorsa) repo kökünde `config.local.env`
oluşturup `env up`'tan önce değiştirin; tüm komutlar ve testler bu değerleri kullanır:

```bash
# config.local.env (git dışı)
HOST_HTTP_PORT=18080
HOST_HTTPS_PORT=18443
HOST_LB_STATS_PORT=19404
HOST_MGMT_HTTP_PORT=19080
HOST_MGMT_HTTPS_PORT=19443
```

## 3. Test uygulamasının dili

Servis zinciri `chainsvc`'nin Go veya .NET uygulamasıyla çalışır. Testler ve mesh yapılandırması dilden bağımsızdır.

```bash
bin/smlab app list                     # diller, aktif dil, imajlar ve çalışma zamanı sürümleri
bin/smlab app use dotnet               # zinciri .NET imajına geçir (mesh değişmez) + doğrulama
bin/smlab app use go
bin/smlab app conformance all          # dil uygulamalarının sözleşme testi (Docker, cluster gerekmez, ~3 dk)
```

Aktif dil `.state/lang` dosyasında tutulur; her test koşusu dili `meta.json` → `app.lang` alanına ve sonuç
dizininin adına yazar. Yeni dil eklemek: [apps/chainsvc/README.md](../apps/chainsvc/README.md#yeni-dil-eklemek).

## 4. Mesh profili seçmek

```bash
bin/smlab mesh list                          # profiller ve aktif olan
bin/smlab mesh use istio-sidecar --fresh     # temiz bench cluster'ında kur (ölçüm için, ~8 dk)
bin/smlab mesh use linkerd                   # mevcut cluster'da değiştir (~3 dk, hızlı deneme için)
bin/smlab mesh verify                        # aktif mesh'i doğrula
bin/smlab mesh status                        # mesh bileşenleri
```

| Profil | Açıklama |
|---|---|
| `none` | Mesh yok. Referans ölçüm |
| `istio-l4` | Istio ambient, yalnız L4 (node başına ztunnel) |
| `istio-l7` | Istio ambient + shop için waypoint (L7) |
| `istio-sidecar` | Istio klasik sidecar |
| `linkerd` | Linkerd (edge) |

`--fresh` bench cluster'ını (`sml-app`) silip yeniden kurar, aktif dille servis zincirini yeniden dağıtır ve mesh'i
kurar. Önceki mesh'ten kalıntı (CRD, iptables kuralı, webhook) olmaz; rapora girecek ölçümler için her zaman
`--fresh` kullanın.

## 5. Test çalıştırmak

Testler **aktif mesh ve aktif dil** ile koşar.

```bash
bin/smlab test list                          # 26 test, kategori, desteklenen mesh'ler
bin/smlab test run P01                       # tek test, quick profil
bin/smlab test run P01 P05 S03               # birkaç test
bin/smlab test run all                       # hepsi (sıra: P, S, T, O, R; R05 en sonda)
bin/smlab test run P01 --profile full        # uzun profil (rapor için)
bin/smlab test run P01 --repeat 3            # 3 tekrar (raporda medyan + min…max)
SESSION=deneme-1 bin/smlab test run S01      # koşuyu bir oturuma bağla (rapor oturum bazında filtreler)
```

| Profil | Süre (bir mesh, bir dil, tüm testler) | Kullanım |
|---|---|---|
| `quick` | ~45 dk | Kurulum doğrulaması, deneme, geliştirme |
| `full` | ~2.5 saat | Rapor |

> **R05** (mesh güncellemesi) mesh'i bir önceki sürümle yeniden kurup hedef sürüme yükseltir. Tek başına
> çalıştırdıktan sonra başka testlere geçmeden `bin/smlab mesh use <profil> --fresh` önerilir.

Bir koşu sırasında ilerleme terminalde ve Grafana panosunda izlenir. Testler istenildiği sırayla, istenildiği
kadar yeniden çalıştırılabilir; her koşu ayrı dizine yazılır, eskilerin üzerine yazılmaz.

## 6. Tam değerlendirme (tüm mesh'ler × tüm diller × tüm testler)

```bash
SESSION=degerlendirme-1 bin/smlab suite --profile full --repeat 3
```

Her mesh ve her dil için sırayla: temiz bench cluster → servis zinciri (o dil) → mesh kurulumu → doğrulama → tüm
testler (akış: [mimari.md](mimari.md#7-test-akışı)). Varsayılan: 5 mesh × `APP_LANGS` (go, dotnet) × 26 test.
Süre: full profil + 3 tekrarla dil başına ~1.5–2 gün (5 mesh × ~2.5 saat × 3 tekrar ≈ 37 saat + kurulumlar),
iki dil için bunun iki katı; önce `--repeat 1` ile bir tur önerilir.

```bash
bin/smlab suite --langs dotnet                                  # yalnız .NET
bin/smlab suite --meshes none,istio-l4,linkerd --tests P01,P05,S03
bin/smlab suite --no-fresh                                      # cluster'ı sıfırlamadan (hızlı; kıyas için önerilmez)
```

Uzun süreceği için oturumu `tmux` / `screen` içinde ya da `nohup ... > suite.log 2>&1 &` ile başlatın.

## 7. Sonuçlar

```bash
bin/smlab results              # son 30 koşu: dizin, durum, süre
bin/smlab results --last 100
```

Her koşu: `results/<zaman>_<test>_<mesh>_<dil>_r<tekrar>/`

| Dosya | İçerik |
|---|---|
| `meta.json` | Test tanımı, mesh, dil ve imaj, profil, oturum, tekrar, sürümler (mesh, k8s, uygulama çalışma zamanı), git commit |
| `result.json` | Durum, kontroller (beklenen / gerçekleşen), metrikler (değer, birim, açıklama), bulgular, uygulanamaz nedeni |
| `log.txt` | Koşunun tam çıktısı |
| `raw/` | k6 özetleri ve logları, Prometheus zaman serileri, uygulanan politikalar, tcpdump sayıları, sertifikalar |

| Durum | Anlamı |
|---|---|
| `pass` | Tüm kontroller geçti |
| `fail` | En az bir kontrol başarısız (ayrıntı `result.json` → `checks`) |
| `na` | Uygulanamaz: bu mesh'te yetenek yok (ör. ambient L4'te L7 politika). Neden kaydedilir, rapora "yetenek yok" olarak girer |
| `error` | Test yarıda kaldı (altyapı sorunu). `log.txt`'ye bakın, testi yeniden çalıştırın |

Sonuçlar ve raporlar (`results/`, `reports/`) git'te tutulur; değerlendirme oturumundan sonra commit edilerek paylaşılır.

## 8. Rapor

```bash
bin/smlab report --session degerlendirme-1     # oturumdaki tüm diller: dil başına rapor + diller arası kıyas
bin/smlab report --session degerlendirme-1 --lang dotnet   # yalnız bir dil
bin/smlab report                               # tüm sonuçlar (her test x mesh x dil için en son oturum)
bin/smlab report --out /tmp/rapor              # çıktı dizini
```

Çıktı `reports/<zaman>/`:

| Dosya | İçerik |
|---|---|
| `<dil>/rapor.html` | Tek dosya, grafikler gömülü, açık / koyu tema, yazdırılabilir |
| `<dil>/rapor.md` | Grafiksiz Markdown sürüm |
| `<dil>/veri.json` | Birleştirilmiş sonuçlar, puan kartı, projeksiyon |
| `karsilastirma.html` / `.md` | (Birden fazla dil varsa) temel göstergelerin diller arası kıyası ve her dil için mesh etkisi; test sonuç matrisi |

Dil başına rapor bölümleri: yönetici özeti · puan kartı · kalem kalem maliyet · 3.000 servis prod projeksiyonu ·
test sonuç matrisi · bulgular · test detayları · lisans / destek · yöntem ve sınırlar · envanter.

| Ayarlanabilir girdi | Nerede |
|---|---|
| Puan kartı kalemleri ve ağırlıklar | `report/scorecard.yaml` (varsayılan eşit ağırlık) |
| Prod varsayımları | `config.env` → `PROD_*` |
| Lisans / destek metinleri | `report/static.yaml` (rapordan önce güncelliği doğrulanmalı) |
| Diller arası kıyas göstergeleri | `report/compare.py` → `ITEMS` |

Varsayımlar değiştiğinde testleri yeniden koşmak gerekmez; `bin/smlab report` yeterlidir.

## 9. Ayarlar

Kalıcı değişiklik `config.env`'de, makineye özel değişiklik `config.local.env`'de (git dışı) yapılır:

| Değişken | Etkisi | Sonra |
|---|---|---|
| `ISTIO_VERSION`, `LINKERD_VERSION` (+ `_PREV_`) | Mesh sürümleri (R05: önceki sürümden yükseltme) | `smlab tools`, `mesh use --fresh` |
| `APP_LANGS`, `APP_LANG` | Desteklenen diller, varsayılan dil | — |
| `CHAINSVC_VERSION` | Uygulama imaj etiketi | `smlab app use <dil>` |
| `SVC_TIMING_*`, `SVC_REPLICAS` | Zincirin yapay işlem süresi / replika | `smlab setup` |
| `APP_WARMUP_S` | Zincir her yeniden dağıtıldığında ölçümden önceki ısınma yükü (sn, varsayılan 60; 0 = kapalı) | — |
| `TEST_WARMUP_S` | Test içinde yeniden oluşturulan pod'lar için ısınma (R01, R02; sn, varsayılan 20) | — |
| `CPUSET_*` | Node CPU yerleşimi | `smlab setup` |
| `HOST_*_PORT` | Host'a açılan portlar | `smlab env down && smlab env up` |
| `NET_*_SUBNET`, `EGRESS_*_IP` | Zone network'leri | `smlab env down && smlab env up` |
| `P01_STAGES_QUICK/FULL`, `P01_SLO_P99_MS`, `P02_RATE_*`, `P03_SPIKE_*`, `P05_RATE` | Test yük seviyeleri (testlerdeki varsayılanları ezer) | — |
| `PROD_*` | Rapordaki prod projeksiyonu | `smlab report` |

Test tanımları değişirse: `bin/smlab docs` (`docs/test-senaryolari.md` yeniden üretilir).

## 10. Yeni test eklemek

1. `tests/<ID>/test.yaml`: `id`, `name`, `category`, `purpose`, `method`, `components`, `meshes`, `profiles`, `outputs`, `pass_criteria`.
2. `tests/<ID>/run.sh`: test çerçevesi içinde `source` edilir; çalışma dizini test dizinidir. Yardımcılar:

   | Yardımcı | İşlev |
   |---|---|
   | `check <ad> <beklenen> <gerçekleşen>`, `check_le`, `check_ge`, `check_true` | Kontroller |
   | `metric <anahtar> <değer> [birim] [açıklama]` | Metrik kaydı |
   | `finding <metin>` | Rapora girecek bulgu |
   | `na <neden>` | Bu mesh'te uygulanamaz |
   | `on_exit <komut>` | Test bitince (hata olsa da) çalışacak temizlik |
   | `profile_val <quick> <full>` | Profile göre değer |
   | `k6_run` / `k6_start` / `k6_wait`, `k6_val` | Yük çalıştırma ve özet okuma |
   | `resources_snapshot`, `role_cpu`, `role_mem`, `role_requests` | Kaynak ölçümü |
   | `prom_query`, `prom_scalar`, `prom_save` | Prometheus sorguları |
   | `http_code`, `expect_access`, `chain_ok`, `probe_pod`, `authz_render` | İstemci ve politika yardımcıları |
   | `test_warmup` | Test içinde pod'lar yeniden oluşturulduysa ölçümden önce ısınma (dil adaletini korur) |
   | `$MESH`, `$APP_IMAGE`, `$SHOP_NS`, `$SHOP_URL`, `kb` (bench kubectl) | Ortam |

   Mesh'e göre dallanın (`case $MESH in istio-l[47]) ... ;; istio-sidecar) ... ;; linkerd) ... ;; esac`),
   dile göre dallanmayın; uygulamaya özel bir şey gerekiyorsa önce [sözleşmeye](../apps/chainsvc/README.md) ekleyin.
3. Gerekirse `report/scorecard.yaml`'a puan kalemi ekleyin; `bin/smlab docs`.

## 11. Temizlik

```bash
bin/smlab mesh use none                  # mesh'i kaldır (servis zinciri kalır)
bin/smlab reset                          # bench cluster'ını sıfırdan kur + setup
bin/smlab env down                       # tüm ortam: cluster'lar, edge LB, egress hedefleri, network'ler
```

`.state/` (PKI, sertifikalar, aktif mesh / dil) ve `.tools/` (CLI'lar) git dışıdır; silinirlerse yeniden üretilir.

## 12. Sık karşılaşılanlar

| Durum | Çözüm |
|---|---|
| `env up`: port kullanımda (`bind: address already in use`) | `config.local.env` ile `HOST_*_PORT` değiştirin (bölüm 2) |
| `env up`: `too many open files` / node hazır olmuyor | inotify limitleri `env up` ön kontrolünde artırılır; host yeniden başladıysa `env up`'ı tekrar çalıştırın |
| `setup` / `mesh use`: `context deadline exceeded`, pod `ImagePullBackOff` | İlk kurulumda imajlar kind node'larına internetten çekilir; yavaş bağlantıda Helm bekleme süresi dolabilir. `kubectl --context kind-sml-mgmt -n observability get pods` ile pod'un hazır olmasını bekleyip aynı komutu tekrar çalıştırın (adımlar idempotenttir) |
| Test `error` ile bitti | `results/<koşu>/log.txt` son satırlar; çoğu zaman geçici: aynı testi yeniden çalıştırın |
| `k6 zaman aşımı` | `kubectl --context kind-sml-app -n loadgen get pods`, `results/<koşu>/raw/*-k6.log` |
| Mesh değiştirdikten sonra tutarsız sonuçlar | `mesh use <profil> --fresh` |
| Host / Docker yeniden başladı | `bin/smlab env up && bin/smlab setup` (IP'ler, CPU sabitleme, CoreDNS yeniden uygulanır), sonra `mesh use` |
| `verify`: "bench cluster metrikleri mgmt'ye ulaşmıyor" | `kubectl --context kind-sml-app -n observability logs deploy/prom-agent-server` |
| `app use`: imaj derlenemedi | `bin/smlab app build <dil>` çıktısı; ağ erişimi (Docker Hub, mcr.microsoft.com, proxy.golang.org, nuget.org) |
| Rapor bir mesh'i / dili göstermiyor | O mesh / dil için koşu yok ya da `--session` filtresi dışında: `bin/smlab results` |

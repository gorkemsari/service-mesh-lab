# service-mesh-lab

Service mesh PoC ortamı: **Istio ambient (L4 / L7)**, **Istio sidecar** ve **Linkerd**, aynı servis zinciri ve
aynı yükle, mesh'siz referansa karşı performans, maliyet, güvenlik (whitelisting), trafik yönetimi, gözlem ve
dayanıklılık açısından kıyaslanır. Servis zinciri **Go** ve **.NET 10** ile aynı davranış sözleşmesine göre
uygulanmıştır; her mesh her dil için ölçülür, böylece mesh etkisinin uygulama diline göre değişimi de görülür.
Sonuçlar dil başına bir rapora ve diller arası bir kıyas raporuna dönüştürülür.

Testler tek host üzerinde, prod benzeri zone'lara ayrılmış bir multi-cluster ortamda koşar:

```
 internet ──► edge LB ──► DMZ A / DMZ B ──► sml-app (bench: mesh + servis zinciri + yük üretici) ──► sml-data
                                                   │
                                                   └──► sml-mgmt (Prometheus, Grafana, Tempo)
```

| Mesh profili | Veri düzlemi |
|---|---|
| `none` | Mesh yok (referans) |
| `istio-l4` | Istio ambient, node başına ztunnel (L4) |
| `istio-l7` | Istio ambient + waypoint (L7) |
| `istio-sidecar` | Istio, pod başına Envoy |
| `linkerd` | Linkerd, pod başına linkerd2-proxy |

## Hızlı başlangıç

Gereksinimler: Linux, Docker, kind, kubectl, helm, jq, python3 + PyYAML, openssl, curl; 12 çekirdek / 32 GB RAM
önerilir (ayrıntı: [kullanım kılavuzu](docs/kullanim-kilavuzu.md#1-gereksinimler)).

```bash
bin/smlab env up                 # test ortamı: zone network'leri, 5 kind cluster, ingress-nginx, edge LB
bin/smlab env verify             # ortam doğrulaması
bin/smlab tools                  # istioctl / linkerd CLI'ları -> .tools/
bin/smlab setup                  # CPU sabitleme, gözlem, servis zinciri, doğrulama

bin/smlab mesh use linkerd --fresh && bin/smlab test run P01      # tek mesh, tek test
bin/smlab app use dotnet && bin/smlab test run P01                # aynı test .NET ile

SESSION=degerlendirme-1 bin/smlab suite --profile full --repeat 3 # tüm mesh'ler x tüm diller x tüm testler
bin/smlab report --session degerlendirme-1                        # reports/<zaman>/
```

Tüm komutlar: `bin/smlab help`.

## Dokümanlar

| Doküman | İçerik |
|---|---|
| [docs/kullanim-kilavuzu.md](docs/kullanim-kilavuzu.md) | Gereksinimler, kurulum, dil ve mesh seçimi, test çalıştırma, sonuçlar, rapor, ayarlar, yeni test, sorun giderme |
| [docs/mimari.md](docs/mimari.md) | Topoloji, zone'lar, cluster ve node yerleşimi, servis zinciri, iletişim, mesh veri yolları, gözlem, test akışı, dizin yapısı |
| [docs/kurulum.md](docs/kurulum.md) | Kurulum adımlarının ayrıntısı, mesh profilleri, doğrulama kontrolleri, kurulum sırasında tespit edilenler |
| [docs/envanter.md](docs/envanter.md) | Tüm bileşenler ve sürümleri, yerleşim, rol bazında kaynak ölçümü |
| [docs/test-senaryolari.md](docs/test-senaryolari.md) | 26 testin amacı, yöntemi, bileşenleri, başarı ölçütü; test x bileşen matrisi |
| [apps/chainsvc/README.md](apps/chainsvc/README.md) | Test servisi sözleşmesi, sözleşme testi, yeni dil ekleme |

## Kapsam

| Alan | Testler |
|---|---|
| Performans ve maliyet | P01 kademeli yük, P02 uzun yük, P03 ani yük, P04 uçtan uca, P05 kaynak (kalem kalem), P06 pod başlangıcı, P07 politika yayılma / ölçek |
| Güvenlik / whitelisting | S01 mTLS, S02 NetworkPolicy, S03 kimlik bazlı, S04 endpoint (L7), S05 DMZ endpoint, S06 atlatma, S07 egress, S08 sertifika / CA rotasyonu |
| Trafik yönetimi | T01 kademeli yayın, T02 protokoller (gRPC, server-first TCP, DB), T03 Gateway API ingress |
| Gözlem / operasyon | O01 metrik, trace, log; O02 metrik maliyeti; O03 operasyon envanteri |
| Dayanıklılık | R01 timeout / retry / outlier, R02 hata enjeksiyonu, R03 pod kaybı, R04 kontrol düzlemi kaybı, R05 kesintisiz güncelleme |

Kapsam dışı: çok cluster'lı mesh (cluster'lar arası failover).

## Dizin yapısı

```
bin/smlab        CLI            config.env   tüm ayarlar          env/        test ortamı (kind, ingress, edge LB)
lib/             çerçeve        apps/        chainsvc + shop      meshes/     mesh helm değerleri
observability/   gözlem         tests/       26 test              report/     rapor üreticileri
docs/            dokümanlar     results/     test koşuları        reports/    üretilen raporlar
```

Ayrıntı: [docs/mimari.md](docs/mimari.md#8-dizin-yapısı).

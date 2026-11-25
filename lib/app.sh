# Test uygulaması: node yerleşimi, CPU sabitleme, chainsvc imajları, shop servis zinciri, egress hedefleri

# Node'ları ayrı CPU çekirdeklerine sabitler ve worker'ları ayırır (taint)
bench_nodes() {
  local n
  log "Node yerleşimi ve CPU sabitleme"
  for n in $(kind get nodes --name "$BENCH_CLUSTER"); do
    case $n in
      *-worker)        docker update --cpuset-cpus "$CPUSET_APP" "$n" >/dev/null; ok "$n -> CPU $CPUSET_APP (servisler)" ;;
      *-worker2)       docker update --cpuset-cpus "$CPUSET_LOADGEN" "$n" >/dev/null; ok "$n -> CPU $CPUSET_LOADGEN (k6)" ;;
      *-control-plane) docker update --cpuset-cpus "$CPUSET_CONTROL" "$n" >/dev/null; ok "$n -> CPU $CPUSET_CONTROL (kontrol düzlemi)" ;;
    esac
  done
  for n in $(for c in "$MGMT_CLUSTER" "$DATA_CLUSTER" "${DMZ_CLUSTERS[@]}"; do kind get nodes --name "$c"; done) \
           "$EDGE_LB" $(docker ps --format '{{.Names}}' | grep '^sml-ext-' || true); do
    docker update --cpuset-cpus "$CPUSET_OTHER" "$n" >/dev/null
  done
  ok "diğer cluster'lar, edge LB, egress hedefleri -> CPU $CPUSET_OTHER"
  # Worker'lara yalnızca test bileşenleri yerleşir; geri kalan her şey control-plane'de
  kb taint nodes "$BENCH_CLUSTER-worker" smlab.io/role=app:NoSchedule --overwrite >/dev/null
  kb taint nodes "$BENCH_CLUSTER-worker2" smlab.io/role=loadgen:NoSchedule --overwrite >/dev/null
  kb taint nodes "$BENCH_CLUSTER-control-plane" node-role.kubernetes.io/control-plane:NoSchedule- >/dev/null 2>&1 || true
  ok "worker taint'leri: app / loadgen"
}

# app_build <dil>: apps/chainsvc/<dil>/Dockerfile -> <CHAINSVC_IMAGE_REPO>-<dil>:<CHAINSVC_VERSION>
# Her çağrıda derlenir (docker katman önbelleği değişmeyen kaynakta saniyeler sürer); bağlam apps/chainsvc
# olduğu için ortak proto/ tüm dillerce kullanılır.
app_build() {
  local lang=$1 img
  lang_known "$lang" || die "bilinmeyen dil: $lang (apps/chainsvc/$lang/Dockerfile yok)"
  img=$(app_image_of "$lang")
  docker build -q -t "$img" -f "$SMLAB_ROOT/apps/chainsvc/$lang/Dockerfile" "$SMLAB_ROOT/apps/chainsvc" >/dev/null \
    || die "imaj derlenemedi: $img"
  ok "imaj: $img ($(docker image inspect -f '{{index .Config.Labels "smlab.runtime"}}' "$img"))"
}

# app_image: aktif dilin imajını derler ve bench cluster node'larına yükler
app_image() {
  app_build "$(current_lang)"
  kind load docker-image "$APP_IMAGE" --name "$BENCH_CLUSTER" >/dev/null 2>&1
}

app_deploy() {
  local data_ip
  log "Servis zinciri (shop, dil: $(current_lang)) + istemciler"
  app_image
  bash "$SMLAB_ROOT/apps/shop/render.sh" | kb apply -f - >/dev/null
  data_ip=$(node_ip_of "$DATA_CLUSTER-control-plane" "$NET_DATA")
  kb apply -f - >/dev/null <<YAML
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: postgres-data
  namespace: $SHOP_NS
  labels: { kubernetes.io/service-name: postgres, endpointslice.kubernetes.io/managed-by: smlab }
addressType: IPv4
ports: [{ name: tcp-postgres, port: 5432, protocol: TCP }]
endpoints: [{ addresses: ["$data_ip"], conditions: { ready: true } }]
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: redis-data
  namespace: $SHOP_NS
  labels: { kubernetes.io/service-name: redis, endpointslice.kubernetes.io/managed-by: smlab }
addressType: IPv4
ports: [{ name: tcp-redis, port: 6379, protocol: TCP }]
endpoints: [{ addresses: ["$data_ip"], conditions: { ready: true } }]
YAML
  ok "manifest'ler uygulandı (data: $data_ip)"
  egress_targets
  app_wait
  app_warmup
}

# app_use <dil>: shop zincirini başka bir dilin chainsvc imajına geçirir (mesh ve diğer bileşenler değişmez)
app_use() {
  local lang=$1
  lang_known "$lang" || die "bilinmeyen dil: $lang (mevcut: $(app_langs))"
  log "Test uygulaması dili: $lang"
  set_current_lang "$lang"
  APP_IMAGE=$(app_image_of "$lang")
  app_image
  bash "$SMLAB_ROOT/apps/shop/render.sh" | kb apply -f - >/dev/null
  app_wait
  app_warmup
}

# app_warmup: yeniden dağıtılan zinciri ölçümden önce ısıtır (APP_WARMUP_S sn, 50 -> 200 RPS).
# JIT (ör. .NET tiered compilation), bağlantı havuzları ve mesh proxy bağlantıları ölçüm başlamadan oturur.
# Pod başlangıcını ölçen testler (P06, R03, R05) yeni pod'ları kendileri oluşturur; onlar soğuk davranışı ölçer.
app_warmup() {
  local d=${APP_WARMUP_S:-0} pod a b
  [ "$d" -gt 0 ] || return 0
  a=$(( d / 3 )); b=$(( d - a ))
  log "Isınma yükü: $d sn ($(current_lang), mesh: $(current_mesh))"
  local RUN_DIR="$STATE_DIR/warmup" TEST_ID=warmup
  mkdir -p "$RUN_DIR/raw"
  pod=$(k6_start warmup load.js PHASES="50:${a}s,200:${b}s" GAP=0)
  # k6_wait hata durumunda die ile çıkar: alt kabukta çalıştırılır, ısınma hatası çağıranı durdurmaz
  if (k6_wait "$pod" warmup $(( d + 180 ))) >/dev/null 2>&1; then ok "ısınma tamam"; else warn "ısınma yükü tamamlanamadı (ölçüme etkisi olabilir)"; fi
}

app_wait() {
  local d
  for d in $(kb -n "$SHOP_NS" get deploy -o name); do
    kb -n "$SHOP_NS" rollout status "$d" --timeout=240s >/dev/null || die "$d hazır olmadı"
  done
  kb -n "$OUTSIDE_NS" rollout status deploy/probe-outside --timeout=120s >/dev/null
  ok "shop: $(kb -n "$SHOP_NS" get pods --no-headers | grep -c Running) pod çalışıyor ($APP_IMAGE)"
}

# exec_probe <pod-deploy> <ns> <komut...>
exec_probe() {
  local d=$1 ns=$2; shift 2
  kb -n "$ns" exec "deploy/$d" -c probe -- "$@"
}

app_verify() {
  local out
  log "Servis zinciri doğrulama"
  out=$(exec_probe probe-gateway "$SHOP_NS" curl -s --max-time 10 http://gateway.$SHOP_NS.svc:9090/)
  local n
  n=$(jq '[.. | objects | select(has("name")) | .name] | unique | length' <<<"$out" 2>/dev/null || echo 0)
  [ "$n" -eq 8 ] && ok "gateway -> 8 servisin hepsi cevap verdi (zincir tam)" \
    || { fail "zincir eksik: $n/8 servis ($out)"; return 1; }
  jq -e '[.. | objects | select(has("code")) | (if .type == "gRPC" then .code == 0 else .code == 200 end)] | all' <<<"$out" >/dev/null \
    && ok "tüm kademeler başarılı (HTTP 200 / gRPC OK)" || { fail "kademelerde hata var"; return 1; }
  out=$(shop_curl --max-time 10 "$SHOP_URL/")
  jq -e '.name == "gateway"' <<<"$out" >/dev/null \
    && ok "uçtan uca: $SHOP_URL (edge -> DMZ -> $BENCH_CLUSTER -> gateway)" \
    || { fail "uçtan uca erişim yok: $out"; return 1; }
  out=$(exec_probe probe-gateway "$SHOP_NS" bash -c "echo | timeout 3 nc banner.$SHOP_NS.svc 7000 2>/dev/null" 2>/dev/null || true)
  grep -q BANNER-READY <<<"$out" && ok "server-first TCP (banner:7000)" || { fail "banner servisi cevap vermedi"; return 1; }
  exec_probe probe-gateway "$SHOP_NS" bash -c "timeout 3 bash -c '</dev/tcp/postgres.$SHOP_NS.svc/5432'" \
    && ok "shop -> postgres (data cluster) TCP" || { fail "postgres erişimi yok"; return 1; }
}

# http_code <probe-deploy> <ns> <url> [curl-arg...]: HTTP durum kodu (bağlantı hatasında 000)
http_code() {
  local d=$1 ns=$2 url=$3; shift 3
  kb -n "$ns" exec "deploy/$d" -c probe -- curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" "$url" 2>/dev/null || true
}
# allowed <kod>: 2xx -> 0
is_2xx() { [[ "$1" =~ ^2 ]]; }

# ns_mesh_labels <kaynak-ns> <hedef-ns>: mesh etiket/annotation'larını kopyalar (yeni test namespace'leri için)
ns_mesh_labels() {
  local l a
  l=$(kb get ns "$1" -o json | jq -r '.metadata.labels // {} | to_entries[] | select(.key|test("istio|dataplane")) | "\(.key)=\(.value)"')
  a=$(kb get ns "$1" -o json | jq -r '.metadata.annotations // {} | to_entries[] | select(.key|test("linkerd")) | "\(.key)=\(.value)"')
  [ -n "$l" ] && kb label ns "$2" $l --overwrite >/dev/null
  [ -n "$a" ] && kb annotate ns "$2" $a --overwrite >/dev/null
  return 0
}

# Geçici test istemcisi: probe_pod <ad> <ns> <sa> <shop.role> [ek-yaml-alanları-json]
#   ek json ile pod şablonuna metadata/spec eklenir (ör. hostNetwork, mesh dışı annotation)
probe_pod() {
  local name=$1 ns=$2 sa=$3 role=$4 extra=${5:-'{}'}
  jq -n --arg n "$name" --arg ns "$ns" --arg sa "$sa" --arg role "$role" --arg img "$NETSHOOT_IMAGE" --argjson x "$extra" '{
    apiVersion: "apps/v1", kind: "Deployment",
    metadata: {name: $n, namespace: $ns},
    spec: {replicas: 1, selector: {matchLabels: {app: $n}},
      template: {
        metadata: ({labels: {app: $n, "shop.role": $role}} * ($x.metadata // {})),
        spec: ({serviceAccountName: $sa, nodeSelector: {"smlab.io/role": "app"},
          tolerations: [{key: "smlab.io/role", operator: "Equal", value: "app", effect: "NoSchedule"}],
          terminationGracePeriodSeconds: 1,
          containers: [{name: "probe", image: $img, command: ["sleep", "infinity"],
            securityContext: ($x.securityContext // {})}]} * ($x.spec // {}))}}}' | kb apply -f - >/dev/null
  kb -n "$ns" rollout status "deploy/$name" --timeout=120s >/dev/null
}

# shop pod'larının tamamı Ready mi (politikalar kubelet probe'larını kesmiş olabilir)
shop_all_ready() {
  kb -n "$SHOP_NS" get pods -l app.kubernetes.io/part-of=shop -o json | jq -e '
    [.items[] | select(.metadata.deletionTimestamp == null) | (.status.conditions[]? | select(.type=="Ready") | .status)] | all(. == "True")' >/dev/null
}

# chain_ok <probe> : gateway üzerinden 8 servisin hepsi başarılı mı
chain_ok() {
  local out
  out=$(exec_probe "$1" "$SHOP_NS" curl -s --max-time 10 "http://gateway.$SHOP_NS.svc:9090/" 2>/dev/null)
  jq -e '([.. | objects | select(has("name")) | .name] | unique | length) == 8 and
         ([.. | objects | select(has("code")) | (if .type == "gRPC" then .code == 0 else .code == 200 end)] | all)' <<<"$out" >/dev/null 2>&1
}
e2e_ok() { [ "$(shop_curl -o /dev/null -w '%{http_code}' --max-time 10 "$SHOP_URL/")" = 200 ]; }

# expect_access <ad> <izin|ret> <probe> <ns> <url> [curl-arg...]
expect_access() {
  local name=$1 want=$2 p=$3 ns=$4 url=$5 code got; shift 5
  code=$(http_code "$p" "$ns" "$url" "$@")
  if is_2xx "$code"; then got=izin; else got=ret; fi
  check "$name [$code]" "$want" "$got"
}

# Dış çıkış (egress) hedefleri: cluster dışında, NET_APP segmentinde iki HTTPS sunucusu (IP'ler config.env).
# Cluster DNS'inde (CoreDNS) adları tanımlanır -> internet bağımlılığı olmadan FQDN bazlı egress testi (S07).
egress_targets() {
  local d="$STATE_DIR/egress" n ip
  mkdir -p "$d"
  [ -f "$d/tls.crt" ] || openssl req -x509 -newkey rsa:2048 -nodes -days 825 -subj "/CN=*.ext.test" \
    -addext "subjectAltName=DNS:*.ext.test" -keyout "$d/tls.key" -out "$d/tls.crt" 2>/dev/null
  cat > "$d/default.conf" <<'NGX'
server { listen 443 ssl; ssl_certificate /certs/tls.crt; ssl_certificate_key /certs/tls.key;
  location / { default_type text/plain; return 200 "ext-target $hostname\n"; } }
NGX
  for n in allowed denied; do
    ip=$([ $n = allowed ] && echo $EGRESS_ALLOWED_IP || echo $EGRESS_DENIED_IP)
    if ! docker inspect "sml-ext-$n" >/dev/null 2>&1; then
      docker run -d --name "sml-ext-$n" --restart unless-stopped --network "$NET_APP" --ip "$ip" --cpuset-cpus "$CPUSET_OTHER" \
        --hostname "$n.ext.test" -v "$d:/certs:ro" -v "$d/default.conf:/etc/nginx/conf.d/default.conf:ro" \
        nginx:1.27-alpine >/dev/null
    fi
  done
  # CoreDNS: ext.test bölgesi (değiştiyse CoreDNS yeniden başlatılır; reload eklentisi gecikmeli/güvenilmez)
  local before; before=$(kb -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' | md5sum)
  kb -n kube-system get configmap coredns -o json | jq --arg a "$EGRESS_ALLOWED_IP" --arg b "$EGRESS_DENIED_IP" '
    .data.Corefile |= (if test("ext.test:53") then . else . + "\next.test:53 {\n    hosts {\n        \($a) allowed.ext.test\n        \($b) denied.ext.test\n    }\n}\n" end)
    | .data.Corefile |= sub("\n# node resolv.conf search local[^\n]*\nlocal:53 \\{\n    template ANY ANY \\{\n        rcode NXDOMAIN\n    \\}\n\\}\n"; "")
    | .data.Corefile |= (if test("ext.test.local:53") then . else . + "\n# search local: ext.test adlarının .local denemesi upstream DNS tarafında zaman aşımına uğrar -> hızlı NXDOMAIN\next.test.local:53 {\n    template ANY ANY {\n        rcode NXDOMAIN\n    }\n}\n" end)' \
    | kb apply -f - >/dev/null
  if [ "$before" != "$(kb -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' | md5sum)" ]; then
    kb -n kube-system rollout restart deploy/coredns >/dev/null
    kb -n kube-system rollout status deploy/coredns --timeout=120s >/dev/null
  fi
  ok "egress hedefleri: allowed.ext.test ($EGRESS_ALLOWED_IP), denied.ext.test ($EGRESS_DENIED_IP)"
}

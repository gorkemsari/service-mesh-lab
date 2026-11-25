# smlab ortak fonksiyonları (bin/smlab ve tests/*/run.sh tarafından source edilir)
set -euo pipefail

SMLAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_DIR="$SMLAB_ROOT/env"            # test ortamı (kind cluster'ları, edge LB, ingress-nginx)
source "$SMLAB_ROOT/config.env"
[ -f "$SMLAB_ROOT/config.local.env" ] && source "$SMLAB_ROOT/config.local.env"
export HOST_HTTPS_PORT HOST_MGMT_HTTPS_PORT   # bash -c ile çalışan bekleme komutları (mgmt_curl / shop_curl) kullanır
source "$ENV_DIR/ingress-nginx/args.sh"

TOOLS="$SMLAB_ROOT/.tools"
RESULTS_DIR="${SMLAB_RESULTS_DIR:-$SMLAB_ROOT/results}"
STATE_DIR="$SMLAB_ROOT/.state"
mkdir -p "$TOOLS" "$RESULTS_DIR" "$STATE_DIR"
export PATH="$TOOLS/bin:$PATH"

MESH_PROFILES=(none istio-l4 istio-l7 istio-sidecar linkerd)

# Cluster'lar (rol -> ad, bkz. env/lib.sh)
BENCH_CLUSTER="${CLUSTER_PREFIX}app"   # mesh'lerin ve testlerin çalıştığı cluster
MGMT_CLUSTER="${CLUSTER_PREFIX}mgmt"
DATA_CLUSTER="${CLUSTER_PREFIX}data"
DMZ_CLUSTERS=("${CLUSTER_PREFIX}dmz-a" "${CLUSTER_PREFIX}dmz-b")

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*" >&2; }
ok()   { printf '  \033[32m[ok]\033[0m %s\n' "$*" >&2; }
warn() { printf '  \033[33m[!]\033[0m %s\n' "$*" >&2; }
fail() { printf '  \033[31m[x]\033[0m %s\n' "$*" >&2; }
die()  { fail "$*"; exit 1; }

# kb: bench cluster'ına kubectl; km: mgmt cluster'ına kubectl; hb / hm: helm
kb() { kubectl --context "kind-$BENCH_CLUSTER" "$@"; }
km() { kubectl --context "kind-$MGMT_CLUSTER" "$@"; }
hb() { helm --kube-context "kind-$BENCH_CLUSTER" "$@"; }
hm() { helm --kube-context "kind-$MGMT_CLUSTER" "$@"; }

# --- Test uygulaması dili (apps/chainsvc/<dil>/) --------------------------------
app_langs() { tr ',' ' ' <<<"$APP_LANGS"; }
current_lang() { cat "$STATE_DIR/lang" 2>/dev/null || echo "$APP_LANG"; }
set_current_lang() { echo "$1" > "$STATE_DIR/lang"; }
app_image_of() { echo "$CHAINSVC_IMAGE_REPO-$1:$CHAINSVC_VERSION"; }
lang_known() { [ -f "$SMLAB_ROOT/apps/chainsvc/$1/Dockerfile" ]; }
APP_IMAGE="$(app_image_of "$(current_lang)")"   # testler bu değişkeni kullanır (aktif dilin imajı)

node_ip_of() { # node_ip_of <node-container> <network>
  docker inspect -f "{{with index .NetworkSettings.Networks \"$2\"}}{{.IPAddress}}{{end}}" "$1"
}

retry() { # retry <deneme> <bekleme-sn> <komut...>
  local n=$1 s=$2 i; shift 2
  for ((i = 1; i <= n; i++)); do
    "$@" && return 0
    sleep "$s"
  done
  return 1
}

# wait_for <sn> <açıklama> <komut...>: komut başarılı olana kadar bekler
wait_for() {
  local t=$1 d=$2 i; shift 2
  for ((i = 0; i < t; i++)); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  fail "zaman aşımı ($t sn): $d"; return 1
}

# --- Aktif mesh profili -----------------------------------------------------
current_mesh() { cat "$STATE_DIR/mesh" 2>/dev/null || echo none; }
set_current_mesh() { echo "$1" > "$STATE_DIR/mesh"; }
mesh_family() { # none | istio | linkerd
  case $1 in istio-*) echo istio ;; linkerd) echo linkerd ;; *) echo none ;; esac
}

# --- Prometheus (mgmt) ------------------------------------------------------
PROM_URL="https://prometheus.localtest.me:$HOST_MGMT_HTTPS_PORT"
GRAFANA_URL="https://grafana.localtest.me:$HOST_MGMT_HTTPS_PORT"
SHOP_URL="https://shop.localtest.me:$HOST_HTTPS_PORT"     # internet -> edge LB -> DMZ -> bench
# *.localtest.me herkese açık DNS'te 127.0.0.1'e çözülür; --resolve DNS'siz ortamlarda da çalışmasını sağlar
mgmt_curl() { curl -sk --resolve "prometheus.localtest.me:$HOST_MGMT_HTTPS_PORT:127.0.0.1" --resolve "grafana.localtest.me:$HOST_MGMT_HTTPS_PORT:127.0.0.1" "$@"; }
shop_curl() { curl -sk --resolve "shop.localtest.me:$HOST_HTTPS_PORT:127.0.0.1" "$@"; }
# Prometheus geçici olarak cevap veremezse (yeniden başlama, 503) birkaç kez tekrar denenir
prom_curl() { mgmt_curl --max-time 30 --retry 5 --retry-all-errors --retry-delay 3 -f "$@"; }
# prom_query <promql> [zaman(unix)] -> JSON
prom_query() {
  if [ -n "${2:-}" ]; then
    prom_curl "$PROM_URL/api/v1/query" --data-urlencode "query=$1" --data-urlencode "time=$2"
  else
    prom_curl "$PROM_URL/api/v1/query" --data-urlencode "query=$1"
  fi
}
# prom_range <promql> <başlangıç> <bitiş> <adım-sn> -> JSON
prom_range() {
  prom_curl "$PROM_URL/api/v1/query_range" --data-urlencode "query=$1" \
    --data-urlencode "start=$2" --data-urlencode "end=$3" --data-urlencode "step=$4"
}
# prom_scalar <promql> [zaman]: tek değer (yoksa "null")
prom_scalar() {
  prom_query "$@" | jq -r '(.data.result[0].value[1] // "null")'
}

# --- Sürüm envanteri (meta.json'a yazılır) ---------------------------------
versions_json() {
  jq -n \
    --arg istio "$ISTIO_VERSION" --arg linkerd "$LINKERD_VERSION" \
    --arg k6 "$K6_IMAGE" --arg app "$APP_IMAGE" --arg gw "$GATEWAY_API_VERSION" \
    --arg k8s "$(kb version -o json 2>/dev/null | jq -r .serverVersion.gitVersion)" \
    --arg kind "$(kind version 2>/dev/null | awk '{print $2}')" \
    --arg ingress "$INGRESS_NGINX_CHART_VERSION" --arg lang "$(current_lang)" \
    --arg runtime "$(docker image inspect -f '{{index .Config.Labels "smlab.runtime"}}' "$APP_IMAGE" 2>/dev/null)" \
    '{istio:$istio, linkerd:$linkerd, k6:$k6, app:$app, app_lang:$lang, app_runtime:$runtime, gateway_api:$gw,
      kubernetes:$k8s, kind:$kind, ingress_nginx_chart:$ingress}'
}

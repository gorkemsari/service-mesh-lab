# Test ortamı ortak fonksiyonları (env/up.sh, env/verify.sh, env/down.sh tarafından source edilir)
set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$ENV_DIR/.." && pwd)"
GEN_DIR="$ROOT/.state/env"          # üretilen dosyalar: TLS sertifikası, haproxy.cfg
source "$ROOT/config.env"
[ -f "$ROOT/config.local.env" ] && source "$ROOT/config.local.env"
source "$ENV_DIR/ingress-nginx/args.sh"

# Roller (kurulum sırası). Cluster adı: <CLUSTER_PREFIX><rol>
ROLES=(mgmt data app dmz-a dmz-b)
DMZ_ROLES=(dmz-a dmz-b)

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m[ok]\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m[x]\033[0m %s\n' "$*"; }

cluster() { echo "${CLUSTER_PREFIX}$1"; }                               # rol -> kind cluster adı
k() { local r=$1; shift; kubectl --context "kind-$(cluster "$r")" "$@"; } # k <rol> <kubectl argümanları>
node_name() { echo "$(cluster "$1")-control-plane"; }

# node_ip <rol> <network>: control-plane node'unun o network'teki IP'si (bağlı değilse boş)
node_ip() {
  docker inspect -f "{{with index .NetworkSettings.Networks \"$2\"}}{{.IPAddress}}{{end}}" "$(node_name "$1")"
}

primary_net() {
  case $1 in
    dmz-*) echo "$NET_DMZ" ;;
    app)   echo "$NET_APP" ;;
    data)  echo "$NET_DATA" ;;
    mgmt)  echo "$NET_MGMT" ;;
  esac
}

zone_of() { case $1 in dmz-*) echo dmz ;; *) echo "$1" ;; esac; }

# retry <deneme> <komut...>: webhook henüz hazır değilken apply gibi işlemler için
retry() {
  local n=$1 i; shift
  for ((i = 1; i <= n; i++)); do
    "$@" && return 0
    echo "  ...tekrar deneniyor ($i/$n)"; sleep 5
  done
  return 1
}

# endpointslice <ns> <service> <port-adı> <port> <ip...>
# Selector'sız bir Service'i cluster dışındaki IP'lere yönlendirir
endpointslice() {
  local ns=$1 svc=$2 pname=$3 port=$4 ip; shift 4
  cat <<YAML
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: $svc-static
  namespace: $ns
  labels:
    kubernetes.io/service-name: $svc
    endpointslice.kubernetes.io/managed-by: smlab
addressType: IPv4
ports:
  - { name: $pname, port: $port, protocol: TCP }
endpoints:
YAML
  for ip in "$@"; do
    echo "  - { addresses: [\"$ip\"], conditions: { ready: true } }"
  done
}

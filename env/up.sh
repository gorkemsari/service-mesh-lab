#!/usr/bin/env bash
# Test ortamını kurar: zone network'leri, 5 kind cluster, ingress-nginx, data servisleri, DMZ kuralları, edge LB.
# Idempotent: yarıda kalırsa tekrar çalıştırılabilir. Kullanım: bin/smlab env up
source "$(dirname "$0")/lib.sh"

preflight() {
  log "Ön kontroller"
  local t
  for t in docker kind kubectl helm openssl curl jq; do
    command -v "$t" >/dev/null || { fail "$t bulunamadı"; exit 1; }
  done
  docker info >/dev/null 2>&1 || { fail "Docker çalışmıyor"; exit 1; }
  # Çok sayıda kind node'u için inotify limitleri (host yeniden başlarsa sıfırlanır)
  docker run --rm --privileged --pid=host alpine:3.20 nsenter -t 1 -m -u -n -i \
    sysctl -w fs.inotify.max_user_instances=1024 fs.inotify.max_user_watches=1048576 >/dev/null
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update >/dev/null
  helm repo update ingress-nginx >/dev/null
  ok "araçlar ve helm repoları hazır"
}

create_networks() {
  log "Zone network'leri"
  local spec name subnet
  for spec in "$NET_EDGE=$NET_EDGE_SUBNET" "$NET_DMZ=$NET_DMZ_SUBNET" "$NET_APP=$NET_APP_SUBNET" \
              "$NET_DATA=$NET_DATA_SUBNET" "$NET_MGMT=$NET_MGMT_SUBNET"; do
    name=${spec%%=*} subnet=${spec#*=}
    docker network inspect "$name" >/dev/null 2>&1 || docker network create --driver bridge --subnet "$subnet" "$name" >/dev/null
    ok "$name ($subnet)"
  done
}

create_cluster() {
  local r=$1 c
  c=$(cluster "$r")
  if kind get clusters 2>/dev/null | grep -qx "$c"; then
    ok "$c zaten var"; return
  fi
  log "Cluster: $c ($(primary_net "$r"))"
  # kind yapılandırmasındaki host port yer tutucuları (yalnızca mgmt) config.env'den doldurulur
  mkdir -p "$GEN_DIR"
  sed -e "s/__HOST_MGMT_HTTP_PORT__/$HOST_MGMT_HTTP_PORT/" -e "s/__HOST_MGMT_HTTPS_PORT__/$HOST_MGMT_HTTPS_PORT/" \
    "$ENV_DIR/kind/$r.yaml" > "$GEN_DIR/kind-$r.yaml"
  KIND_EXPERIMENTAL_DOCKER_NETWORK="$(primary_net "$r")" \
    kind create cluster --name "$c" --image "$KIND_NODE_IMAGE" --config "$GEN_DIR/kind-$r.yaml" --wait 180s
}

# attach <rol> <network>: cluster'ın tüm node'larını ek bir zone network'üne bağlar
attach() {
  local n
  for n in $(kind get nodes --name "$(cluster "$1")"); do
    if [ -z "$(docker inspect -f "{{with index .NetworkSettings.Networks \"$2\"}}{{.IPAddress}}{{end}}" "$n")" ]; then
      docker network connect "$2" "$n"
    fi
  done
  ok "$(cluster "$1") -> $2 ($(node_ip "$1" "$2"))"
}

attach_networks() {
  log "Zone'lar arası bağlantılar"
  attach dmz-a "$NET_APP"
  attach dmz-b "$NET_APP"
  attach app "$NET_DATA"
  attach mgmt "$NET_DMZ"
  attach mgmt "$NET_APP"
  attach mgmt "$NET_DATA"
}

install_ingress() {
  local r=$1 extra=()
  log "ingress-nginx: $(cluster "$r") (zone: $(zone_of "$r"))"
  ingress_args "$(zone_of "$r")"
  # DMZ cevaplarına hangi DMZ cluster'ından geçildiğini ekle (edge LB dağılımını görmek için)
  [ "$(zone_of "$r")" = dmz ] && extra=(--set-string "controller.addHeaders.X-Dmz=$r")
  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx --kube-context "kind-$(cluster "$r")" \
    --create-namespace "${INGRESS_ARGS[@]}" "${extra[@]}" --wait --timeout 6m
}

deploy_data() {
  log "Data: Postgres + Redis"
  retry 6 k data apply -k "$ENV_DIR/workloads/data"
  k data -n data rollout status statefulset/postgres --timeout=300s
  k data -n data rollout status deployment/redis --timeout=180s
}

ensure_cert() {
  local dir="$GEN_DIR/certs"
  [ -f "$dir/tls.crt" ] && return
  mkdir -p "$dir"
  openssl req -x509 -newkey rsa:2048 -nodes -days 825 -subj "/CN=*.localtest.me" \
    -addext "subjectAltName=DNS:*.localtest.me,DNS:localtest.me" \
    -keyout "$dir/tls.key" -out "$dir/tls.crt" 2>/dev/null
}

deploy_dmz() {
  local app_ip r
  app_ip=$(node_ip app "$NET_APP")
  ensure_cert
  for r in "${DMZ_ROLES[@]}"; do
    log "DMZ: $(cluster "$r") -> $(cluster app) ingress ($app_ip)"
    retry 6 k "$r" apply -k "$ENV_DIR/workloads/dmz"
    k "$r" -n edge create secret tls edge-tls --cert "$GEN_DIR/certs/tls.crt" --key "$GEN_DIR/certs/tls.key" \
      --dry-run=client -o yaml | k "$r" apply -f -
    endpointslice edge app-ingress http 80 "$app_ip" | k "$r" apply -f -
  done
}

# Edge LB: HAProxy container'ı; host 80/443 -> dmz-a / dmz-b ingress (L4 + PROXY protocol)
deploy_edge() {
  local a_ip b_ip cfg="$GEN_DIR/haproxy.cfg"
  a_ip=$(node_ip dmz-a "$NET_DMZ")
  b_ip=$(node_ip dmz-b "$NET_DMZ")
  log "Edge LB: $EDGE_LB -> dmz-a ($a_ip), dmz-b ($b_ip)"
  mkdir -p "$GEN_DIR"
  sed -e "s/__DMZ_A__/$a_ip/g" -e "s/__DMZ_B__/$b_ip/g" "$ENV_DIR/edge-lb/haproxy.cfg.tpl" > "$cfg"
  docker rm -f "$EDGE_LB" >/dev/null 2>&1 || true
  docker run -d --name "$EDGE_LB" --restart unless-stopped \
    --network "$NET_EDGE" --sysctl net.ipv4.ip_unprivileged_port_start=0 \
    -p "127.0.0.1:$HOST_HTTP_PORT:80" -p "127.0.0.1:$HOST_HTTPS_PORT:443" -p "127.0.0.1:$HOST_LB_STATS_PORT:8404" \
    -v "$cfg:/usr/local/etc/haproxy/haproxy.cfg:ro" "$HAPROXY_IMAGE" >/dev/null
  docker network connect "$NET_DMZ" "$EDGE_LB"
  # Sağlık kontrolü (3 sn aralıkla 2 başarılı) iki DMZ'yi de UP görene kadar bekle: ortam "hazır" dendiğinde trafik alır
  local i up=0
  for ((i = 0; i < 60; i++)); do
    up=$(curl -s --max-time 2 "http://127.0.0.1:$HOST_LB_STATS_PORT/;csv" | grep -E '^dmz_https,dmz-[ab],' | grep -c ',UP,' || true)
    [ "$up" -eq 2 ] && break
    sleep 1
  done
  [ "$up" -eq 2 ] && ok "$EDGE_LB çalışıyor ($NET_EDGE + $NET_DMZ), iki DMZ backend'i UP" \
    || fail "$EDGE_LB: DMZ backend'leri 60 sn içinde UP olmadı (http://127.0.0.1:$HOST_LB_STATS_PORT)"
}

# wait_path: edge LB -> DMZ -> sml-app ingress yolu 5xx'siz cevap verene kadar bekler (DMZ nginx'lerinin
# yeni upstream'i yüklemesi birkaç saniye sürer). shop henüz kurulmadıysa sml-app ingress'i 404 döner: yol sağlam.
wait_path() {
  local i code
  for ((i = 0; i < 60; i++)); do
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 --resolve "shop.localtest.me:$HOST_HTTPS_PORT:127.0.0.1" \
      "https://shop.localtest.me:$HOST_HTTPS_PORT/" || true)
    [[ "$code" =~ ^(200|404)$ ]] && { ok "giriş yolu hazır (edge LB -> DMZ -> $(cluster app) ingress, HTTP $code)"; return; }
    sleep 1
  done
  fail "giriş yolu 60 sn içinde hazır olmadı (son kod: $code)"
}

summary() {
  log "Test ortamı hazır"
  cat <<TXT
  kubectl context'leri : $(for r in "${ROLES[@]}"; do printf 'kind-%s ' "$(cluster "$r")"; done)
  Giriş (internet)      : https://shop.localtest.me:$HOST_HTTPS_PORT  ('smlab setup' sonrası)
  Gözlem (mgmt)        : https://grafana.localtest.me:$HOST_MGMT_HTTPS_PORT, https://prometheus.localtest.me:$HOST_MGMT_HTTPS_PORT
  Edge LB istatistikleri: http://127.0.0.1:$HOST_LB_STATS_PORT
  Doğrulama            : bin/smlab env verify
  Sonraki adım         : bin/smlab tools && bin/smlab setup
TXT
}

preflight
create_networks
for r in "${ROLES[@]}"; do create_cluster "$r"; done
attach_networks
for r in "${ROLES[@]}"; do install_ingress "$r"; done
deploy_data
deploy_dmz
deploy_edge
wait_path
summary

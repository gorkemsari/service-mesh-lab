# Gözlem altyapısı: sml-mgmt'de Prometheus/Grafana/Tempo, bench cluster'ında (sml-app) Prometheus agent

obs_install_mgmt() {
  log "Gözlem ($MGMT_CLUSTER): Prometheus, Tempo, Grafana"
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
  helm repo add grafana https://grafana.github.io/helm-charts --force-update >/dev/null
  helm repo update prometheus-community grafana >/dev/null
  # mgmt ingress'inin TCP portları (9090/9411/4317) values-mgmt.yaml'da; env up ile aynı argümanlar
  ingress_args mgmt
  hm upgrade --install ingress-nginx ingress-nginx/ingress-nginx "${INGRESS_ARGS[@]}" --wait --timeout 5m >/dev/null
  hm upgrade --install prometheus prometheus-community/prometheus --version "$PROMETHEUS_CHART_VERSION" \
    -n observability --create-namespace -f "$SMLAB_ROOT/observability/prometheus-mgmt.yaml" --wait --timeout 6m >/dev/null
  ok "prometheus"
  hm upgrade --install tempo grafana/tempo --version "$TEMPO_CHART_VERSION" \
    -n observability -f "$SMLAB_ROOT/observability/tempo.yaml" --wait --timeout 6m >/dev/null
  ok "tempo"
  # pano sorgularındaki __BENCH_CLUSTER__ yer tutucusu config'deki cluster adıyla doldurulur
  local d="$STATE_DIR/dashboards" f
  mkdir -p "$d"
  for f in "$SMLAB_ROOT"/observability/dashboards/*.json; do
    sed "s/__BENCH_CLUSTER__/$BENCH_CLUSTER/g" "$f" > "$d/$(basename "$f")"
  done
  km -n observability create configmap grafana-dashboards-smlab \
    --from-file="$d/" --dry-run=client -o yaml | km apply -f - >/dev/null
  hm upgrade --install grafana grafana/grafana --version "$GRAFANA_CHART_VERSION" \
    -n observability -f "$SMLAB_ROOT/observability/grafana.yaml" --wait --timeout 6m >/dev/null
  ok "grafana"
}

# Bench cluster'ında mgmt'yi temsil eden selector'sız servisler (data servisleriyle aynı yöntem)
obs_bridge_bench() {
  local ip
  ip=$(node_ip_of "$MGMT_CLUSTER-control-plane" "$NET_APP")
  [ -n "$ip" ] || die "mgmt node'unun $NET_APP IP'si bulunamadı"
  kb create namespace observability --dry-run=client -o yaml | kb apply -f - >/dev/null
  kb apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Service
metadata: { name: prometheus, namespace: observability }
spec:
  ports: [{ name: http, port: 9090, targetPort: 9090, appProtocol: http }]
---
apiVersion: v1
kind: Service
metadata: { name: tempo, namespace: observability }
spec:
  ports:
    - { name: zipkin, port: 9411, targetPort: 9411, appProtocol: http }
    - { name: otlp-grpc, port: 4317, targetPort: 4317, appProtocol: grpc }
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: prometheus-mgmt
  namespace: observability
  labels: { kubernetes.io/service-name: prometheus, endpointslice.kubernetes.io/managed-by: smlab }
addressType: IPv4
ports: [{ name: http, port: 9090, protocol: TCP }]
endpoints: [{ addresses: ["$ip"], conditions: { ready: true } }]
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: tempo-mgmt
  namespace: observability
  labels: { kubernetes.io/service-name: tempo, endpointslice.kubernetes.io/managed-by: smlab }
addressType: IPv4
ports:
  - { name: zipkin, port: 9411, protocol: TCP }
  - { name: otlp-grpc, port: 4317, protocol: TCP }
endpoints: [{ addresses: ["$ip"], conditions: { ready: true } }]
YAML
  ok "bench -> mgmt köprüsü (prometheus/tempo -> $ip)"
}

# obs_install_agent [mesh-profili]: agent'ı kurar/günceller. Her seri cluster / mesh / lang dış etiketlerini taşır.
obs_install_agent() {
  local mesh=${1:-$(current_mesh)} lang
  lang=$(current_lang)
  log "Gözlem ($BENCH_CLUSTER): Prometheus agent (mesh=$mesh, lang=$lang)"
  obs_bridge_bench
  hb upgrade --install prom-agent prometheus-community/prometheus --version "$PROMETHEUS_CHART_VERSION" \
    -n observability -f "$SMLAB_ROOT/observability/prometheus-agent.yaml" \
    --set-string "server.global.external_labels.cluster=$BENCH_CLUSTER" \
    --set-string "server.global.external_labels.mesh=$mesh" \
    --set-string "server.global.external_labels.lang=$lang" --wait --timeout 5m >/dev/null
  ok "prom-agent (external_labels: cluster=$BENCH_CLUSTER, mesh=$mesh, lang=$lang)"
}

obs_verify() {
  local n
  log "Gözlem doğrulama"
  wait_for 60 "Prometheus API" bash -c "$(declare -f mgmt_curl); mgmt_curl --max-time 5 $PROM_URL/-/ready | grep -qi ready" \
    && ok "Prometheus hazır ($PROM_URL)"
  wait_for 90 "bench cluster metrikleri mgmt'ye ulaşıyor" \
    bash -c "$(declare -f mgmt_curl); [ \"\$(mgmt_curl '$PROM_URL/api/v1/query' --data-urlencode 'query=count(up{cluster=\"$BENCH_CLUSTER\"})' | jq -r '.data.result[0].value[1] // 0')\" -gt 0 ]"
  n=$(prom_scalar "count(up{cluster=\"$BENCH_CLUSTER\"} == 1)")
  ok "bench cluster'ından $n hedef toplanıyor (remote-write çalışıyor)"
  n=$(prom_scalar "count(container_cpu_usage_seconds_total{cluster=\"$BENCH_CLUSTER\",container!=\"\"})")
  [ "$n" != null ] && ok "cAdvisor konteyner metrikleri: $n seri" || { fail "cAdvisor metrikleri yok"; return 1; }
  n=$(prom_scalar "count(kube_pod_info{cluster=\"$BENCH_CLUSTER\"})")
  [ "$n" != null ] && ok "kube-state-metrics: $n pod" || { fail "kube-state-metrics yok"; return 1; }
  mgmt_curl --max-time 5 "$GRAFANA_URL/api/health" | grep -q '"database": *"ok"' \
    && ok "Grafana hazır ($GRAFANA_URL)" || { fail "Grafana cevap vermiyor"; return 1; }
  mgmt_curl --max-time 5 -u admin:smlab "$GRAFANA_URL/api/datasources/uid/tempo/health" | grep -qi '"status": *"OK"' \
    && ok "Grafana -> Tempo datasource" || warn "Tempo datasource sağlık kontrolü geçmedi (trace yoksa normal olabilir)"
}

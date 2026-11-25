# ingress_args <zone>: ingress-nginx helm argümanlarını INGRESS_ARGS dizisine yazar.
# Tek kaynak: env/up.sh (ilk kurulum), lib/mesh.sh (mesh'e alma) ve lib/observability.sh (mgmt TCP portları)
# aynı değerlerle kurar; böylece 'helm upgrade' zone ayarlarını kaybetmez.
ingress_args() {
  local d
  d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  INGRESS_ARGS=(--version "$INGRESS_NGINX_CHART_VERSION" -n ingress-nginx
                -f "$d/values-common.yaml" -f "$d/values-$1.yaml")
  case $1 in
    dmz) INGRESS_ARGS+=(--set-string "controller.config.proxy-real-ip-cidr=$NET_DMZ_SUBNET") ;;  # yalnızca edge LB
    app) INGRESS_ARGS+=(--set-string "controller.config.proxy-real-ip-cidr=$NET_APP_SUBNET") ;;  # yalnızca DMZ node'ları
  esac
}

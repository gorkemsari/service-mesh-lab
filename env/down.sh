#!/usr/bin/env bash
# Test ortamını tamamen siler: edge LB, egress hedefleri, tüm cluster'lar ve zone network'leri.
# Kullanım: bin/smlab env down
source "$(dirname "$0")/lib.sh"

for c in "$EDGE_LB" sml-ext-allowed sml-ext-denied; do
  docker rm -f "$c" >/dev/null 2>&1 && ok "silindi: $c"
done
for r in "${ROLES[@]}"; do
  if kind get clusters 2>/dev/null | grep -qx "$(cluster "$r")"; then
    log "Siliniyor: $(cluster "$r")"
    kind delete cluster --name "$(cluster "$r")"
  fi
done
for n in "$NET_EDGE" "$NET_DMZ" "$NET_APP" "$NET_DATA" "$NET_MGMT"; do
  docker network rm "$n" >/dev/null 2>&1 && ok "network silindi: $n"
done
rm -f "$ROOT/.state/mesh"     # aktif mesh profili artık geçersiz
true

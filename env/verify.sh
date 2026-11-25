#!/usr/bin/env bash
# Test ortamını uçtan uca doğrular: edge -> DMZ -> sml-app yolu, data erişimi, segmentasyon, mgmt erişimi.
# 'smlab setup' öncesinde de çalışır (shop henüz yoksa sml-app ingress'i 404 döner; yol yine doğrulanmış olur).
# Kullanım: bin/smlab env verify
source "$(dirname "$0")/lib.sh"
set +e

FAILED=0
check() { # check <açıklama> <komut...>: en fazla 3 deneme (yeni kurulan ortamda geçici gecikmeler için)
  local desc=$1 i; shift
  for i in 1 2 3; do
    if "$@" >/dev/null 2>&1; then ok "$desc"; return; fi
    sleep 3
  done
  fail "$desc"; FAILED=$((FAILED + 1))
}
expect_fail() { # expect_fail <açıklama> <komut...>
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then fail "$desc (ERİŞİLEBİLİR!)"; FAILED=$((FAILED + 1)); else ok "$desc"; fi
}
# probe <rol> <image> <komut...>: cluster içinde tek seferlik pod (control-plane'e de yerleşebilir)
probe() {
  local r=$1 img=$2; shift 2
  k "$r" run "probe-$RANDOM" -n default --rm -i --restart=Never --quiet --image="$img" \
    --overrides='{"spec":{"tolerations":[{"operator":"Exists"}]}}' --command -- "$@"
}

SHOP="https://shop.localtest.me:$HOST_HTTPS_PORT"
log "İnternet -> edge LB -> DMZ A/B -> $(cluster app) ingress ($SHOP)"
# Her satır: "<X-Dmz> <HTTP kodu>". 200 (shop kurulu) veya 404 (henüz kurulmadı) -> yol sağlam; 5xx -> kopuk
out=$(for i in $(seq 12); do
  curl -sk -o /dev/null -D - -w 'code:%{http_code}\n' --max-time 5 --resolve "shop.localtest.me:$HOST_HTTPS_PORT:127.0.0.1" "$SHOP/" \
    | tr -d '\r' | sed -n 's/^[Xx]-[Dd]mz: //p; s/^code://p' | paste -sd' '
done)
echo "$out" | sort | uniq -c | sed 's/^/    /'
check "dmz-a trafik alıyor"  grep -q '^dmz-a ' <<<"$out"
check "dmz-b trafik alıyor"  grep -q '^dmz-b ' <<<"$out"
check "$(cluster app) ingress'ine ulaşılıyor (200/404, 5xx yok)" bash -c "! grep -vqE ' (200|404)$' <<<\"$out\""
check "edge LB: iki DMZ backend'i de UP" \
  bash -c "[ \$(curl -s 'http://127.0.0.1:$HOST_LB_STATS_PORT/;csv' | grep -E '^dmz_https,dmz-[ab],' | grep -c ',UP,') -eq 2 ]"

log "$(cluster app) -> $(cluster data) (data ingress TCP portları)"
data_ip=$(node_ip data "$NET_DATA")
check "postgres ($data_ip:5432)" probe app postgres:16-alpine pg_isready -h "$data_ip" -p 5432 -t 5
check "redis ($data_ip:6379)"    probe app redis:7-alpine sh -c "redis-cli -h $data_ip ping | grep -q PONG"

log "Segmentasyon (bu erişimlerin ENGELLİ olması beklenir)"
app_ip=$(node_ip app "$NET_APP")
expect_fail "edge LB -/-> $(cluster app) ($app_ip:80)"  docker exec "$EDGE_LB" nc -z -w 3 "$app_ip" 80
expect_fail "dmz-a -/-> data ($data_ip:5432)"           probe dmz-a busybox:1.36 nc -z -w 3 "$data_ip" 5432
expect_fail "data -/-> $(cluster app) ($app_ip:80)"     probe data busybox:1.36 nc -z -w 3 "$app_ip" 80

log "$(cluster mgmt) -> cluster API server'ları"
for r in dmz-a dmz-b app data; do
  ip=$(node_ip "$r" "$(primary_net "$r")")
  check "mgmt -> $(cluster "$r") ($ip:6443)" probe mgmt busybox:1.36 nc -z -w 3 "$ip" 6443
done

echo
if [ "$FAILED" -eq 0 ]; then ok "Tüm ortam kontrolleri geçti"; else fail "$FAILED kontrol başarısız"; exit 1; fi

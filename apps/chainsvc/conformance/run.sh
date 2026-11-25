#!/usr/bin/env bash
# chainsvc davranış sözleşmesi testi (../README.md). Cluster gerekmez; yalnızca Docker.
#
# Kullanım: run.sh <dil...>          (smlab app conformance [dil...|all])
#
# Her dil için: HTTP ve gRPC sunucu/istemci, upstream zinciri, yol aktarımı, keep-alive, hata / gecikme enjeksiyonu,
# gRPC hata ayrıntısının taşınması, istemci zaman aşımı, B3 yayılımı + Zipkin span'leri, yapay işlem süresinin
# dağılımı ve SIGTERM'de istek boşaltma. Birden fazla dil verilirse diller arası tel uyumu (karışık zincir) da sınanır.
set -euo pipefail
source "$(dirname "$0")/../../../lib/common.sh"
source "$SMLAB_ROOT/lib/app.sh"
[ $# -gt 0 ] || set -- $(app_langs)

RUN=smlabc-$$
NET=$RUN
FAILED=0 PASSED=0
cleanup() {
  docker ps -aq --filter "label=smlab.conformance=$RUN" | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

pass() { PASSED=$((PASSED + 1)); ok "$*"; }
nok()  { FAILED=$((FAILED + 1)); fail "$*"; }
expect() { # expect <açıklama> <jq-ifadesi> <json>
  if jq -e "$2" >/dev/null 2>&1 <<<"$3"; then pass "$1"; else nok "$1  [$2]"; echo "$3" | head -c 600 | sed 's/^/      /' >&2; echo >&2; fi
}

# svc <ad> <dil> [ENV=değer...]: chainsvc container'ı (ağdaki DNS adı = <ad>)
svc() {
  local name=$1 lang=$2; shift 2
  local envs=(-e "NAME=$name" -e "MESSAGE=$name v1" -e LOG_LEVEL=error) e
  for e in "$@"; do envs+=(-e "$e"); done
  docker run -d --name "$RUN-$name" --network "$NET" --network-alias "$name" --label "smlab.conformance=$RUN" \
    "${envs[@]}" "$(app_image_of "$lang")" >/dev/null
}
rmsvc() { docker rm -f "$RUN-$1" >/dev/null 2>&1 || true; }
# c <komut...>: istemci container'ında çalıştır (curl, jq, python3)
c() { docker exec "$RUN-client" "$@"; }
get() { c curl -s --max-time 15 "http://$1"; }
wait_ready() { # wait_ready <ad> <http|grpc>
  local i
  for ((i = 0; i < 100; i++)); do
    if [ "$2" = http ]; then c curl -sf -o /dev/null --max-time 1 "http://$1:9090/ready" && return 0
    else c nc -z -w 1 "$1" 9090 && return 0; fi
    sleep 0.1
  done
  nok "$1 hazır olmadı"; docker logs "$RUN-$1" 2>&1 | tail -5 >&2; return 1
}

log "Hazırlık: imajlar ve test ağı"
for l in "$@"; do lang_known "$l" || die "bilinmeyen dil: $l"; app_build "$l"; done
docker network create "$NET" >/dev/null
# istemci + Zipkin toplayıcısı (gelen span'leri /tmp/spans.jsonl dosyasına yazar)
docker run -d --name "$RUN-client" --network "$NET" --network-alias collector --label "smlab.conformance=$RUN" \
  "$NETSHOOT_IMAGE" python3 -c '
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        b = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open("/tmp/spans.jsonl", "a") as f:
            for s in json.loads(b): f.write(json.dumps(s) + "\n")
        self.send_response(202); self.end_headers()
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("", 9411), H).serve_forever()' >/dev/null

conform() { # conform <dil>
  local L=$1 out tid t0 t1 mean code
  log "Dil: $L ($(docker image inspect -f '{{index .Config.Labels "smlab.runtime"}}' "$(app_image_of "$L")"))"
  svc leaf "$L"
  svc mid "$L" SERVER_TYPE=grpc UPSTREAM_URIS=http://leaf:9090
  svc front "$L" "UPSTREAM_URIS=grpc://mid:9090,http://leaf:9090" UPSTREAM_WORKERS=2 TRACING_ZIPKIN=http://collector:9411
  wait_ready leaf http && wait_ready mid grpc && wait_ready front http || return 0

  out=$(get front:9090/)
  expect "HTTP cevabı: ad, tür, kod, gövde, IP, zaman biçimleri" \
    '.name=="front" and .type=="HTTP" and .code==200 and .body=="front v1" and (.ip_addresses|length>0)
     and (.start_time|test("^\\d{4}-\\d\\d-\\d\\dT\\d\\d:\\d\\d:\\d\\d\\.\\d{6}$")) and (.duration|test("^[0-9.]+(ns|µs|ms|s)$"))' "$out"
  expect "gRPC upstream: tür, kod 0, adres, iç içe HTTP çağrısı" \
    '.upstream_calls[0] | .name=="mid" and .type=="gRPC" and .code==0 and .uri=="grpc://mid:9090"
     and .upstream_calls[0].name=="leaf" and .upstream_calls[0].code==200' "$out"
  expect "paralel HTTP upstream (UPSTREAM_WORKERS=2), sıra korunur" '.upstream_calls[1] | .name=="leaf" and .type=="HTTP" and .uri=="http://leaf:9090/"' "$out"
  expect "alan kümesi sözleşmeyle aynı" '(keys - ["body","error","upstream_calls"]) == ["code","duration","end_time","ip_addresses","name","start_time","type","uri"]' "$out"
  out=$(get front:9090/orders/42)
  expect "yol aktarımı (HTTP ve gRPC üzerinden)" '.uri=="/orders/42" and .upstream_calls[1].uri=="http://leaf:9090/orders/42"
     and .upstream_calls[0].upstream_calls[0].uri=="http://leaf:9090/orders/42"' "$out"
  out=$(c curl -s -o /dev/null -o /dev/null -w '%{num_connects} ' http://leaf:9090/ http://leaf:9090/)
  [ "$out" = "1 0 " ] && pass "HTTP keep-alive (ikinci istek aynı bağlantıda)" || nok "HTTP keep-alive: bağlantı sayıları '$out'"
  out=$(c curl -s -w '|%{content_type}' http://leaf:9090/ready)
  [[ "$out" == "OK"*"|text/plain"* ]] && pass "/ready -> OK" || nok "/ready: $out"

  log "$L: B3 yayılımı ve Zipkin span'leri"
  tid=$(openssl rand -hex 16)
  c curl -s -o /dev/null -H "X-B3-TraceId: $tid" -H "X-B3-SpanId: $(openssl rand -hex 8)" -H "X-B3-Sampled: 1" http://front:9090/
  sleep 2.5
  out=$(c sh -c "cat /tmp/spans.jsonl 2>/dev/null" | jq -s --arg t "$tid" '[.[] | select(.traceId==$t)]')
  expect "front span'leri gelen trace kimliğiyle (SERVER + 2 CLIENT)" \
    '([.[] | select(.localEndpoint.serviceName=="front")] | (map(.kind)|sort) == ["CLIENT","CLIENT","SERVER"])
     and all(.[]; (.id|length)==16 and (.timestamp|type)=="number" and (.duration|type)=="number")' "$out"
  # yayılımı görmek için mid de span göndersin
  rmsvc mid; svc mid "$L" SERVER_TYPE=grpc UPSTREAM_URIS=http://leaf:9090 TRACING_ZIPKIN=http://collector:9411; wait_ready mid grpc
  tid=$(openssl rand -hex 16)
  c curl -s -o /dev/null -H "X-B3-TraceId: $tid" -H "X-B3-SpanId: $(openssl rand -hex 8)" http://front:9090/
  sleep 2.5
  out=$(c sh -c "cat /tmp/spans.jsonl" | jq -s --arg t "$tid" '[.[] | select(.traceId==$t)]')
  # B3 ortak span modeli: sunucu span'i istemcinin span kimliğini paylaşır, ebeveyni çağıranın sunucu span'idir
  expect "B3 gRPC metadata ile yayılır: mid SERVER span'i = front CLIENT span'i (ortak span)" \
    '(map(select(.localEndpoint.serviceName=="front" and .kind=="CLIENT" and .name=="grpc://mid:9090"))[0].id) as $p
     | any(.[]; .localEndpoint.serviceName=="mid" and .kind=="SERVER" and .id==$p and .name=="/chain.Chain/Call")' "$out"

  log "$L: hata ve gecikme enjeksiyonu"
  rmsvc leaf; svc leaf "$L" ERROR_RATE=1 ERROR_CODE=503; wait_ready leaf http
  out=$(c curl -s -w '\n%{http_code}' http://leaf:9090/); code=${out##*$'\n'}; out=${out%$'\n'*}
  expect "HTTP hata enjeksiyonu: ERROR_CODE durum kodu ve gövdede hata" '.code==503 and .error=="Service error automatically injected"' "$out"
  [ "$code" = 503 ] && pass "HTTP durum satırı 503" || nok "HTTP durum satırı: $code"
  out=$(c curl -s -w '\n%{http_code}' http://front:9090/); code=${out##*$'\n'}; out=${out%$'\n'*}
  expect "upstream hatası: front 500, HTTP upstream 503" '.code==500 and (.error|startswith("Error processing upstream request")) and .upstream_calls[1].code==503' "$out"
  expect "gRPC hata ayrıntısı taşınır: mid kod 13 (Internal), içinde leaf 503" \
    '.upstream_calls[0] | .code==13 and .type=="gRPC" and (.error|startswith("Error processing upstream request")) and .upstream_calls[0].code==503' "$out"
  [ "$code" = 500 ] && pass "front durum satırı 500" || nok "front durum satırı: $code"
  rmsvc leaf; svc leaf "$L"; wait_ready leaf http
  rmsvc mid; svc mid "$L" SERVER_TYPE=grpc ERROR_RATE=1; wait_ready mid grpc
  out=$(get front:9090/)
  expect "gRPC sunucuda hata enjeksiyonu -> kod 13" '.upstream_calls[0] | .code==13 and .error=="Service error automatically injected"' "$out"
  rmsvc mid; svc mid "$L" SERVER_TYPE=grpc UPSTREAM_URIS=http://leaf:9090; wait_ready mid grpc
  svc slow "$L" ERROR_RATE=1 ERROR_TYPE=delay ERROR_DELAY=300ms; wait_ready slow http
  out=$(c curl -s -o /dev/null -w '%{time_total}' http://slow:9090/)
  awk -v t="$out" 'BEGIN{exit !(t >= 0.3 && t < 0.6)}' && pass "gecikme enjeksiyonu (300 ms -> ${out} sn)" || nok "gecikme enjeksiyonu: ${out} sn"
  svc impatient "$L" UPSTREAM_URIS=http://slow:9090 HTTP_CLIENT_REQUEST_TIMEOUT=100ms; wait_ready impatient http
  out=$(get impatient:9090/)
  expect "istemci zaman aşımı (HTTP_CLIENT_REQUEST_TIMEOUT): upstream kod -1, çağıran 500" '.code==500 and .upstream_calls[0].code==-1 and (.upstream_calls[0].error|length>0)' "$out"
  rmsvc impatient; rmsvc slow

  log "$L: yapay işlem süresi (TIMING_*: 1ms / 2ms / 5ms, beklenen ortalama 1.215 ms)"
  svc timing "$L" TIMING_50_PERCENTILE=1ms TIMING_90_PERCENTILE=2ms TIMING_99_PERCENTILE=5ms; wait_ready timing http
  mean=$(c sh -c 'for i in $(seq 400); do curl -s http://timing:9090/; done' | jq -rs '
    def ms: if test("ms$") then rtrimstr("ms")|tonumber elif test("µs$") then rtrimstr("µs")|tonumber/1000
            elif test("ns$") then rtrimstr("ns")|tonumber/1e6 else rtrimstr("s")|tonumber*1000 end;
    [.[].duration|ms] | add/length | .*1000|round/1000')
  local metric_line="ortalama işlem süresi $mean ms (400 istek)"
  awk -v m="$mean" 'BEGIN{exit !(m >= 1.1 && m <= 1.6)}' && pass "$metric_line" || nok "$metric_line — beklenen 1.1..1.6"
  echo "$L $mean" >> "$STATE_DIR/conformance-timing.txt"
  rmsvc timing

  log "$L: SIGTERM'de devam eden isteğin tamamlanması"
  svc drain "$L" TIMING_50_PERCENTILE=2s; wait_ready drain http
  c sh -c 'curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://drain:9090/ > /tmp/drain.code' &
  local bg=$!
  sleep 0.7
  t0=$(date +%s.%N); docker stop -t 10 "$RUN-drain" >/dev/null; t1=$(date +%s.%N)
  wait $bg || true
  code=$(c cat /tmp/drain.code)
  [ "$code" = 200 ] && pass "SIGTERM: devam eden istek 200 ile tamamlandı (kapanış $(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}') sn)" \
    || nok "SIGTERM: devam eden istek kodu $code"
  rmsvc drain; rmsvc front; rmsvc mid; rmsvc leaf
}

mixed() { # mixed <front-dili> <mid-dili> <leaf-dili>: diller arası tel uyumu
  local out
  log "Karışık zincir: front=$1 -> mid(gRPC)=$2 -> leaf=$3"
  svc leaf "$3"; svc mid "$2" SERVER_TYPE=grpc UPSTREAM_URIS=http://leaf:9090; svc front "$1" UPSTREAM_URIS=grpc://mid:9090
  wait_ready leaf http && wait_ready mid grpc && wait_ready front http || return 0
  out=$(get front:9090/x)
  expect "$1 -> $2 -> $3: zincir tam, yol aktarıldı" '.code==200 and .upstream_calls[0].code==0 and .upstream_calls[0].upstream_calls[0].uri=="http://leaf:9090/x"' "$out"
  rmsvc leaf; svc leaf "$3" ERROR_RATE=1 ERROR_CODE=503; wait_ready leaf http
  out=$(get front:9090/)
  expect "$1 -> $2 -> $3: gRPC hata ayrıntısı diller arasında taşınır" '.code==500 and .upstream_calls[0].code==13 and .upstream_calls[0].upstream_calls[0].code==503' "$out"
  rmsvc front; rmsvc mid; rmsvc leaf
}

: > "$STATE_DIR/conformance-timing.txt"
for l in "$@"; do conform "$l"; done
if [ $# -gt 1 ]; then
  mixed "$1" "$2" "$1"
  mixed "$2" "$1" "$2"
fi

echo
log "Sonuç: $PASSED geçti, $FAILED başarısız"
[ "$FAILED" -eq 0 ]

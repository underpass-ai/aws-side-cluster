#!/usr/bin/env bash
# Smoke test integral del cluster AWS-side. Cold-start via demand-gateway, valida
# la cadena completa (nodos, Calico, MetalLB, proxies, EC2->MetalLB, worker<->worker,
# DNS privado) y PARA los EC2 al final (trap). Reporta PASS/FAIL por check.
#
# Uso:  AWS_REGION=eu-south-2 scripts/cluster-test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
# Valores host-specific (IP publica de casa, etc.) fuera del repo: .env.local
[ -f .env.local ] && . ./.env.local
export AWS_REGION="${AWS_REGION:-eu-south-2}" AWS_DEFAULT_REGION="${AWS_REGION:-eu-south-2}"
GW="${GW:-http://127.0.0.1:18080}"
K="kubectl --request-timeout=8s"
LOG(){ printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1 ${2:+| $2}"; FAIL=$((FAIL+1)); }
chk(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "got=[$2] want=[$3]"; fi; }

cleanup(){ echo; LOG "CLEANUP: parar EC2"; scripts/ec2-pool.sh scale 0 >/dev/null 2>&1 && LOG "stop enviado" || LOG "stop FALLO - revisar"; }
trap cleanup EXIT INT TERM

nodeReady(){ $K get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null; }

# Espera (retry) a que una condición se cumpla; evita falsos negativos por timing.
wait_until(){ # <segundos> <comando...>; sale 0 si se cumple
  local d=$(( $(date +%s) + $1 )); shift
  while [ "$(date +%s)" -lt "$d" ]; do "$@" && return 0; sleep 6; done
  return 1
}
calico_ready(){ [ "$($K -n calico-system get pods -l k8s-app=calico-node -o wide --no-headers 2>/dev/null | awk -v n="$1" '$7==n{print $2}')" = "1/1" ]; }
speakers_on_workers(){ [ "$($K -n metallb-system get pods -l component=speaker -o wide --no-headers 2>/dev/null | awk '$7 ~ /aws-worker/{c++} END{print c+0}')" -ge 2 ]; }

LOG "===== 0) esperar pool stopped (cold start real) ====="
wait_until 240 sh -c '[ "$(aws ec2 describe-instances --filters Name=tag:Project,Values=aws-side-cluster Name=tag:Role,Values=worker Name=instance-state-name,Values=running,pending,stopping --query "length(Reservations[].Instances[])" --output text 2>/dev/null)" = "0" ]' && LOG "pool stopped"

LOG "===== 1) COLD WAKE via gateway /wake ====="
HC=$(curl -s --max-time 540 -o /tmp/wake.json -w '%{http_code}' "$GW/wake" 2>/dev/null)
LOG "/wake -> HTTP $HC"
chk "gateway /wake 200" "$HC" "200"

LOG "===== 2) NODOS ====="
chk "aws-worker-1 Ready" "$(nodeReady aws-worker-1)" "True"
chk "aws-worker-2 Ready" "$(nodeReady aws-worker-2)" "True"
chk "control-plane Ready" "$(nodeReady wrx80-node1)" "True"

LOG "===== 3) CNI + MetalLB (con espera) ====="
wait_until 120 calico_ready aws-worker-1 && ok "calico-node aws-worker-1 1/1" || no "calico-node aws-worker-1 1/1"
wait_until 120 calico_ready aws-worker-2 && ok "calico-node aws-worker-2 1/1" || no "calico-node aws-worker-2 1/1"
wait_until 120 speakers_on_workers && ok "MetalLB speakers en 2 workers" || no "MetalLB speakers en 2 workers"

LOG "===== 4) SMOKE (pod en worker AWS) ====="
$K -n default delete pod smoke --ignore-not-found --now >/dev/null 2>&1
$K -n default run smoke --image=registry.k8s.io/pause:3.10 --restart=Never \
  --overrides='{"spec":{"nodeSelector":{"underpass.ai/node-pool":"aws-poc"}}}' >/dev/null 2>&1
$K -n default wait --for=condition=Ready pod/smoke --timeout=90s >/dev/null 2>&1 || true
sn=$($K -n default get pod smoke -o jsonpath='{.spec.nodeName}' 2>/dev/null)
[ "$($K -n default get pod smoke -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ] && echo "$sn" | grep -q aws-worker \
  && ok "smoke Running en $sn" || no "smoke pod" "node=$sn"
$K -n default delete pod smoke --now >/dev/null 2>&1

LOG "===== 5) GATEWAY PROXY ====="
for p in /hostname /worker-1/hostname /worker-2/hostname; do
  b=$(curl -s --max-time 20 "$GW$p" 2>/dev/null)
  c=$(curl -s --max-time 20 -o /dev/null -w '%{http_code}' "$GW$p" 2>/dev/null)
  { [ "$c" = "200" ] && echo "$b" | grep -q aws-echo; } && ok "proxy $p -> $b" || no "proxy $p" "code=$c"
done
chk "proxy via MetalLB .243" "$(curl -s --max-time 20 -o /dev/null -w '%{http_code}' http://192.168.1.243/worker-1/hostname 2>/dev/null)" "200"

LOG "===== 6) EC2->MetalLB + worker<->worker ====="
$K -n default delete pod ctest --ignore-not-found --now >/dev/null 2>&1
$K -n default run ctest --image=busybox:1.36 --restart=Never \
  --overrides='{"spec":{"nodeSelector":{"underpass.ai/worker-index":"1"}}}' \
  --command -- sh -c 'nc -w4 -z 192.168.1.241 80; echo m241=$?; nc -w4 -z 192.168.1.242 80; echo x242=$?' >/dev/null 2>&1
$K -n default wait --for=jsonpath='{.status.phase}'=Succeeded pod/ctest --timeout=60s >/dev/null 2>&1 || true
l=$($K -n default logs ctest 2>/dev/null); echo "$l" | sed 's/^/    /'
chk "EC2 pod -> MetalLB .241" "$(echo "$l" | grep -oE 'm241=[0-9]+' | cut -d= -f2)" "0"
chk "worker<->worker (.242 backend remoto)" "$(echo "$l" | grep -oE 'x242=[0-9]+' | cut -d= -f2)" "0"
$K -n default delete pod ctest --now >/dev/null 2>&1

LOG "===== 7) DNS privado (hostNetwork + dnsPolicy:Default = resolver VPC) ====="
if [ -z "${WG_HOME_IP:-}" ]; then
  no "DNS privado aws-vpc-wg" "WG_HOME_IP no definido (crear .env.local, ver .env.local.example)"
else
  WG_HOME_IP_RE=$(printf '%s' "$WG_HOME_IP" | sed 's/\./\\\\./g')
  $K -n default delete pod dnstest --ignore-not-found --now >/dev/null 2>&1
  $K -n default run dnstest --image=busybox:1.36 --restart=Never \
    --overrides='{"spec":{"hostNetwork":true,"dnsPolicy":"Default","nodeSelector":{"underpass.ai/worker-index":"1"}}}' \
    --command -- sh -c 'nslookup aws-vpc-wg.underpassai.com 2>/dev/null | grep -oE "'"$WG_HOME_IP_RE"'" | head -1 && echo dns=ok || echo dns=fail' >/dev/null 2>&1
  $K -n default wait --for=jsonpath='{.status.phase}'=Succeeded pod/dnstest --timeout=60s >/dev/null 2>&1 || true
  chk "DNS privado aws-vpc-wg -> $WG_HOME_IP" "$($K -n default logs dnstest 2>/dev/null | grep -oE 'dns=[a-z]+' | cut -d= -f2)" "ok"
  $K -n default delete pod dnstest --now >/dev/null 2>&1
fi

echo
LOG "===== RESULTADO: ${PASS} PASS / ${FAIL} FAIL ====="
[ "$FAIL" = "0" ] && LOG "CLUSTER OK" || LOG "revisar fallos arriba"
exit 0

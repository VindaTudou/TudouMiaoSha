#!/usr/bin/env bash
# V1 容量扫描：固定到达率，逐级加压，看 QPS 在哪封顶
#
# 为什么要扫描而不是只测一个点：
#   只测一个数你不知道它是"还没饱和"还是"早就饱和了"。扫描才能找到拐点。
#
# 前提：应用在 127.0.0.1:8080 跑着（make app-bg），MySQL 在容器里

set -u
cd "$(dirname "$0")/.."
K6=$(find tools -name k6 -type f -path '*/bin/*' | head -1)
M="docker exec -i -e MYSQL_PWD=root miaosha-mysql mysql -uroot --default-character-set=utf8mb4 miaosha"
DURATION=${DURATION:-20s}
RATES=${RATES:-"500 1000 2000 4000"}

printf '%-8s %-12s %-10s %-10s %-10s %-10s %-8s\n' 到达率 实际下单速率 p99 409率 5xx率 MySQL_CPU APP_CPU
printf '%-8s %-12s %-10s %-10s %-10s %-10s %-8s\n' ------ ------------ --- ----- ----- --------- -------

for R in $RATES; do
  # 每次重置：库存拉满（保证不卖完），清空订单
  $M -e "UPDATE product SET stock=10000000 WHERE id=1; DELETE FROM orders;" 2>/dev/null

  # 背景采样 CPU
  ( for i in $(seq 1 25); do
      docker stats --no-stream --format '{{.CPUPerc}}' miaosha-mysql 2>/dev/null | tr -d '%'
      sleep 0.7
    done ) > /tmp/cpu-mysql.txt 2>/dev/null &
  (
    for i in $(seq 1 25); do
      curl -sS --max-time 2 http://127.0.0.1:8080/actuator/metrics/process.cpu.usage 2>/dev/null \
        | python3 -c 'import json,sys
try: print(round(json.load(sys.stdin)["measurements"][0]["value"]*100,1))
except Exception: pass'
      sleep 0.7
    done
  ) > /tmp/cpu-app.txt 2>/dev/null &

  "$K6" run --quiet --summary-export="/tmp/k6-$R.json" \
    -e BROWSE_ON=0 -e RATE="$R" -e SECKILL_DURATION="$DURATION" \
    loadtest/k6/v1.js > /tmp/k6-$R.log 2>&1

  wait

  python3 - "$R" <<'PY'
import json, sys, statistics
rate = sys.argv[1]
d = json.load(open(f'/tmp/k6-{rate}.json'))['metrics']
ok = d.get('order_success', {}).get('count', 0)
so = d.get('order_soldout', {}).get('count', 0)
ot = d.get('order_other', {}).get('count', 0)
dur = d.get('http_req_duration{scenario:seckill}', {})
p99 = dur.get('p(99)', 0)
total = ok + so + ot
def read(p):
    try:
        xs = [float(x) for x in open(p).read().split()]
        return statistics.mean(xs) if xs else 0
    except Exception:
        return 0
mc = read('/tmp/cpu-mysql.txt')
ac = read('/tmp/cpu-app.txt')
print(f"{rate:<8} {ok/20:<12.0f} {p99:<10.1f} {so*100/total if total else 0:<10.1f} {ot*100/total if total else 0:<10.1f} {mc:<10.1f} {ac:<8.1f}")
PY
done

$M -e "UPDATE product SET stock=1000 WHERE id=1; DELETE FROM orders;" 2>/dev/null

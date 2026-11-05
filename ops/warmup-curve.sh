#!/usr/bin/env bash
# 预热曲线实验：同一个 JVM，连续 N 轮，看 P99 随【累计处理订单数】怎么变
#
# 为什么要做：
#   M1 里同一份代码、同样 3,000/s，P99 测出过 13ms 和 243ms。
#   差别只有一个：这台 JVM 跑过多少请求。
#   所以"预热"不是一个感觉，是一个必须被量化、被排除的变量。
#
# 规矩：每轮开始前等 Kafka 积压排空，否则积压会污染延迟（M1 踩过）。
#
# 用法：ops/warmup-curve.sh [轮数] [每轮秒数]

set -u
cd "$(dirname "$0")/.."

ROUNDS=${1:-5}
DUR=${2:-20s}
RATE=3000
K6=$(find tools -name k6 -type f -path '*/bin/*' | head -1)
M="docker exec -i -e MYSQL_PWD=root miaosha-mysql mysql -uroot --default-character-set=utf8mb4 miaosha"
OUT=${3:-/tmp/warmup.tsv}
: > "$OUT"

q() {
  curl -s -G 'http://127.0.0.1:9090/api/v1/query' --data-urlencode "query=$1" \
    | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)["data"]["result"]
    print(d[0]["value"][1] if d else "0")
except Exception:
    print("0")'
}

drain() {
  local t0=$(date +%s)
  while :; do
    l=$(q 'sum(kafka_consumer_fetch_manager_records_lag)')
    case "$l" in ''|*[!0-9.]*) l=0 ;; esac
    [ "${l%%.*}" -eq 0 ] && break
    [ $(( $(date +%s) - t0 )) -ge 240 ] && break
    sleep 3
  done
}

restart_app() {
  # -sTCP:LISTEN 必须加：否则 lsof 会把"正在连 8080 的 Prometheus"也算进来（M1 踩过）
  local pid
  pid=$(lsof -ti tcp:8080 -sTCP:LISTEN 2>/dev/null || true)
  [ -n "$pid" ] && kill $pid 2>/dev/null
  sleep 6
  mkdir -p logs
  # 打开 JIT 和 GC 日志：事后能数出"第几秒之后不再有新编译"
  #
  # 注意：-Xlog:jit+compilation=info 在 JDK 17 上会被【静默忽略】，日志 0 字节，不报错。
  # 必须用 -XX:+PrintCompilation（输出到 stdout，也就是 logs/app-host.log）。
  INSTANCE_ID=host nohup java -Xms256m -Xmx384m \
    -XX:+PrintCompilation \
    -Xlog:gc*:file=logs/gc.log:time,uptime \
    -jar app/target/miaosha.jar > logs/app-host.log 2>&1 &
  for i in $(seq 1 60); do
    curl -s -m 2 http://127.0.0.1:8080/actuator/health >/dev/null 2>&1 && return 0
    sleep 2
  done
  echo "❌ 应用没起来"; exit 1
}

echo "=== 重启应用（冷 JVM，带 JIT/GC 日志）==="
restart_app
echo "✅ 应用已就绪，PID=$(lsof -ti tcp:8080 -sTCP:LISTEN)"
echo

printf '%-6s %-12s %-8s %-8s %-8s %-9s %-8s\n' 轮次 累计订单 P50 P95 P99 QPS 丢弃
for r in $(seq 1 "$ROUNDS"); do
  drain
  $M -e "UPDATE product SET stock=10000000 WHERE id=1; DELETE FROM orders;" >/dev/null 2>&1
  curl -sS -m 5 -X POST http://127.0.0.1:8080/api/admin/preheat/1 >/dev/null
  # 每轮固定 1 单热身（Kafka 生产者懒加载）
  curl -sS -m 5 -X POST http://127.0.0.1:8080/api/orders \
    -H 'Content-Type: application/json' -d '{"userId":1,"productId":1,"quantity":1}' >/dev/null
  sleep 3

  cumulative=$(q 'sum(miaosha_order_total)')

  "$K6" run --quiet --summary-export="/tmp/warm-$r.json" \
    -e RATE="$RATE" -e SECKILL_DURATION="$DUR" -e MAX_VUS=2000 \
    loadtest/k6/v2.js > /dev/null 2>&1

  python3 - "$r" "$cumulative" "$OUT" <<'PY'
import json, sys
r, cumulative, out = sys.argv[1], sys.argv[2], sys.argv[3]
m = json.load(open(f'/tmp/warm-{r}.json'))['metrics']
d = m['http_req_duration{scenario:seckill}']
row = (r, int(float(cumulative)), round(d['med']), round(d['p(95)']),
       round(d['p(99)']), round(m['http_reqs']['rate']),
       int(m.get('dropped_iterations', {}).get('count', 0)))
print('%-6s %-12s %-8s %-8s %-8s %-9s %-8s' % row)
with open(out, 'a') as f:
    f.write('\t'.join(map(str, row)) + '\n')
PY
done

echo
echo "结果写入 $OUT"
echo "JIT 日志: logs/jit.log   GC 日志: logs/gc.log"

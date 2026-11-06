#!/usr/bin/env bash
# 堆大小对照实验：证明/否定「8,000/s 的崩溃是堆太小导致的」
#
# 纪律：
#   - 只改一个变量：-Xmx。其余参数（Xms、GC 类型、代码、到达率、时长）完全不变
#   - 每轮都重启 JVM → 两轮的"预热程度"从同一起点算
#   - 每轮先跑一轮热身（丢弃）→ 排除 M1 测出来的预热曲线影响
#   - 每轮前清空 topic → 排除积压对消费者/CPU 的干扰
#
# 用法：loadtest/heap-ab.sh 384m 1024m

set -u
cd "$(dirname "$0")/.."

K6=$(find tools -name k6 -type f -path '*/bin/*' | head -1)
M="docker exec -i -e MYSQL_PWD=root miaosha-mysql mysql -uroot --default-character-set=utf8mb4 miaosha"
KA="docker exec miaosha-kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server 127.0.0.1:29092"
TOPIC=seckill-order
RATE=8000
DUR=60s
OUT=/tmp/heap-ab.tsv
: > "$OUT"

restart_app() {
  local heap=$1
  local pid
  pid=$(lsof -ti tcp:8080 -sTCP:LISTEN 2>/dev/null || true)
  [ -n "$pid" ] && kill $pid 2>/dev/null
  sleep 6
  mkdir -p logs
  INSTANCE_ID=host nohup java -Xms256m -Xmx"$heap" \
    -Xlog:gc*:file=logs/gc-"$heap".log:time,uptime \
    -jar app/target/miaosha.jar > logs/app-"$heap".log 2>&1 &
  for i in $(seq 1 60); do
    curl -s -m 2 http://127.0.0.1:8080/actuator/health >/dev/null 2>&1 && return 0
    sleep 2
  done
  echo "❌ 应用没起来"; exit 1
}

clear_topic() {
  $KA --delete --topic "$TOPIC" >/dev/null 2>&1
  for i in $(seq 1 30); do
    $KA --list 2>/dev/null | grep -qx "$TOPIC" || break
    sleep 1
  done
  $KA --create --topic "$TOPIC" --partitions 3 --replication-factor 1 >/dev/null 2>&1
  sleep 12      # 等消费组 rebalance 完成，否则会污染下一轮（M2-A 踩过）
}

reset_data() {
  $M -e "UPDATE product SET stock=10000000 WHERE id=1; DELETE FROM orders;" >/dev/null 2>&1
  curl -sS -m 5 -X POST http://127.0.0.1:8080/api/admin/preheat/1 >/dev/null
  curl -sS -m 5 -X POST http://127.0.0.1:8080/api/orders -H 'Content-Type: application/json' \
    -d '{"userId":1,"productId":1,"quantity":1}' >/dev/null
}

run_case() {
  local heap=$1 tag=$2
  echo "=============================================="
  echo " 用例 -Xmx${heap}"
  echo "=============================================="
  restart_app "$heap"
  clear_topic
  reset_data
  echo "  热身：3,000/s × 30s（丢弃）"
  "$K6" run --quiet -e RATE=3000 -e SECKILL_DURATION=30s -e BASE=http://127.0.0.1:8080 \
    -e MAX_VUS=6000 loadtest/k6/v3.js >/dev/null 2>&1

  clear_topic
  reset_data
  echo "  正式：${RATE}/s × ${DUR}"
  python3 ops/sampler.py "/tmp/heap-$tag.csv" 75 http://127.0.0.1:8080 >/dev/null 2>&1 &
  sampler=$!
  sleep 3
  "$K6" run --quiet --summary-export="/tmp/k6-heap-$tag.json" \
    -e RATE="$RATE" -e SECKILL_DURATION="$DUR" -e BASE=http://127.0.0.1:8080 \
    -e MAX_VUS=$(( RATE * 2 )) loadtest/k6/v3.js >/dev/null 2>&1
  wait $sampler 2>/dev/null

  python3 - "$heap" "$tag" "$OUT" <<'PY'
import csv, json, sys
heap, tag, out = sys.argv[1], sys.argv[2], sys.argv[3]
m = json.load(open(f'/tmp/k6-heap-{tag}.json'))['metrics']
d = m.get('http_req_duration', {})
rows = list(csv.DictReader(open(f'/tmp/heap-{tag}.csv')))
busy = max(int(r['busy']) for r in rows)
heap_pk = max(float(r['heap_mb']) for r in rows)
gc0, gc1 = int(rows[0]['gc_cnt']), int(rows[-1]['gc_cnt'])
gp0, gp1 = float(rows[0]['gc_pause_s']), float(rows[-1]['gc_pause_s'])
qps = m['http_reqs']['rate']
drop = m.get('dropped_iterations', {}).get('count', 0)
reqs = m['http_reqs']['count']
succ = m.get('order_success', {}).get('count', 0)
other = m.get('order_other', {}).get('count', 0)
row = (heap, round(qps), int(reqs), round(d.get('med', 0)), round(d.get('p(95)', 0)),
       round(d.get('p(99)', 0)), round(d.get('max', 0)), int(drop),
       busy, round(heap_pk), gc1 - gc0, round(gp1 - gp0, 2),
       round(succ * 100 / max(1, reqs), 2), int(other))
print(f"  QPS {row[1]}  请求 {row[2]}  P50 {row[3]}  P95 {row[4]}  P99 {row[5]}  最长 {row[6]}")
print(f"  丢弃 {row[7]}  线程峰 {row[8]}  堆峰 {row[9]}MB  GC {row[10]} 次 / {row[11]}s  成功 {row[12]}%")
with open(out, 'a') as f:
    f.write('\t'.join(map(str, row)) + '\n')
PY
  echo
}

for spec in "$@"; do
  run_case "$spec" "${spec%m}"
done

echo "=============================================="
echo " 汇总"
echo "=============================================="
printf '%-7s %-6s %-8s %-6s %-6s %-6s %-7s %-8s %-8s %-7s %-6s %-7s\n' \
  堆 QPS 请求数 P50 P95 P99 丢弃 线程峰 堆峰 GC次数 GC暂停 成功%
while IFS=$'\t' read -r heap qps reqs p50 p95 p99 mx drop busy hp gc gs sc ot; do
  printf '%-7s %-6s %-8s %-6s %-6s %-6s %-7s %-8s %-6sMB %-7s %-6ss %-7s\n' \
    "$heap" "$qps" "$reqs" "$p50" "$p95" "$p99" "$drop" "$busy" "$hp" "$gc" "$gs" "$sc"
done < "$OUT"
echo
echo "明细 CSV: /tmp/heap-384.csv /tmp/heap-1024.csv"

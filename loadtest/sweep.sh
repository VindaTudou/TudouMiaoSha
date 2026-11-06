#!/usr/bin/env bash
# 实验 A：阶梯扫描找容量拐点
#
# 要回答的问题：3,000/s 干净、5,000/s 开始崩，中间的拐点到底在哪一档？
#
# 纪律（每一条都是前面踩出来的）：
#   1. 每档前等 Kafka lag 归零      —— 积压会污染延迟（M1：17ms vs 85ms）
#   2. 每档前重置库存 + 预热         —— Redis 里是上一轮的旧值
#   3. 每档先下 1 单                —— Kafka 生产者懒加载，否则 P99 含冷启动
#   4. 全程采样忙碌线程              —— Tomcat 顶到 200 就是排队开始
#   5. 检查 dropped_iterations      —— k6 没发出去，测的是压测机的上限
#
# 用法：loadtest/sweep.sh [起始] [结束] [步长] [每档秒数]
#   默认：1000 5000 500 20

set -u
cd "$(dirname "$0")/.."

FROM=${1:-1000}
TO=${2:-5000}
STEP=${3:-500}
DUR=${4:-20s}
DUR_SEC=${DUR%s}
OUT=${OUT:-/tmp/sweep.tsv}
K6=$(find tools -name k6 -type f -path '*/bin/*' | head -1)
M="docker exec -i -e MYSQL_PWD=root miaosha-mysql mysql -uroot --default-character-set=utf8mb4 miaosha"
BASE=${BASE:-http://127.0.0.1:8080}   # 可指向网关 http://127.0.0.1:8000

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

KA="docker exec miaosha-kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server 127.0.0.1:29092"
TOPIC=seckill-order

# 快速排空：删掉 topic 再建一个空的。
# 为什么要这个：消费者只有 ~300/s，一次 20 秒 3,000/s 的压测会留下 6 万条，
# 排空要 3 分钟——比压测本身还久。做"同一档跑多次"时这不现实。
# 代价：丢掉历史消息，所以只用于请求侧的容量测试，不能用于对账。
clear_topic() {
  $KA --delete --topic "$TOPIC" >/dev/null 2>&1
  for i in $(seq 1 30); do
    $KA --list 2>/dev/null | grep -qx "$TOPIC" || break
    sleep 1
  done
  $KA --create --topic "$TOPIC" --partitions 3 --replication-factor 1 >/dev/null 2>&1
  # 建完不能立刻开压：消费者要重新加入消费组（rebalance），生产者要刷新元数据。
  # 上一轮就是因为这个干扰，测出一个 132ms 的假点。
  sleep 12
}

drain() {
  if [ "${FAST_CLEAR:-0}" = "1" ]; then clear_topic; return; fi
  local t0=$(date +%s)
  while :; do
    l=$(q 'sum(kafka_consumer_fetch_manager_records_lag)')
    case "$l" in ''|*[!0-9.]*) l=0 ;; esac
    [ "${l%%.*}" -eq 0 ] && break
    [ $(( $(date +%s) - t0 )) -ge 300 ] && { echo "  (排空超时，lag=$l)"; break; }
    sleep 3
  done
}

busy() {  # 当前忙碌线程数，读 actuator 的小 JSON（不去拉 1600 行的 prometheus 端点）
  curl -s -m 2 "$BASE/actuator/metrics/tomcat.threads.busy" \
    | python3 -c 'import json,sys
try: print(int(json.load(sys.stdin)["measurements"][0]["value"]))
except Exception: print(0)' 2>/dev/null || echo 0
}

if [ -n "${RATES:-}" ]; then
  RATE_LIST=$RATES
  DESC="指定档位: $RATES"
else
  RATE_LIST=$(seq "$FROM" "$STEP" "$TO")
  DESC="${FROM} → ${TO} 步长 ${STEP}"
fi

echo "=============================================================="
echo " 实验 A：${DESC}  每档 ${DUR}"
echo "=============================================================="

# ---------- 热身（整轮丢弃，理由见 M1 预热曲线）----------
echo "[热身] 3,000/s 跑 ${DUR}，结果丢弃"
$M -e "UPDATE product SET stock=10000000 WHERE id=1; DELETE FROM orders;" >/dev/null 2>&1
curl -sS -m 5 -X POST $BASE/api/admin/preheat/1 >/dev/null
curl -sS -m 5 -X POST $BASE/api/orders -H 'Content-Type: application/json' \
  -d '{"userId":1,"productId":1,"quantity":1}' >/dev/null
sleep 3
"$K6" run --quiet -e RATE=3000 -e SECKILL_DURATION="$DUR" -e MAX_VUS=8000 \
  loadtest/k6/v3.js >/dev/null 2>&1
echo "[热身] 完成"
echo

printf '%-7s %-7s %-8s %-7s %-7s %-7s %-6s %-6s %-5s %s\n' \
  目标QPS 实际QPS 成功/s P50 P95 P99 丢弃 线程峰 5xx 可信
printf '%s\n' "-------------------------------------------------------------------------------"

for rate in $RATE_LIST; do
  drain
  $M -e "UPDATE product SET stock=10000000 WHERE id=1; DELETE FROM orders;" >/dev/null 2>&1
  curl -sS -m 5 -X POST $BASE/api/admin/preheat/1 >/dev/null
  curl -sS -m 5 -X POST $BASE/api/orders -H 'Content-Type: application/json' \
    -d '{"userId":1,"productId":1,"quantity":1}' >/dev/null
  sleep 3

  # 采样忙碌线程（1 秒一次，取峰值）
  : > /tmp/busy-$rate.txt
  ( for i in $(seq 1 40); do busy >> /tmp/busy-$rate.txt; sleep 1; done ) &
  sampler=$!

  "$K6" run --quiet --summary-export="/tmp/k6-sweep-$rate.json" \
    -e RATE="$rate" -e SECKILL_DURATION="$DUR" \
    loadtest/k6/v3.js > "/tmp/k6-sweep-$rate.log" 2>&1

  kill $sampler 2>/dev/null; wait $sampler 2>/dev/null

  python3 - "$rate" "$OUT" "$DUR_SEC" <<'PY'
import json, sys
rate, out, dur = sys.argv[1], sys.argv[2], float(sys.argv[3])
m = json.load(open(f'/tmp/k6-sweep-{rate}.json'))['metrics']
# 单场景时 k6 不一定会导出带 scenario 标签的 key，做个兜底
d = m.get('http_req_duration{scenario:seckill}') or m.get('http_req_duration', {})
qps = m.get('http_reqs', {}).get('rate', 0)
drop = int(m.get('dropped_iterations', {}).get('count', 0))
reqs = int(m.get('http_reqs', {}).get('count', 1)) or 1
succ = m.get('order_success', {}).get('count', 0)
other = int(m.get('order_other', {}).get('count', 0))
rl = int(m.get('order_ratelimited', {}).get('count', 0))
drop_pct = drop * 100 / max(1, drop + reqs)
samples = sorted(int(x) for x in open(f'/tmp/busy-{rate}.txt').read().split() if x.strip())
samples = samples or [0]
busy = samples[min(len(samples) - 1, int(len(samples) * 0.9))]   # p90，避开单次尖刺

# 可信度：k6 丢超过 5% 说明压测机自己供不上，这一档的数字不能用来判断拐点
if drop_pct > 5:
    verdict = 'NO'
elif drop_pct > 1:
    verdict = '~'
else:
    verdict = 'YES'

row = (rate, round(qps), round(succ / dur), round(d.get('med', 0)), round(d.get('p(95)', 0)),
       round(d.get('p(99)', 0)), drop, busy, other, rl, round(drop_pct, 1), verdict)
print('%-7s %-7s %-8s %-7s %-7s %-7s %-6s %-6s %-5s %s' % (
    row[0], row[1], row[2], row[3], row[4], row[5], row[6], row[7], row[8],
    ('429=%d' % row[9]) if row[9] else ('丢弃%.0f%%' % row[10])))
with open(out, 'a') as f:
    f.write('\t'.join(map(str, row[:11])) + '\t' + row[11] + '\n')
PY
done

echo
echo "结果写入 ${OUT}（列：目标 实际 成功/s p50 p95 p99 丢弃 线程峰 5xx 429 丢弃% 可信）"

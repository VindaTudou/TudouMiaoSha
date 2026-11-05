#!/usr/bin/env bash
# M1 验收：证明 Prometheus 上的数字和 k6 报的数字对得上
#
# 为什么必须先做这一步：
#   监控装完就开始看它，是最典型的自我欺骗。
#   一个标签写错、一次抓取失败、一个计数器名字打错，
#   面板上照样有漂亮的曲线，只是那条线是错的。
#   所以先拿一个【已知答案】去对：k6 说发了多少个请求，Prometheus 就该数出多少个。
#
# 用法：ops/verify-metrics.sh [到达率] [时长]

set -u
cd "$(dirname "$0")/.."

RATE=${1:-3000}
DUR=${2:-20s}
K6=$(find tools -name k6 -type f -path '*/bin/*' | head -1)
M="docker exec -i -e MYSQL_PWD=root miaosha-mysql mysql -uroot --default-character-set=utf8mb4 miaosha"
R="docker exec miaosha-redis redis-cli"
PROM=http://127.0.0.1:9090
BIG_STOCK=10000000

q() {  # 查一个标量表达式，返回数字；失败返回空
  curl -s -G "$PROM/api/v1/query" --data-urlencode "query=$1" \
    | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)["data"]["result"]
    print(d[0]["value"][1] if d else "")
except Exception:
    print("")'
}

echo "=============================================="
echo " M1 验收：监控数字 vs k6 数字"
echo " 到达率 $RATE/s，时长 $DUR"
echo "=============================================="

# ---------- 0. 预检：Prometheus 和目标都活着 ----------
[ "$(curl -s -o /dev/null -w '%{http_code}' $PROM/-/ready)" = "200" ] || { echo "❌ Prometheus 没起来，先跑 ops/observability.sh up"; exit 1; }
up=$(curl -s $PROM/api/v1/targets | python3 -c 'import json,sys;print(sum(1 for t in json.load(sys.stdin)["data"]["activeTargets"] if t["labels"]["job"]=="miaosha" and t["health"]=="up"))')
[ "$up" = "1" ] || { echo "❌ 应用 target 不是 up，检查 8080 是否在跑"; exit 1; }
echo "✅ Prometheus 就绪，应用 target = up"

# ---------- 1. 重置数据 + 预热 ----------
$M -e "UPDATE product SET stock=$BIG_STOCK WHERE id=1; DELETE FROM orders;" >/dev/null 2>&1
curl -sS -m 5 -X POST http://127.0.0.1:8080/api/admin/preheat/1 >/dev/null
echo "✅ 库存已重置为 ${BIG_STOCK}，Redis 已预热"

# ---------- 1.5 等上一轮积压排空（不排空，延迟会被残留污染）----------
# 踩过的坑：两轮同样 3,000/s，一轮 P99 13ms、一轮 85ms，
# 差别就是上一轮的积压还没排完。积压高时 Kafka broker 忙，生产者 ack 变慢，
# 请求延迟跟着涨——看起来像"系统变慢了"，其实是自己上一轮留下的尾巴。
echo "等待上一轮积压排空 ..."
t0=$(date +%s)
while :; do
  lag=$(q 'sum(kafka_consumer_fetch_manager_records_lag)')
  case "$lag" in ''|*[!0-9.]*) lag=0 ;; esac
  [ "${lag%%.*}" -eq 0 ] && break
  [ $(( $(date +%s) - t0 )) -ge 300 ] && { echo "  ⚠️ 300 秒仍未排空（lag=$lag），本轮延迟数据不可信"; break; }
  sleep 3
done
echo "✅ 排空等待 $(( $(date +%s) - t0 ))s"

# ---------- 2. 预热 Kafka 生产者（否则第一批请求吃冷启动，P99 是假的）----------
curl -sS -m 5 -X POST http://127.0.0.1:8080/api/orders \
  -H 'Content-Type: application/json' -d '{"userId":1,"productId":1,"quantity":1}' >/dev/null
sleep 16   # 等一次抓取，让这单进到 before 里

before=$(q 'sum(miaosha_order_total)')
echo "✅ 预热完成，Prometheus 起点计数 = ${before:-读取失败}"
[ -n "$before" ] || { echo "❌ 读不到计数器"; exit 1; }

# ---------- 3. 压测 ----------
echo
echo "开始压测 ..."
"$K6" run --quiet --summary-export=/tmp/k6-m1.json \
  -e RATE="$RATE" -e SECKILL_DURATION="$DUR" -e MAX_VUS=2000 \
  loadtest/k6/v2.js > /tmp/k6-m1.log 2>&1
echo "压测结束"

# ---------- 4. 等最后一次抓取 ----------
sleep 20
after=$(q 'sum(miaosha_order_total)')

k6_reqs=$(python3 -c "import json;print(int(json.load(open('/tmp/k6-m1.json'))['metrics']['http_reqs']['count']))")
k6_rate=$(python3 -c "import json;print(round(json.load(open('/tmp/k6-m1.json'))['metrics']['http_reqs']['rate']))")

delta=$(python3 -c "print(int($after) - int($before))")
err=$(python3 -c "print(f'{abs($delta-$k6_reqs)*100/max(1,$k6_reqs):.2f}')")

echo
echo "---------- 对账 ----------"
printf '  k6 报的请求数          : %s\n' "$k6_reqs"
printf '  Prometheus 计数差值    : %s\n' "$delta"
printf '  误差                   : %s%%\n' "$err"
printf '  k6 报的速率            : %s /s\n' "$k6_rate"
printf '  Prometheus 平均速率    : %s /s\n' "$(q "sum(rate(miaosha_order_total[2m]))" | cut -c1-6)"
k6_p99=$(python3 -c "import json;print(round(json.load(open('/tmp/k6-m1.json'))['metrics']['http_req_duration{scenario:seckill}']['p(99)']))")
srv_p99=$(q 'histogram_quantile(0.99, sum by (le) (rate(http_server_requests_seconds_bucket{uri="/api/orders"}[2m])))')
srv_p99_ms=$(python3 -c "print(round(float('${srv_p99:-0}' or 0)*1000))")
printf '  k6 客户端 P99          : %s ms   ← 延迟以客户端为准\n' "$k6_p99"
printf '  服务端 P99（直方图）   : %s ms   ← 只统计服务端处理时间，不含网络\n' "$srv_p99_ms"

if python3 -c "exit(0 if $err < 2 else 1)"; then
  echo "  判定                   : ✅ 监控数字可信（误差 < 2%）"
else
  echo "  判定                   : ❌ 对不上，先别信任何面板"
fi

# ---------- 5. 面板查询体检：每条 PromQL 都要有数据 ----------
echo
echo "---------- 面板查询体检 ----------"
check() {
  local name=$1 expr=$2
  local out=$(q "$expr")
  if [ -z "$out" ]; then echo "  ⚠️  $name → 无数据"; else printf '  ✅ %-22s → %s\n' "$name" "$out"; fi
}
check "下单结果QPS"   'sum(rate(miaosha_order_total[1m]))'
check "下单P99(s)"    'histogram_quantile(0.99, sum by (le) (rate(http_server_requests_seconds_bucket{uri="/api/orders"}[1m])))'
check "Kafka积压"     'sum(kafka_consumer_fetch_manager_records_lag)'
check "Redis扣减P99"  'max(miaosha_redis_deduct_seconds{quantile="0.99"})'
check "Kafka发送P99"  'max(miaosha_kafka_send_seconds{quantile="0.99"})'
check "Tomcat忙碌线程" 'max(tomcat_threads_busy_threads)'
check "消费速率"      'sum(rate(miaosha_consumer_persist_total{result="ok"}[1m]))'

# ---------- 6. 排空 + 对账 ----------
echo
echo "---------- 等 Kafka 排空 ----------"
t0=$(date +%s)
while :; do
  lag=$(q 'sum(kafka_consumer_fetch_manager_records_lag)')
  # 空的或 NaN（Kafka 还没测出积压时会报 NaN）一律当 0
  case "$lag" in ''|*[!0-9.]*) lag=0 ;; esac
  [ "${lag%%.*}" -eq 0 ] && break
  [ $(( $(date +%s) - t0 )) -ge 180 ] && { echo "  超时，lag 仍为 $lag"; break; }
  sleep 3
done
drain=$(( $(date +%s) - t0 ))

orders=$($M -N -B -e 'SELECT COUNT(*) FROM orders;' | tr -d '\r\n')
final=$($R get seckill:stock:1 | tr -d '\r\n')
echo "  排空耗时: ${drain}s"
echo "  Redis 剩余库存: $final"
echo "  MySQL 订单数: $orders"
echo "  (Redis 扣减 = $BIG_STOCK - $final = $(( BIG_STOCK - final )) )"

#!/usr/bin/env bash
# V2 容量扫描：请求侧吞吐 + 消费侧积压
#
# 和 V1 的区别：
#   - 每轮 preheat（MySQL 库存刷进 Redis），不是直接改 MySQL
#   - 200 只代表"抢到名额"，还要等消费者落库才算完
#   - 必须采 Kafka lag，否则会被漂亮的 QPS 骗过去
#
# 用法：RATES="1000 3000" DURATION=10s bash loadtest/run-capacity-v2.sh

set -u
cd "$(dirname "$0")/.."

K6=$(find tools -name k6 -type f -path '*/bin/*' | head -1)
M="docker exec -i -e MYSQL_PWD=root miaosha-mysql mysql -uroot --default-character-set=utf8mb4 miaosha"
R="docker exec miaosha-redis redis-cli"
KG="docker exec miaosha-kafka /opt/kafka/bin/kafka-consumer-groups.sh"
DURATION=${DURATION:-15s}
RATES=${RATES:-"1000 3000 8000"}
BIG_STOCK=10000000
ROWS=/tmp/v2rows.tsv
: > "$ROWS"

lag() {
  $KG --bootstrap-server 127.0.0.1:29092 --describe --group miaosha-order-consumer 2>/dev/null \
    | awk 'NR>1 && $6 ~ /^[0-9]+$/ {s+=$6} END{printf "%d", s+0}'
}

echo "=============================================="
echo " V2 容量扫描   到达率: $RATES   每轮: $DURATION"
echo "=============================================="
printf '%-8s %-9s %-8s %-8s %-7s %-8s\n' 到达率 实际QPS p50 p99 5xx% k6丢弃
printf '%-8s %-9s %-8s %-8s %-7s %-8s\n' ------ ------- --- --- ---- ------

for rate in $RATES; do
  $M -e "UPDATE product SET stock=$BIG_STOCK WHERE id=1; DELETE FROM orders;" >/dev/null 2>&1
  curl -sS -m 5 -X POST http://127.0.0.1:8080/api/admin/preheat/1 >/dev/null

  # 起点必须干净：上一轮的 lag 排空
  for i in $(seq 1 180); do [ "$(lag)" -eq 0 ] && break; sleep 1; done

  ( for i in $(seq 1 300); do lag; sleep 1; done ) > "/tmp/lag-$rate.txt" 2>/dev/null &
  sampler=$!

  "$K6" run --quiet --summary-export="/tmp/k6-v2-$rate.json" \
    -e RATE="$rate" -e SECKILL_DURATION="$DURATION" \
    loadtest/k6/v2.js > "/tmp/k6-v2-$rate.log" 2>&1

  kill "$sampler" 2>/dev/null
  wait "$sampler" 2>/dev/null

  lag_end=$(lag)

  t0=$(date +%s)
  while :; do
    [ "$(lag)" -eq 0 ] && break
    [ $(( $(date +%s) - t0 )) -ge 180 ] && break
    sleep 1
  done
  drain=$(( $(date +%s) - t0 ))

  final=$($R get seckill:stock:1 2>/dev/null | tr -d '\r\n')
  orders=$($M -N -B -e 'SELECT COUNT(*) FROM orders;' 2>/dev/null | tr -d '\r\n')
  deducted=$(( BIG_STOCK - final ))

  read -r qps med p99 errpct drop ok < <(python3 loadtest/parse_k6.py "/tmp/k6-v2-$rate.json")

  printf '%-8s %-9s %-8s %-8s %-7s %-8s\n' "$rate" "$qps" "$med" "$p99" "$errpct" "$drop"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$rate" "$deducted" "$ok" "$lag_end" "$drain" "$orders" >> "$ROWS"
done

echo
printf '%-8s %-11s %-11s %-10s %-9s %-10s %-9s\n' 到达率 Redis扣减 Kafka消息 结束时lag 排空s 消费速率 MySQL订单
printf '%-8s %-11s %-11s %-10s %-9s %-10s %-9s\n' ------ --------- --------- -------- ----- ------- ---------
while IFS=$'\t' read -r rate deducted produced lag_end drain orders; do
  rate_out=$(( lag_end == 0 && drain == 0 ? 0 : (drain > 0 ? lag_end / drain : lag_end) ))
  printf '%-8s %-11s %-11s %-10s %-9s %-10s %-9s\n' \
    "$rate" "$deducted" "$produced" "$lag_end" "$drain" "$rate_out" "$orders"
done < "$ROWS"

echo
echo "对账：Redis扣减 应 ≈ Kafka消息数 ≈ MySQL订单 + 结束时lag"
echo "（排空后 lag=0，三者应当相等）"

#!/usr/bin/env bash
# 实验 B：过载病历
#
# 目的不是"测出多少 QPS"，而是记录【超出容量后系统怎么烂掉】：
#   是全员变慢？部分失败？还是雪崩？
#
# 与实验 A 的区别：
#   - 到达率明显超过拐点（默认 6,000/s，A 的拐点是 4,500~5,000）
#   - 跑 60 秒而不是 20 秒，看"越久越糟"的累积效应
#   - 全程每秒采样，画成时间曲线
#   - 压测结束后继续采 60 秒，量【恢复时间】
#
# 用法：loadtest/overload.sh [到达率] [时长] [BASE] [标签]
#   loadtest/overload.sh 6000 60s http://127.0.0.1:8080 direct
#   loadtest/overload.sh 6000 60s http://127.0.0.1:8000 gateway

set -u
cd "$(dirname "$0")/.."

RATE=${1:-6000}
DUR=${2:-60s}
BASE=${3:-http://127.0.0.1:8080}
TAG=${4:-run}
DUR_SEC=${DUR%s}
RECOVER=60                       # 压测后再采 60 秒，看恢复
K6=$(find tools -name k6 -type f -path '*/bin/*' | head -1)
M="docker exec -i -e MYSQL_PWD=root miaosha-mysql mysql -uroot --default-character-set=utf8mb4 miaosha"
CSV=/tmp/overload-$TAG.csv

echo "=============================================================="
echo " 实验 B：过载病历   ${RATE}/s × ${DUR_SEC}s   → ${BASE}"
echo "=============================================================="

# ---------- 前置 ----------
$M -e "UPDATE product SET stock=10000000 WHERE id=1; DELETE FROM orders;" >/dev/null 2>&1
curl -sS -m 5 -X POST ${BASE}/api/admin/preheat/1 >/dev/null
curl -sS -m 5 -X POST ${BASE}/api/orders -H 'Content-Type: application/json' \
  -d '{"userId":1,"productId":1,"quantity":1}' >/dev/null
echo "✅ 库存重置 + 预热 + Kafka 生产者热身"

# ---------- 采样器先跑起来（比压测早 3 秒，拿到基线）----------
python3 ops/sampler.py "$CSV" $(( DUR_SEC + RECOVER + 6 )) > /tmp/sampler-$TAG.log 2>&1 &
sampler=$!
sleep 3
echo "✅ 每秒采样已启动 → $CSV"
echo

# ---------- 压测 ----------
start=$(date +%s)
"$K6" run --quiet --summary-export="/tmp/k6-overload-$TAG.json" \
  -e RATE="$RATE" -e SECKILL_DURATION="$DUR" -e BASE="$BASE" -e MAX_VUS=$(( RATE * 2 )) \
  loadtest/k6/v3.js > "/tmp/k6-overload-$TAG.log" 2>&1
stop=$(date +%s)
echo "压测结束，用时 $(( stop - start ))s；继续采样 ${RECOVER}s 观察恢复 ..."

wait $sampler 2>/dev/null
echo "✅ 采样结束"

# ---------- 汇总 ----------
echo
echo "---------- k6 汇总 ----------"
python3 - "$TAG" <<'PY'
import json, sys
tag = sys.argv[1]
m = json.load(open(f'/tmp/k6-overload-{tag}.json'))['metrics']
d = m.get('http_req_duration{scenario:seckill}') or m.get('http_req_duration', {})
def g(k, f='count'):
    return m.get(k, {}).get(f, 0)
reqs = g('http_reqs')
succ = g('order_success')
so = g('order_soldout')
dup = g('order_duplicate')
rl = g('order_ratelimited')
other = g('order_other')
drop = g('dropped_iterations')
print(f"  请求总数        : {reqs:,.0f}")
print(f"  成功 200        : {succ:,.0f}  ({succ*100/max(1,reqs):.2f}%)")
print(f"  售罄 409        : {so:,.0f}")
print(f"  重复 409        : {dup:,.0f}")
print(f"  限流 429        : {rl:,.0f}")
print(f"  其他（5xx/超时）: {other:,.0f}  ({other*100/max(1,reqs):.2f}%)")
print(f"  k6 丢弃         : {drop:,.0f}")
print(f"  P50 / P95 / P99 : {d.get('med',0):.0f} / {d.get('p(95)',0):.0f} / {d.get('p(99)',0):.0f} ms")
print(f"  最长单请求      : {d.get('max',0):.0f} ms")
PY

echo
echo "---------- 恢复情况（从 CSV 读）----------"
python3 - "$TAG" "$DUR_SEC" <<'PY'
import csv, sys
tag, dur = sys.argv[1], float(sys.argv[2])
rows = list(csv.DictReader(open(f'/tmp/overload-{tag}.csv')))
if not rows:
    print("  没有采样数据"); sys.exit()
def at(t):
    return min(rows, key=lambda r: abs(float(r['t']) - t))
peak = max(rows, key=lambda r: int(r['busy']))
print(f"  峰值忙碌线程    : {peak['busy']} （第 {peak['t']} 秒）")
print(f"  峰值堆使用      : {max(float(r['heap_mb']) for r in rows):.0f} MB")
print(f"  峰值 Kafka P99  : {max(float(r['kafka_p99']) for r in rows)*1000:.0f} ms")
print(f"  结束时积压      : {rows[-1]['lag']}")
# 恢复：停压后线程首次回到 30 以下的时间
t_stop = dur
rec = None
for r in rows:
    if float(r['t']) >= t_stop and int(r['busy']) <= 30 and int(r['hikari_pending']) == 0:
        rec = float(r['t']) - t_stop
        break
print(f"  线程恢复(<30)   : {rec:.0f} 秒" if rec is not None else "  线程恢复(<30)   : 60 秒内没恢复")
PY

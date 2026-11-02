#!/usr/bin/env bash
# V0.1 丢失更新扫描
#
# 控制变量：每线程自增次数固定，只改线程数。
# 每个配置跑 ROUNDS 轮，取中位数（不是平均值——平均值会被一次抖动带偏）。
#
# 用法:
#   bash run-sweep.sh
#   ITERS=50000 ROUNDS=7 bash run-sweep.sh
#   THREADS_LIST="1 2 4 8" bash run-sweep.sh

ITERS=${ITERS:-20000}
ROUNDS=${ROUNDS:-5}
THREADS_LIST=${THREADS_LIST:-"4 10 25 50 100 200"}

median() { sort -n | awk '{a[NR]=$1} END{ if(NR==0) print 0; else print a[int((NR+1)/2)] }'; }

printf '%-8s %-14s %-10s %-14s\n' "线程数" "中位丢失次数" "丢失率" "中位耗时(ms)"
printf '%-8s %-14s %-10s %-14s\n' "------" "------------" "------" "------------"

for t in $THREADS_LIST; do
  losses=""
  times=""
  for r in $(seq "$ROUNDS"); do
    out=$(java NaiveCounter.java "$t" "$ITERS")
    losses="$losses$(printf '%s\n' "$out" | awk '/丢失更新/{print $3}')
"
    times="$times$(printf '%s\n' "$out" | awk '/耗时/{print $3}')
"
  done

  med_loss=$(printf '%s' "$losses" | median)
  med_time=$(printf '%s' "$times" | median)
  total=$(( t * ITERS ))

  awk -v t="$t" -v l="$med_loss" -v tm="$med_time" -v tot="$total" \
    'BEGIN{ printf "%-8s %-14s %-10s %-14s\n", t, l, sprintf("%.2f%%", l*100/tot), tm }'
done

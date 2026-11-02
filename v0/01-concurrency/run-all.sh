#!/usr/bin/env bash
# V0.1 标准入口 —— 所有对外引用的数字都必须从这个脚本产生。
#
# 为什么要有这个脚本：
#   同一个 .java 文件，参数不同就是不同实验。
#   2026-11-02 发生过一次事故：100x1000 和 100x20000 被当成同一个实验对比，
#   丢失率差了 25 倍。根因是程序没把参数打全、没有统一入口。
#
# 用法:
#   bash run-all.sh                       # 默认 100 线程 x 20000 次，5 轮，JIT 开启
#   JAVA_OPTS=-Xint bash run-all.sh       # 纯解释执行（结果稳，但代表不了真实性能）
#   THREADS=10 ITERS=1000 bash run-all.sh # 自定义

THREADS=${THREADS:-100}
ITERS=${ITERS:-20000}
ROUNDS=${ROUNDS:-5}
JAVA_OPTS=${JAVA_OPTS:-}

median() { sort -n | awk '{a[NR]=$1} END{ if(NR==0) print 0; else print a[int((NR+1)/2)] }'; }

TOTAL=$(( THREADS * ITERS ))
MODE=${JAVA_OPTS:-"默认(JIT)"}

echo "=============================================="
echo " 配置   线程=$THREADS  每线程=$ITERS  期望=$TOTAL  轮数=$ROUNDS"
echo " JVM    $MODE"
echo " 命令   $(basename "$0")"
echo "=============================================="
printf '%-18s %-14s %-10s %-12s %-8s\n' "实现" "中位丢失" "丢失率" "中位耗时(ms)" "正确?"
printf '%-18s %-14s %-10s %-12s %-8s\n' "----" "--------" "------" "------------" "-----"

for f in NaiveCounter VolatileCounter AtomicCounter SyncCounter; do
  losses=""
  times=""
  for r in $(seq "$ROUNDS"); do
    out=$(java $JAVA_OPTS "$f.java" "$THREADS" "$ITERS")
    losses="$losses$(printf '%s\n' "$out" | awk '/丢失更新/{print $3}')
"
    times="$times$(printf '%s\n' "$out" | awk '/耗时/{print $3}')
"
  done
  med_loss=$(printf '%s' "$losses" | median)
  med_time=$(printf '%s' "$times" | median)
  awk -v f="$f" -v l="$med_loss" -v tm="$med_time" -v tot="$TOTAL" 'BEGIN{
    ok = (l == 0) ? "是" : "否"
    printf "%-18s %-14s %-10s %-12s %-8s\n", f, l, sprintf("%.2f%%", l*100/tot), tm, ok
  }'
done

echo "----------------------------------------------"
echo " 注：丢失率随参数剧烈变化（实测 13%~91%），但「是否为 0」从不变化。"
echo "     并发正确性没有中间态，只有对和错。"

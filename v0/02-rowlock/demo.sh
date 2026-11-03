#!/usr/bin/env bash
# V0.2 行锁实验：全自动复现，输出带耗时
#
# 为什么用脚本而不是手敲三个终端：
#   并发实验要求"时序精确"（A 必须还在持锁时 B 才发起），手敲做不到可复现。
#   脚本化之后，任何人任何时间跑，看到的都是同一组现象。
#
# 用法：bash demo.sh

set -u
DB=miaosha
RESET="UPDATE product SET stock = 1000 WHERE id = 1;"

q() { docker exec -i -e MYSQL_PWD=root miaosha-mysql mysql -uroot --default-character-set=utf8mb4 "$DB" -N -B -e "$1" 2>&1; }

# 后台跑一条会持锁的 SQL：BEGIN → 加锁 → 睡 N 秒 → COMMIT
hold() {
  docker exec -i -e MYSQL_PWD=root miaosha-mysql mysql -uroot --default-character-set=utf8mb4 "$DB" -N -B \
    -e "BEGIN; $1; SELECT SLEEP($2); COMMIT;" >/dev/null 2>&1 &
}

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

hr() { printf '\n%s\n' "────────────────────────────────────────────────────────────"; }

q "$RESET"

hr; echo "场景 1：X 锁 —— 两个会话抢同一行"; hr
echo "A: BEGIN → UPDATE → 持锁 6 秒 → COMMIT"
hold "UPDATE product SET stock = stock - 1 WHERE id = 1;" 6
sleep 1
t0=$(now_ms)
out=$(q "SET SESSION innodb_lock_wait_timeout = 3; UPDATE product SET stock = stock - 1 WHERE id = 1;")
t1=$(now_ms)
echo "B: 同一条 UPDATE，等待 $((t1 - t0)) ms 后返回："
echo "$out"
sleep 4
echo "最终库存：$(q 'SELECT stock FROM product WHERE id = 1;')  期望 1000（B 失败，只有 A 扣成功）"

hr; echo "场景 2：锁的明细 —— 谁在等谁"; hr
q "$RESET" >/dev/null
hold "UPDATE product SET stock = stock - 1 WHERE id = 1;" 8
sleep 1
( docker exec -i -e MYSQL_PWD=root miaosha-mysql mysql -uroot --default-character-set=utf8mb4 "$DB" -N -B \
    -e "SET SESSION innodb_lock_wait_timeout = 6; UPDATE product SET stock = stock - 1 WHERE id = 1;" \
    >/dev/null 2>&1 ) &
sleep 2
echo "--- performance_schema.data_locks（锁加在哪）---"
q "SELECT ENGINE_TRANSACTION_ID AS trx, OBJECT_NAME AS tbl, INDEX_NAME AS idx,
          LOCK_TYPE, LOCK_MODE, LOCK_STATUS, LOCK_DATA
   FROM performance_schema.data_locks;"
echo
echo "--- performance_schema.data_lock_waits（等待关系）---"
q "SELECT REQUESTING_ENGINE_TRANSACTION_ID AS waiting_trx,
          BLOCKING_ENGINE_TRANSACTION_ID  AS blocking_trx
   FROM performance_schema.data_lock_waits;"
sleep 6

hr; echo "场景 3：普通 SELECT 不被锁阻塞（快照读）"; hr
q "$RESET" >/dev/null
( docker exec -i -e MYSQL_PWD=root miaosha-mysql mysql -uroot --default-character-set=utf8mb4 "$DB" -N -B \
    -e "BEGIN; SELECT stock FROM product WHERE id = 1; DO SLEEP(4); SELECT stock FROM product WHERE id = 1; COMMIT;" \
    2>&1 | sed 's/^/    A 读到: /' ) &
sleep 1
q "UPDATE product SET stock = 500 WHERE id = 1;" >/dev/null
echo "    某个时刻 B 把 stock 改成 500 并提交"
wait
echo "    A 提交后再查：$(q 'SELECT stock FROM product WHERE id = 1;')"

hr; echo "场景 4：库存为 0 时，条件更新还加锁吗"; hr
q "UPDATE product SET stock = 0 WHERE id = 1;" >/dev/null
echo "先把库存改成 0"
hold "UPDATE product SET stock = stock - 1 WHERE id = 1 AND stock >= 1;" 6
sleep 1
t0=$(now_ms)
out=$(q "SET SESSION innodb_lock_wait_timeout = 3; UPDATE product SET stock = stock - 1 WHERE id = 1 AND stock >= 1;")
t1=$(now_ms)
echo "B: 条件更新（库存已是 0），等待 $((t1 - t0)) ms："
echo "$out"
sleep 4

hr; echo "场景 5：S 锁（FOR SHARE）—— 别人能读、不能写"; hr
q "$RESET" >/dev/null
hold "SELECT stock FROM product WHERE id = 1 FOR SHARE;" 6
sleep 1
echo -n "普通 SELECT 耗时："
t0=$(now_ms); q "SELECT stock FROM product WHERE id = 1;" >/dev/null; t1=$(now_ms)
echo "$((t1 - t0)) ms（不阻塞）"
echo -n "UPDATE   耗时："
t0=$(now_ms); out=$(q "SET SESSION innodb_lock_wait_timeout = 2; UPDATE product SET stock = 999 WHERE id = 1;"); t1=$(now_ms)
echo "$((t1 - t0)) ms"
echo "$out"
sleep 4

q "$RESET" >/dev/null
hr; echo "清理完成，库存已恢复 1000"; hr

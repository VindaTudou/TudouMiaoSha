#!/usr/bin/env bash
# V0.2 补充实验：锁的范围由索引决定
#
# 同一个 UPDATE，只差一个索引，锁住的行数完全不同。
# 这是"建索引不只为了快，更是为了锁的范围小"的直接证据。

set -u
DB=miaosha
M="docker exec -i -e MYSQL_PWD=root miaosha-mysql mysql -uroot"

q() { $M "$DB" -N -B -e "$1" 2>&1; }
hr() { printf '\n%s\n' "────────────────────────────────────────────────────────────"; }

# 造 5 行数据，name 上【故意不建索引】
q "DELETE FROM product;" >/dev/null
q "INSERT INTO product (id, name, price, stock) VALUES
     (1,'A',1.00,10),(2,'B',1.00,10),(3,'C',1.00,10),(4,'D',1.00,10),(5,'E',1.00,10);" >/dev/null
q "ALTER TABLE product DROP INDEX idx_name;" >/dev/null 2>&1

hr; echo "条件：name 上没有索引"; hr
echo "A: BEGIN → UPDATE ... WHERE name='B' → 持锁 5 秒"
docker exec -i -e MYSQL_PWD=root miaosha-mysql mysql -uroot --default-character-set=utf8mb4 "$DB" -N -B \
  -e "BEGIN; UPDATE product SET stock = stock - 1 WHERE name = 'B'; DO SLEEP(5); COMMIT;" >/dev/null 2>&1 &
sleep 1
echo
echo "锁住了几行？"
q "SELECT LOCK_MODE, LOCK_DATA FROM performance_schema.data_locks
   WHERE OBJECT_NAME='product' AND LOCK_TYPE='RECORD' ORDER BY LOCK_DATA;"
echo
echo "锁数量：$(q "SELECT COUNT(*) FROM performance_schema.data_locks WHERE OBJECT_NAME='product' AND LOCK_TYPE='RECORD';")"
sleep 5

hr; echo "条件：给 name 建上索引"; hr
q "ALTER TABLE product ADD INDEX idx_name (name);" >/dev/null
echo "A: 同一条 UPDATE，再跑一次"
docker exec -i -e MYSQL_PWD=root miaosha-mysql mysql -uroot --default-character-set=utf8mb4 "$DB" -N -B \
  -e "BEGIN; UPDATE product SET stock = stock - 1 WHERE name = 'B'; DO SLEEP(5); COMMIT;" >/dev/null 2>&1 &
sleep 1
echo
echo "锁住了几行？"
q "SELECT LOCK_MODE, LOCK_DATA FROM performance_schema.data_locks
   WHERE OBJECT_NAME='product' AND LOCK_TYPE='RECORD' ORDER BY LOCK_DATA;"
echo
echo "锁数量：$(q "SELECT COUNT(*) FROM performance_schema.data_locks WHERE OBJECT_NAME='product' AND LOCK_TYPE='RECORD';")"
sleep 5

hr; echo "收尾：恢复成 V0.2 的初始状态"; hr
q "DELETE FROM product;" >/dev/null
q "INSERT INTO product (id, name, price, stock) VALUES (1,'测试商品-库存1000',99.00,1000);" >/dev/null
q "SHOW INDEX FROM product;" | awk '{print "  索引: "$3"  列: "$5}'

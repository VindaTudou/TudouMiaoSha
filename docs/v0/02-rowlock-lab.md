# V0.2 行锁：亲眼看见 `UPDATE` 卡住

> 目标：不靠背概念，亲眼看见"两个会话抢同一行"时，第二个会卡住。
> 这一步之后，V1 的"连接池耗尽"就不再是抽象名词。

## 前置

```bash
cd ~/ComputerScience/Projects/TudouMiaoSha
make up          # 起 MySQL，等到健康
make status      # 应该看到 miaosha-mysql 是 Up (healthy)
```

表已经由 `db/init/01-schema.sql` 建好了：`product` 只有一行，`id=1, stock=1000`。

## 第一步：开两个会话

**终端 A**

```bash
docker exec -it miaosha-mysql mysql -uroot -proot miaosha
```

```sql
SET SESSION innodb_lock_wait_timeout = 5;   -- 把等待超时从 50 秒改成 5 秒，省时间
BEGIN;
UPDATE product SET stock = stock - 1 WHERE id = 1;
-- 看到 "Query OK, 1 row affected" 之后，什么都不要做，不要 COMMIT
```

**终端 B**（新开一个）

```bash
docker exec -it miaosha-mysql mysql -uroot -proot miaosha
```

```sql
SET SESSION innodb_lock_wait_timeout = 5;
UPDATE product SET stock = stock - 1 WHERE id = 1;
```

### 你会看到什么

终端 B 会**停在那里，光标不动，5 秒后**：

```
ERROR 1205 (HY000): Lock wait timeout exceeded; try restarting transaction
```

这 5 秒里 B 什么都没干，就是在等 A 释放锁。**这就是行锁。**

> 注意：这里用的是同一个数据卷、同一个库，A 和 B 是两个独立连接，
> 模拟的就是 V1 里两个 HTTP 请求对应的两个数据库连接。

## 第二步：看清"谁在等谁"

**终端 C**（第三个会话，A 还挂着别提交）

```sql
-- 当前有哪些事务，各自在等什么
SELECT trx_id, trx_state, trx_started,
       trx_rows_locked, trx_rows_modified,
       LEFT(trx_query, 60) AS query
FROM information_schema.innodb_trx\G

-- 锁的明细：哪一行、什么类型的锁
SELECT ENGINE_TRANSACTION_ID, OBJECT_NAME, INDEX_NAME,
       LOCK_TYPE, LOCK_MODE, LOCK_STATUS, LOCK_DATA
FROM performance_schema.data_locks\G

-- 等待关系：谁阻塞了谁
SELECT * FROM performance_schema.data_lock_waits\G
```

重点看 `data_locks` 里的 `LOCK_MODE`：应该是 `X`（排他锁）。
`LOCK_STATUS` 在 A 的事务上会是 `GRANTED`，B 的那条是 `WAITING`。

## 第三步：对照实验

把上面重做一遍，但 A 换成**先查再改**的写法：

```sql
-- 终端 A
BEGIN;
SELECT stock FROM product WHERE id = 1 FOR UPDATE;   -- 显式加排他锁
-- 然后终端 B 执行 UPDATE，同样会卡住
```

再试第三种：**条件不满足时**

```sql
-- 先把库存改成 0
UPDATE product SET stock = 0 WHERE id = 1;

-- 终端 A
BEGIN;
UPDATE product SET stock = stock - 1 WHERE id = 1 AND stock >= 1;
-- 影响行数 0，没有扣成功

-- 终端 B 同时执行同一条，观察是否还会卡住、卡多久
```

**这是 V1-b 的核心写法。** 它不会超卖，但你要观察的是：在库存充足（热点争抢）时，
它和 `FOR UPDATE` 的等待行为有区别吗？

> 提示：有区别，但区别可能比你预期的小。想清楚"为什么"再下结论——
> 这是 V1-b 压测时会重新遇到的问题。

## 第四步：记录

新建 `v0/02-rowlock/RESULTS.md`，至少记下：

| 观察项 | 值 |
|---|---|
| B 卡住了多久 | |
| 报的错 | |
| `data_locks` 里 B 的 `LOCK_MODE` / `LOCK_STATUS` | |
| `innodb_lock_wait_timeout` 默认值 | |
| 条件更新（`stock >= 1`）在库存充足时是否也阻塞 | |
| 条件更新在库存为 0 时是否还阻塞 | |

## 自问（做完回答，答不上来就回来问）

1. 这 5 秒里，终端 B 的那个**数据库连接**在干什么？还能处理别的请求吗？
2. 如果 V1 的连接池只有 10 个连接，同时有 10 个请求在等同一行的锁，第 11 个请求会怎样？
3. `BEGIN` 之后忘了 `COMMIT`，会发生什么？为什么说"事务要短"？

## 清理

```bash
# 终端 A 里
COMMIT;
# 或者
ROLLBACK;

# 收工
make down       # 停容器，保留数据
make reset      # 清空重建（下次 up 会重新执行建表脚本）
```

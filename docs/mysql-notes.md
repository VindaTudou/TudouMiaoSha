# MySQL 速成：跑 V0.2 之前必须有的 6 个模型

> 你已经会增删改查。这份笔记只补**秒杀项目会用到的底层模型**，
> 每个模型都配一条可验证的 SQL，跑 V0.2 时一起验证。
>
> 不会讲：安装、建库建表、语法大全、备份恢复、主从搭建。

---

## 一、数据是怎么存的：页 与 B+ 树

**三句话**

1. InnoDB 把数据存在固定大小的**页**里（默认 16 KB），一页装若干行。
2. 表本身是一棵 **B+ 树**，按**主键**排序。叶子节点就是数据行 —— 这叫**聚簇索引**。
3. 所以：**一张 InnoDB 表只能有一个聚簇索引，就是主键。**

**为什么重要**

- 主键不是"随便加的一个 id"，它是**数据的物理组织方式**。
- 主键短 → 一页能装更多行 → 树更矮 → 查得更快。
- 用 UUID 当主键 → 随机插入 → 页分裂 → 写放大。这是"为什么用自增 ID"的真正原因，不是习惯。

**验证**

```sql
-- 一页多大、表有多少页
SELECT TABLE_NAME, AVG_ROW_LENGTH, DATA_LENGTH, INDEX_LENGTH
FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'miaosha';
```

---

## 二、索引：一个排好序的目录，但它有前提

**三种索引的区别**

| 类型 | 叶子节点存什么 | 查一次要几次树查找 |
|---|---|---|
| 聚簇索引（主键） | 整行数据 | 1 次 |
| 二级索引（普通索引） | **主键值** | 2 次（查到主键后再回聚簇索引取整行） |
| 覆盖索引 | 查询要的列 | 1 次（不用回表） |

**回表**：二级索引找到主键 → 再去主键树里取整行。这就是"`SELECT *` 比 `SELECT id` 慢"的原因。

**最左前缀**

联合索引 `(user_id, product_id, created_at)`：

| 查询条件 | 能用索引吗 |
|---|---|
| `WHERE user_id = ?` | ✅ |
| `WHERE user_id = ? AND product_id = ?` | ✅ |
| `WHERE product_id = ?` | ❌ 跳过最左列 |
| `WHERE user_id = ? AND created_at > ?` | ⚠️ 只能用到 user_id |

**索引失效的四个常见原因**

1. 列上套函数：`WHERE DATE(created_at) = '2026-11-02'`
2. 隐式类型转换：`WHERE user_id = '123'`（列是 BIGINT）
3. 前缀通配：`LIKE '%abc'`
4. `OR` 连接的两列有一边没索引

**验证**

```sql
EXPLAIN SELECT * FROM product WHERE id = 1;
-- 看 key（用了哪个索引）、rows（扫多少行）、Extra（是否 Using index）
```

`Extra` 的关键值：

- `Using index`：覆盖索引，不回表 ✅
- `Using where`：server 层还要过滤
- `Using filesort`：排序没走索引，数据量大就完蛋
- `Using temporary`：用了临时表，通常意味着 GROUP BY / DISTINCT 没走索引

---

## 三、事务：两种读，一种加锁一种不加 ★

这是**最容易被忽略、又直接导致超卖**的一节。

### 快照读 vs 当前读

| | 谁 | 加锁吗 | 读到什么 |
|---|---|---|---|
| **快照读** | 普通 `SELECT` | ❌ 不加锁 | 事务开始那一刻的**历史版本**（靠 undo log + MVCC） |
| **当前读** | `UPDATE` / `DELETE` / `INSERT` / `SELECT ... FOR UPDATE` / `SELECT ... LOCK IN SHARE MODE` | ✅ 加锁 | **最新**已提交的数据 |

**核心结论：`SELECT` 不加锁，你看到的库存只是一个快照。**

### 超卖是怎么发生的

```
时刻   事务 A（用户 1 下单）              事务 B（用户 2 下单）
 t1    BEGIN
 t2    SELECT stock -> 1000   ← 快照读，不加锁
 t3                                       BEGIN
 t4                                       SELECT stock -> 1000  ← 也是 1000
 t5    UPDATE stock = 999     ← 当前读，加 X 锁
 t6    COMMIT
 t7                                       UPDATE stock = 999  ← 覆盖 A 的结果
 t8                                       COMMIT
```

两单都成功，库存只减了 1。**问题不在 UPDATE，在"读的时候没锁"。**

### 隔离级别

| 级别 | 脏读 | 不可重复读 | 幻读 | 秒杀里够用吗 |
|---|---|---|---|---|
| READ UNCOMMITTED | ✅ 会 | ✅ 会 | ✅ 会 | 不用 |
| READ COMMITTED | ❌ | ✅ 会 | ✅ 会 | 不够 |
| **REPEATABLE READ（默认）** | ❌ | ❌ | ❌（InnoDB 用间隙锁兜住） | 够 |
| SERIALIZABLE | ❌ | ❌ | ❌ | 太重 |

**RC 和 RR 的真实差别**：

- RR：ReadView 在**事务第一次快照读时**创建，整个事务期间都用它 → 同一事务里读多少次都一样
- RC：**每次**快照读都新建 ReadView → 能读到别人刚提交的

**验证**

```sql
SELECT @@transaction_isolation;   -- 默认 REPEATABLE-READ
```

---

## 四、锁：加在索引上，不是加在表上 ★

**三句话**

1. `UPDATE` 加的 X 锁是加在**索引记录**上的，不是加在"表"或"行号"上的。
2. `WHERE` 的列**没有索引** → 全表扫描 → 扫描过的每一行都被锁 → **实际接近锁表**。
3. 所以"给 WHERE 列建索引"不只是为了查得快，更是为了**锁的范围小**。

**锁的种类**

| 锁 | 锁什么 | 出现场景 |
|---|---|---|
| Record Lock | 索引上的一条记录 | `WHERE id = 1` |
| Gap Lock | 两条记录之间的**空隙** | RR 下范围查询，防止幻读 |
| Next-Key Lock | 记录 + 前面的间隙 | RR 默认，Record 和 Gap 的组合 |
| 意向锁（IS/IX） | 表级，表示"我下面有行锁" | 加行锁时自动加，用来快速判断表锁能不能加 |

**死锁**：两个事务交叉持锁、互相等待。InnoDB 会自动检测，回滚"代价小"的那个：

```
ERROR 1213 (40001): Deadlock found when trying to get lock
```

**验证**（V0.2 会用到）

```sql
SELECT * FROM performance_schema.data_locks\G
SELECT * FROM performance_schema.data_lock_waits\G
SHOW ENGINE INNODB STATUS\G     -- 看 TRANSACTIONS 段
```

---

## 五、日志：为什么 UPDATE 很快，以及为什么事务要短

| 日志 | 是什么 | 作用 |
|---|---|---|
| **redo log** | 物理日志，"某页某偏移改成了什么" | 崩溃恢复。**先写日志再改页**（WAL） |
| **undo log** | 逻辑日志，"怎么改回去" | 回滚 + MVCC 的历史版本 |
| **binlog** | 逻辑日志，"执行了什么 SQL" | 主从复制、数据归档 |

**为什么单行 UPDATE 很快**：改的是内存里的页，只顺序写一小段 redo log 就返回，脏页由后台异步刷盘。所以瓶颈往往不在"写"，而在**锁等待**。

**为什么事务要短**：

1. 锁持有的时间 = 事务长度 → 别人等得久
2. undo log 不能回收 → 版本链变长 → 快照读越来越慢
3. 长事务会拖住 purge 线程 → 磁盘空间涨

**验证**

```sql
SELECT @@innodb_flush_log_at_trx_commit;   -- 1 = 每次提交都刷盘，最安全
SELECT trx_id, trx_state, trx_started, TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS 秒
FROM information_schema.innodb_trx ORDER BY 秒 DESC;
```

---

## 六、连接与连接池：V1 会撞上的墙

**三句话**

1. 一个连接 = 服务端一个**线程**，占内存、占调度。
2. `max_connections` 是硬上限（8.0 默认 151），超了直接拒绝。
3. 连接池不是越大越好：连接多了，锁竞争和上下文切换都会上升，吞吐反而下降。

**HikariCP 的经验公式**

```
连接数 ≈ CPU 核数 × 2 + 磁盘数
```

4 核机器 → 大约 9~10 个连接就够。但**真实约束往往不是这个公式，而是锁竞争**：
10 个连接全在等同一行锁时，第 11 个连接毫无意义。

**这就是 V1 的画面**：连接池 10 个，10 个请求卡在同一行，第 11 个请求报

```
HikariPool-1 - Connection is not available, request timed out after 30000ms
```

**验证**

```sql
SHOW STATUS LIKE 'Threads_connected';   -- 当前连接数
SHOW STATUS LIKE 'Threads_running';     -- 正在执行的（不含等待）
SHOW VARIABLES LIKE 'max_connections';
```

> `Threads_running` 高 → CPU 在忙；`Threads_connected` 高但 `Threads_running` 低 → **都在等锁**。

---

## 自测 5 题

1. `SELECT * FROM product WHERE id = 1` 和 `SELECT ... FOR UPDATE` 的区别是什么？哪个会阻塞别人？
2. 两个事务同时执行"先 SELECT 库存，判断 > 0，再 UPDATE 减 1"，为什么会超卖？把时间线画出来。
3. `UPDATE product SET stock = stock - 1 WHERE name = '测试商品'`，如果 `name` 没有索引，会锁多少行？
4. 为什么联合索引 `(a, b)` 在 `WHERE b = ?` 时用不上？
5. `Threads_connected = 200` 且 `Threads_running = 2`，系统最可能卡在哪？

## 面试追问清单

- 为什么 InnoDB 用 B+ 树而不是 B 树 / 哈希 / 跳表？
- 聚簇索引和二级索引的区别？什么是回表？怎么避免？
- MVCC 是怎么实现的？undo log 版本链 + ReadView。
- RR 和 RC 的区别？为什么 RR 能防幻读？
- 间隙锁什么时候加？为什么 RC 下几乎不加？
- 死锁怎么排查？`SHOW ENGINE INNODB STATUS` 里看什么？
- 一条 UPDATE 语句的执行流程？（连接 → 解析 → 优化 → 加锁 → 改页 → 写 redo → 提交）
- 为什么建议用自增主键？

# 锁的规则：从实验提炼的结论

> **三层文档分工**
> - 理论 → [mysql-notes.md](mysql-notes.md)（B+ 树、索引、事务、锁的定义）
> - 证据 → [V0.2 实验记录](../v0/02-rowlock/RESULTS.md)（原始输出与数字）
> - **结论 → 本文档**（可直接用于设计和面试的规则）
>
> 每一条规则后面都标了它的证据来源，数字都可以复现。

---

## 一、十条规则

### 规则 1：锁加在「索引记录」上，不是加在表或行号上

**证据**：`performance_schema.data_locks` 里 `INDEX_NAME = PRIMARY`、`LOCK_DATA = 1`。

**后果**：一行数据在几棵树上，就可能在几处被锁（二级索引 + 聚簇索引）。
所以"锁一行"可能对应 3 个锁条目，别用条目数直接当行数。

---

### 规则 2：锁在判断之前

`UPDATE` 的内部顺序是固定的：

```
定位 → 加锁 → 读最新值 → 判断 WHERE → 改 → 提交放锁
```

**证据**：库存为 0 时，`UPDATE ... WHERE stock >= 1` 影响 0 行，但另一个会话仍然阻塞 **3,113 ms** 后超时。

**后果**：
- "条件不成立"也要先付锁的代价
- **库存扣到 0 之后，QPS 不会回升**——所有人还在抢同一把锁
- 压测曲线会出现"卖完之后 QPS 依然满格、成功率归零"的平台期

---

### 规则 3：没有索引 ≈ 锁全表

InnoDB 只能逐行扫描，**每读一行就锁一行**，不匹配的锁在 RR 下还不释放。

**证据**：

| 数据量 | 锁条目 |
|---|---|
| 5 行，`name` 无索引 | 6 条（5 行 + supremum） |
| 5,000 行，`name` 无索引 | **5,018 条** |
| 5 行，`WHERE id = 3`（主键） | **1 条** |

**后果**：
- 一个用户的订单查询能让全站写操作停摆
- **给 `WHERE` 列建索引是并发系统的生死问题，不是性能优化**

---

### 规则 4：普通 `SELECT` 不申请任何锁

**证据**：X 锁持有时，普通 `SELECT` **89 ms** 返回（进程开销），`UPDATE` **2,098 ms** 超时。

**后果**：
- 锁限制的是"加锁的语句"，不是"所有读"
- "锁住了还能读吗" → 能

---

### 规则 5：但普通 `SELECT` 读到的是快照，不是最新值

**证据**：A 开事务读两次，中间 B 改成 500 并提交，A 第二次仍读到 **1000**；A 提交后才看到 500。

**后果**：
- **`SELECT` → 判断 → `UPDATE` 必然超卖**，因为那个 SELECT 看到的是过期的真相
- 必须把判断塞进 `UPDATE` 的 `WHERE` 里

---

### 规则 6：间隙锁锁的是「不存在的位置」

**证据**：数据只有 `1, 5, 10`，执行 `SELECT ... WHERE id = 7 FOR UPDATE`（7 不存在），
锁明细出现 `X,GAP` + `LOCK_DATA = 10`，即锁住了区间 **(5, 10)**。

**后果**：查询一个不存在的值，也会留下一个锁，挡住别人往这段里插入。

---

### 规则 7：间隙锁只挡 `INSERT`，不挡已有行的 `UPDATE` / `DELETE`

**证据**：`(5,10)` 被锁期间，`INSERT id=7` 超时 2,098 ms；`INSERT id=3`（另一个间隙）89 ms 成功。

**后果**：间隙锁保护的是"未来的行"，记录锁保护的是"已有的行"。

---

### 规则 8：间隙锁之间**不互斥**

两个事务可以同时持有同一个间隙的锁——因为它只表示"别往这儿插"，不代表拥有数据。

**后果**：真正冲突的是「间隙锁 vs 插入意向锁」，这是 **RR 下死锁率高的主要原因**。

---

### 规则 9：RC 会释放"不匹配行"的锁，RR 保留到事务结束

**证据**：5,000 行、`name` 无索引、匹配 0 行的 `UPDATE`：

| 隔离级别 | 持锁期间的锁条目 |
|---|---|
| REPEATABLE READ | **5,018** |
| READ COMMITTED | **0** |

**后果**：

| | RR | RC |
|---|---|---|
| 阻塞窗口 | **整个事务时长** | 语句执行时间 |
| 间隙锁 | 有 | 基本没有 |
| 挡 INSERT | **是** | 否 |
| 死锁概率 | 高 | 低 |
| 可重复读 | 保证 | 不保证 |

---

### 规则 10：锁持有时间 = 事务长度

**后果**：事务里做了 RPC、缓存写入、日志上报，锁就跟着延长。
**事务必须短**，这是并发系统的第一纪律。

---

## 二、锁范围速查表

| SQL 形式 | 索引情况 | 锁范围 | 典型 `LOCK_MODE` |
|---|---|---|---|
| `WHERE 主键 = 1` | 主键 | 1 行 | `X,REC_NOT_GAP` |
| `WHERE 唯一索引 = 'x'` | 唯一索引 | 1 行 | `X,REC_NOT_GAP` |
| `WHERE 普通索引 = 'x'` | 二级索引 | 命中的 N 行 + 边界间隙 | `X` / `X,GAP` |
| `WHERE 主键 BETWEEN 2 AND 4` | 主键 | 区间内所有行 + 区间内间隙 | `X` / `X,REC_NOT_GAP` |
| `WHERE 主键 = 7`（7 不存在） | 主键 | 一段间隙 | `X,GAP` |
| `WHERE 无索引列 = 'x'` | **无** | **扫描过的所有行（≈全表）** | `X` + `supremum` |
| `SELECT ...`（无后缀） | 任意 | **不加锁** | — |

**记忆锚点：锁多少条 = 扫描了多少条。**

---

## 三、RR 还是 RC

### 选择依据

| 你的场景 | 建议 |
|---|---|
| 高并发写入（订单、库存、支付） | **RC**：少锁、少死锁、少停摆 |
| 对账、报表、批量导出 | RR：需要"扫一遍数据不变" |
| 新手项目 / 不确定 | 先用默认 RR，把锁范围看清楚再决定 |
| 用 RC 的前提 | `binlog_format = ROW`（MySQL 8 默认已是 ROW） |

### 本项目（秒杀）的选择

**V1 先用默认 RR。** 理由：

1. V1 就是要让锁问题暴露得更明显（教学目的）
2. 等 V1 压测看到"锁全表/长事务"的代价，再决定是否切 RC——**这个决策要有数据支撑**
3. 如果切换到 RC，必须在 BENCHMARK.md 里记录，因为它会改变所有数字

**这是一个可以在面试里讲的决策点**：
"我一开始用默认 RR，压测发现不匹配行的锁保留到事务结束导致平台期，切到 RC 后 QPS 提升了 X%。"

---

## 四、线上锁等待排查三步

### 第一步：谁在等谁

```sql
SELECT r.trx_id AS waiting_trx, LEFT(r.trx_query, 60) AS waiting_sql,
       b.trx_id AS blocking_trx, LEFT(b.trx_query, 60) AS blocking_sql,
       TIMESTAMPDIFF(SECOND, b.trx_started, NOW()) AS blocking_secs
FROM performance_schema.data_lock_waits w
JOIN information_schema.innodb_trx b ON b.trx_id = w.BLOCKING_ENGINE_TRANSACTION_ID
JOIN information_schema.innodb_trx r ON r.trx_id = w.REQUESTING_ENGINE_TRANSACTION_ID;
```

### 第二步：锁了什么

```sql
SELECT ENGINE_TRANSACTION_ID, INDEX_NAME, LOCK_TYPE, LOCK_MODE, LOCK_STATUS, LOCK_DATA
FROM performance_schema.data_locks
ORDER BY ENGINE_TRANSACTION_ID;
```

### 第三步：这个事务跑了多久

```sql
SELECT trx_id, trx_state, trx_started,
       TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS 秒,
       trx_rows_locked, trx_rows_modified, LEFT(trx_query, 80) AS sql
FROM information_schema.innodb_trx
ORDER BY 秒 DESC;
```

**看到 `trx_rows_locked` 是几百万、`秒` 是几十——不用再查了，就是没索引 + 长事务。**

---

## 五、对 V1 的硬性约束

这四条不是建议，是**做错了数字就无效**的约束：

| # | 约束 | 违反的后果 |
|---|---|---|
| 1 | `WHERE` 用到的列必须有索引 | 锁全表，压测数字全部作废 |
| 2 | 用单条 `UPDATE ... WHERE stock >= 1`，不用"先查再改" | 超卖 |
| 3 | 事务里不夹 RPC / 日志 / 缓存写 | 锁持有时间被拉长，QPS 崩塌 |
| 4 | 压测按 `200 / 409 / 5xx` 分类统计 | 把"售罄"当"故障"，看不出真实瓶颈 |

第 4 条的背景见规则 2：**卖完之后 QPS 不降，只有成功率降**。只看 QPS 会得出完全错误的结论。

---

## 六、面试十问（附答题要点）

**Q1 锁加在哪？**
> 索引记录上。`data_locks` 的 `INDEX_NAME` 和 `LOCK_DATA` 可以直接证明。

**Q2 为什么没索引会锁全表？**
> 只能逐行扫描，每读一行锁一行；RR 下不匹配的锁还保留到事务结束。

**Q3 为什么库存为 0 还要加锁？**
> 加锁在判断之前。不知道条件成不成立，得先锁住再读再判断（否则 TOCTOU）。

**Q4 普通 SELECT 会被锁阻塞吗？**
> 不会，它不申请锁。但它读到的是快照，可能是旧值。

**Q5 什么是间隙锁？为什么需要？**
> 锁住两条记录之间的空隙，防止别人 INSERT。目的是防幻读——保证同一事务内查询结果不变多。

**Q6 间隙锁之间互斥吗？**
> 不互斥。冲突的是间隙锁和插入意向锁，这是 RR 死锁多发的根源。

**Q7 RR 和 RC 的差别？**
> RC 会立刻释放不匹配行的锁、基本没有间隙锁；RR 保留到事务结束、有间隙锁。实测同一语句 5,018 条锁 vs 0 条。

**Q8 线上锁等待怎么查？**
> `data_lock_waits` 看谁等谁 → `data_locks` 看锁了什么 → `innodb_trx` 看事务跑了多久。

**Q9 为什么事务要短？**
> 锁持有时间 = 事务长度；长事务还让 undo 版本链变长、拖住 purge。

**Q10 秒杀为什么用单条 UPDATE 而不是 FOR UPDATE？**
> 单条 UPDATE 把"判断 + 修改"合成一次原子操作，锁只持有语句执行的那一瞬间；
> `FOR UPDATE` 要把锁从 SELECT 持有到 COMMIT，热点行场景下并发直接塌。

---

## 待办：这些还没验证

- [ ] 10 万行数据上 `EXPLAIN` 的 `type` / `rows` / 实际耗时对比（V0.3）
- [ ] 热点行在真实并发下的 TPS 基线（V0.4）
- [ ] 切换到 RC 后 QPS 的变化（V1 阶段做对照）
- [ ] `innodb_buffer_pool_size` 调大后的变化（V1 调优）

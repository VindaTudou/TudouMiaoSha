# V0.2 行锁：看见 `UPDATE` 卡住

> 目的：把"行锁""锁加在索引上""卖完了还在抢锁"从概念变成可复现的现象。
> 这三点直接决定 V1 的写法和 V1-b 的结论。

## 环境

| 项 | 值 |
|---|---|
| MySQL | 8.4.5（`miaosha-mysql` 容器，4 核 / 512 MB buffer pool） |
| 隔离级别 | `REPEATABLE-READ`（默认） |
| `innodb_lock_wait_timeout` | 50 s（实验中按会话调成 2~3 s，省时间） |
| 数据 | `product` 表 1 行，`id=1, stock=1000` |
| 复现 | `bash demo.sh` / `bash lock-scope.sh` |
| 原始输出 | `run-log.txt` / `lock-scope-log.txt` |

---

## 实验一：X 锁 —— 两个会话抢同一行

```
A: BEGIN → UPDATE stock=stock-1 → 持锁 6 秒 → COMMIT
B: 同一条 UPDATE（会话超时设 3 秒）
```

| 观测 | 值 |
|---|---|
| B 等待时长 | **3,123 ms** |
| B 的结果 | `ERROR 1205 (HY000): Lock wait timeout exceeded` |
| 最终库存 | **999**（B 失败，只有 A 扣成功） |

3 秒超时 → 等了 3123 ms，多出来的 100 ms 是建立连接的开销。

---

## 实验二：锁的明细 —— 加在哪、谁在等谁

B 阻塞期间查 `performance_schema.data_locks`：

```
trx    tbl      idx       LOCK_TYPE  LOCK_MODE       LOCK_STATUS  LOCK_DATA
1840   product  NULL      TABLE      IX              GRANTED      NULL
1841   product  NULL      TABLE      IX              GRANTED      NULL
1840   product  PRIMARY   RECORD     X,REC_NOT_GAP   GRANTED      1
1841   product  PRIMARY   RECORD     X,REC_NOT_GAP   WAITING      1
```

`data_lock_waits`：

```
waiting_trx  blocking_trx
1841         1840
```

**逐列解读（这张表是面试硬通货）**：

| 字段 | 含义 | 本例说明 |
|---|---|---|
| `INDEX_NAME = PRIMARY` | 锁加在**哪棵索引**上 | 主键索引 |
| `LOCK_DATA = 1` | 锁的是**哪条记录** | 主键值 1 |
| `LOCK_TYPE = RECORD` | 记录级锁 | 不是表锁 |
| `LOCK_MODE = X,REC_NOT_GAP` | 排他锁，**不含间隙** | 等值查主键 → 退化为纯记录锁 |
| `LOCK_TYPE = TABLE` + `IX` | **意向排他锁**（表级） | 表示"我下面有行锁"，用来快速判断表锁能否加 |
| `LOCK_STATUS` | `GRANTED` 已获得 / `WAITING` 在等 | 一条 granted 一条 waiting |

**结论：锁是加在「索引记录」上的，不是加在「表」或「行号」上。**
证据就是 `INDEX_NAME` 和 `LOCK_DATA` 这两列。

---

## 实验三：普通 `SELECT` 不被锁阻塞

```
A: BEGIN → SELECT stock（读到 1000）→ 睡 4 秒 → 再 SELECT → COMMIT
期间 B: UPDATE stock=500 并提交
```

| 时刻 | A 读到 |
|---|---|
| 第一次 SELECT | 1000 |
| B 已把 stock 改成 500 并提交 | — |
| 第二次 SELECT | **还是 1000** |
| A 提交后再查 | **500** |

**普通 `SELECT` 是快照读：不申请锁，所以不会被 X 锁阻塞；但它读到的是旧快照。**

这一条同时解释了两件事：

1. 为什么"锁住了还能读"——锁限制的是**加锁的语句**，不是所有读
2. 为什么"先 SELECT 判断再 UPDATE"会超卖——那个 SELECT 看到的是一个**已经过期的真相**

---

## 实验四：库存为 0 时，条件更新仍然会锁 ⚠️

```
先把 stock 改成 0
A: BEGIN → UPDATE ... WHERE stock >= 1（影响 0 行）→ 持锁 6 秒
B: 同一条 UPDATE（超时 3 秒）
```

| 观测 | 值 |
|---|---|
| B 等待时长 | **3,113 ms** |
| B 的结果 | `ERROR 1205 Lock wait timeout exceeded` |

**库存已经是 0，条件永远不成立，但 B 还是在等锁。**

原因（对照《MySQL 笔记》第八章的 UPDATE 执行顺序）：**加锁发生在判断条件之前**。A 虽然一行都没改到，但那行已经被锁过了，直到 COMMIT 才释放。

> **这里的结论只有一半是对的（V0.4 已更正）**：
> 锁确实还在抢，但"没有修改任何数据"的事务提交时几乎不花钱，
> 所以实测吞吐**反而升高 9 倍**（1,919 → 17,900 QPS）。
> 见 [V0.4 基线测量](../03-baseline/RESULTS.md) 第四节。

---

## 实验五：S 锁 —— 别人能读，不能写

```
A: BEGIN → SELECT ... FOR SHARE → 持锁 6 秒
B1: 普通 SELECT
B2: UPDATE（超时 2 秒）
```

| 操作 | 耗时 | 结果 |
|---|---|---|
| 普通 `SELECT` | 89 ms | 正常返回（**不阻塞**） |
| `UPDATE` | 2,098 ms | `ERROR 1205` 超时 |

89 ms 主要是 `docker exec` 拉起客户端的开销，不是锁等待；对比 2,098 ms 就看得很清楚。

**S 锁只挡住了写，没挡住读。** 这跟实验三的结论一致。

---

## 实验六：锁的范围由索引决定 ⭐

同一个 `UPDATE ... WHERE name = 'B'`，只差一个索引：

### name 上没有索引

```
LOCK_MODE  LOCK_DATA
X          1
X          2
X          3
X          4
X          5
X          supremum pseudo-record
```

**锁了 6 条：5 行数据 + supremum（最后一条记录到"正无穷"的间隙）。**

等于**把整张表锁住**。表里有 100 万行，就锁 100 万行。

### 给 name 建上索引后

```
LOCK_MODE       LOCK_DATA
X               'B', 2
X,GAP           'C', 3
X,REC_NOT_GAP   2
```

**只锁了 'B' 这一行相关的几个条目。**

### 差别

| | 无索引 | 有索引 |
|---|---|---|
| 锁条目 | 5 行 + supremum = **6** | 1 行的索引项 + 主键项 = **3** |
| 实际影响 | 全表 | 一行 |
| 并发度 | 任何写都排队 | 不同行可以并行 |

**`LOCK_MODE` 的四种取值（背下来）**：

| 值 | 含义 | 出现场景 |
|---|---|---|
| `X` | Next-Key Lock（记录 + 前面的间隙） | 二级索引等值/范围查询 |
| `X,REC_NOT_GAP` | 纯记录锁，不含间隙 | **唯一索引或主键等值查询** |
| `X,GAP` | 纯间隙锁 | 范围边界 |
| `supremum pseudo-record` | 最后一条记录之后的间隙 | 扫描到表尾 |

> **建索引不只为了查得快，更是为了锁得少。**
> 这条在写并发业务时比性能重要得多——性能差是慢，锁范围大是直接不可用。

---


## 实验七：隔离级别决定"失败后还锁不锁"

库存 = 0，A 执行 `UPDATE ... WHERE stock >= 1`（影响 0 行）后持锁 5 秒，B 再执行同一条：

| A 的隔离级别 | B 等待 | 结果 |
|---|---|---|
| **REPEATABLE READ**（默认） | **3,116 ms** | `ERROR 1205` 超时 |
| **READ COMMITTED** | **88 ms** | 立即返回（无错误） |

原因：**READ COMMITTED 下，InnoDB 会在评估完 WHERE 之后释放"不匹配行"上的锁**；
REPEATABLE READ 下则保留到事务结束。

> 所以"卖完了还在抢锁"这件事，**在 RC 下会轻很多，在 RR 下会一直持续**。
> 但这不改变吞吐天花板：只要还有并发写同一行，锁就是串行的。

## 附：怎么读 `performance_schema.data_locks`

### 字段速查

| 字段 | 取值 | 含义 |
|---|---|---|
| `ENGINE_TRANSACTION_ID` | 数字 | 事务 ID，用来和 `innodb_trx` 对上 |
| `INDEX_NAME` | `PRIMARY` / `idx_name` / `NULL` | 锁加在哪棵索引上；`NULL` 表示表级锁 |
| `LOCK_TYPE` | `TABLE` / `RECORD` | 表级锁 / 记录锁 |
| `LOCK_MODE` | `IX` `X` `S` `X,REC_NOT_GAP` `X,GAP` | 见下表 |
| `LOCK_STATUS` | `GRANTED` / `WAITING` | 已获得 / 在排队 |
| `LOCK_DATA` | `1` 或 `'B', 2` | 锁的是哪条记录 |

### `LOCK_MODE` 的四种形态

```
索引里记录的排列：
    ┌───┬───┬───┬───┬───┐
    │ A │ B │ C │ D │ E │
    └───┴───┴───┴───┴───┘

X（Next-Key）    = 记录 + 它前面的间隙
X,REC_NOT_GAP    = 只有记录，不含间隙（唯一索引/主键等值查询）
X,GAP            = 只有间隙
IX（表级）        = 意向排他锁，只声明"我下面有行锁"，不锁数据
```

### `LOCK_DATA` 的格式

| 索引 | `LOCK_DATA` 长什么样 | 说明 |
|---|---|---|
| 主键索引 | `1` | 主键值 |
| 二级索引 | `'B', 2` | **索引列值 + 主键值** |

二级索引那行直接印证了《MySQL 笔记》里的结论：**二级索引叶子存的是 (索引列, 主键)**。

### 一条能直接用的排查 SQL

```sql
SELECT r.trx_id AS waiting_trx, LEFT(r.trx_query, 40) AS waiting_sql,
       b.trx_id AS blocking_trx, LEFT(b.trx_query, 40) AS blocking_sql,
       TIMESTAMPDIFF(SECOND, b.trx_started, NOW()) AS blocking_secs
FROM performance_schema.data_lock_waits w
JOIN information_schema.innodb_trx b ON b.trx_id = w.BLOCKING_ENGINE_TRANSACTION_ID
JOIN information_schema.innodb_trx r ON r.trx_id = w.REQUESTING_ENGINE_TRANSACTION_ID;
```

实测输出（A 在 `DO SLEEP(6)` 期间持锁，B 的 UPDATE 在等）：

```
waiting_trx  waiting_sql                            blocking_trx  blocking_sql    blocking_secs
1903         UPDATE product SET stock=stock-1 ...    1902          DO SLEEP(6)     2
```

**一眼看出"谁在等谁、等的是哪条 SQL、阻塞方已经跑了多久"。**
线上出现锁等待时，这条 SQL 就是第一手证据。

> 注意 `blocking_sql` 显示的是 `DO SLEEP(6)`——因为阻塞方此时正在执行那条语句。
> 真正把它锁住的是它事务里**上一条** UPDATE。看 `innodb_trx` 的 `trx_query` 只能看到"当前在跑什么"，
> 要看"加了什么锁"得回到 `data_locks`。

## 实验八：间隙锁 —— 锁住"不存在的位置"

数据只有 id = 1、5、10，**7 不存在**。

```sql
A: BEGIN; SELECT id FROM product WHERE id = 7 FOR UPDATE;   -- 查一个不存在的行
```

A 锁住了什么：

```
LOCK_MODE   LOCK_DATA
X,GAP       10
```

`LOCK_DATA = 10` 表示**锁住 id=10 之前的那段间隙，也就是 (5, 10)**。

两个插入的结果：

| B 的操作 | 等待 | 结果 |
|---|---|---|
| `INSERT id = 7`（落在 (5,10) 里） | **2,098 ms** | `ERROR 1205` 超时 |
| `INSERT id = 3`（落在 (1,5) 里） | **89 ms** | 成功 |

最终数据：`1, 3, 5, 10` —— 只多了 3，7 被挡住。

**结论：**
1. 间隙锁锁的不是记录，是**两条相邻记录之间的区间**。
2. 它只挡 `INSERT`，不挡已有行的 `UPDATE` / `DELETE`。
3. 查询一个不存在的值，也会留下一个锁。

## 结论

1. **锁加在索引记录上**：`INDEX_NAME` + `LOCK_DATA` 两列就是证据。
2. **没有索引 ≈ 锁全表**：扫过的每一行都被锁，还包括 supremum。
3. **普通 `SELECT` 不等锁，但读旧快照**：这就是超卖的根因。
4. **加锁在判断条件之前**：库存为 0、条件不成立，锁照样加、照样等。
5. **S 锁挡写不挡读**，且升级易死锁，实践中基本用 `FOR UPDATE`。

## 对 V1 的意义

| 现象 | V1 会变成什么 |
|---|---|
| B 等 3 秒超时 | 应用连接池 10 个连接，10 个请求各等 3 秒 → 第 11 个请求直接报 `Connection is not available` |
| 库存 0 仍然等锁 | 锁还在抢，但**没有写操作 → 提交极快 → 吞吐反而升高**（已实测，原预测错误） |
| 无索引锁全表 | V1 的 `WHERE` 列必须有索引，否则压测数字全部作废 |
| 快照读不加锁 | V1-a 的 `SELECT → 判断 → UPDATE` 必然超卖，且并发越高超得越多 |

## 复现

```bash
make up
cd v0/02-rowlock
bash demo.sh          # 实验一 ~ 五
bash lock-scope.sh    # 实验六
```

两个脚本都会在结束时把 `product` 恢复成 1 行、`stock=1000`、只有主键索引。

## 清理

```bash
make down     # 停容器，保留数据
make reset    # 连数据卷一起删
```

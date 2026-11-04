# V1-a 测试原理与结果

> 这一版的目的不是"实现一个下单接口"，是**用压力把最朴素的实现压坏**，
> 让「超卖」和「性能天花板」同时暴露，为 V2 提供立项依据。
>
> 配套：核心汇总表在 [../BENCHMARK.md](../BENCHMARK.md)，架构图在 [../architecture.md](../architecture.md)。

---

## 一、被测的东西

### 应用

Spring Boot 3.3.5 + JdbcTemplate（不用 JPA，因为要看 SQL 原文）。

| 接口 | 说明 |
|---|---|
| `GET /api/products?page=&size=` | 商品列表 |
| `GET /api/products/{id}` | 商品详情 |
| `POST /api/orders` | 下单，`{userId, productId, quantity}` |

状态码约定：

| 码 | 含义 | 算不算错误 |
|---|---|---|
| 200 | 下单成功 | — |
| **409** | **售罄** | **不算，是业务结果** |
| 404 | 商品不存在 | 不算（压测不会触发） |
| 5xx | 系统错误 | 算 |

### 故意留的缺陷

```java
@Transactional
public String create(long userId, long productId, int quantity) {
    Product p = products.findById(productId)...;               // ① 快照读，不加锁
    if (p.stock() < quantity) throw new SoldOutException();    // ② 判断
    products.overwriteStock(productId, p.stock() - quantity);  // ③ 覆盖写 ← 错在这
    orders.insert(orderNo, ...);                               // ④ 落订单
}
```

第 ③ 步是 `UPDATE product SET stock = ? WHERE id = ?`，把应用算好的**绝对值**盖回去。

```
请求 A: 读到 1000 → 算 999 ──────────────→ 写回 999
请求 B:      读到 1000 → 算 999 → 写回 999
                                    ↑ A 的结果被覆盖
```

两个请求都成功，库存只减 1。这是 V0.1 `count++` 的数据库版。

### 故意留的口子

`orders` 表**没有** `UNIQUE(user_id, product_id)`，同一用户连点两次会产生两单。幂等留到 V2。

### 关键配置

| 配置 | 值 | 理由 |
|---|---|---|
| HikariCP `maximum-pool-size` | 10 | V0.4 实测 4 线程就打满热点行，10 足够 |
| HikariCP `connection-timeout` | 3000 ms | 默认 30 秒太久，压测时看不清问题 |
| Tomcat `threads.max` | 200 | 默认值，用来看会不会打满 |
| 事务边界 | `@Transactional` 包住 ③④ | 扣库存和写订单要一起成功 |

---

## 二、压测方法

### 为什么下单用 `constant-arrival-rate`

k6 两种执行器：

| 执行器 | 行为 | 问题 |
|---|---|---|
| `ramping-vus` | 固定并发数，能跑多快跑多快 | **系统变慢 → VU 被阻塞 → 压力自动变小**，永远测不到上限 |
| `constant-arrival-rate` | 不管快慢，每秒固定发 N 个 | 才是"秒杀"：用户不管你快不快，人就是要来 |

### 结果必须三分类

```js
if (res.status === 200)      orderSuccess.add(1);
else if (res.status === 409) orderSoldOut.add(1);   // 业务结果
else                         orderOther.add(1);     // 5xx，这才是故障
```

混在一起算"错误率"，卖完了会被当成系统挂了，结论全反。

### 每轮重置数据

```sql
UPDATE product SET stock = 10000000 WHERE id = 1;  -- 保证不卖完
DELETE FROM orders;
```

---

## 三、三轮定位过程

### 第一轮：数字不对，先怀疑自己

第一次扫描，所有到达率都只出 ~830/s。查 k6 输出：

```
dropped_iterations: 62879  (2978/s)
```

**k6 说"我没发出请求"**——`maxVUs: 1000` 被占满。提到 3000 后重跑，同样条件能到 951/s。

> 这一轮的数字全部作废。差的那 15% 不是系统差，是压测机差。

### 第二轮：怀疑连接池

池子 10 → 50：

| 连接池 | 到达率 2000 时实际下单 | P99 |
|---|---|---|
| 10 | 926 /s | 3.9 s |
| 50 | 907 /s | 4.3 s |

**没变化，甚至更差。** 连接池不是瓶颈。

采样证明池子确实满了，但不是"卡"在这：

```
时刻   max   active   idle   pending
 2s     10     10       0      189      ← 满了，189 个线程在排队
 3s     10      0      10        0      ← 全空了（k6 发不出请求了）
```

**重要细节**：`active=10` 说明连接被占着，但每个连接**绝大部分时间在等行锁**，不是在干活。
所以「能支撑的吞吐 = 连接数 ÷ 单请求占用时间」里，那个"占用时间"是 1 ms 里 0.5 ms 在等锁。

### 第三轮：对照实验定位到"那一行"

其他条件全部不变，只改"打哪一行"：

| 场景 | 实际下单 | P99 |
|---|---|---|
| 全打 `id=1` | 926 /s | **3.9 s** |
| 分散到 9 万 SKU | **1,989 /s** | **46 ms** |

**吞吐 2.2 倍，P99 43 倍。** 控制变量的排他性证据。

---

## 四、结果

### 正确性

| 场景 | 初始库存 | 并发 | 成功下单 | 最终库存 | 超卖 |
|---|---|---|---|---|---|
| 60 个用户各下 1 单 | 10 | 60 | **43** | 0 | **33 单** |

### 性能

| 到达率 | 实际下单 | P99 | MySQL CPU | 应用 CPU |
|---|---|---|---|---|
| 500 | 496 /s | 297 ms | 14.6% | 7.9% |
| 1000 | 915 /s | 2.2 s | 16.7% | 3.0% |
| 2000 | 926 /s | 3.9 s | 19.0% | 1.3% |
| 4000 | 951 /s | 3.9 s | 17.6% | 0.6% |

**到达率 ×8，吞吐 ×1.9，P99 ×13。**

### 和 V0.4 基线的对照

| 谁在压 | 单行热点吞吐 |
|---|---|
| V0.4：裸 JDBC 直接压 MySQL | ~2,000 TPS |
| V1-a：通过 Spring Boot + 事务 | **~950 TPS** |

差的那一半 = 「事务把 UPDATE + INSERT + COMMIT 包在一起」带来的锁持有时间。

> **结论：同一行，事务越长，吞吐越低。**

---

## 五、结论

1. **超卖和性能瓶颈是同一个根因**：所有请求都在争 MySQL 里同一行。
2. **加连接池无效**（10 → 50，吞吐 926 → 907）。
3. **CPU 只用了 19%**——在等，不在算。
4. **V2 的立项理由不是"Redis 比较快"，是"对照实验证明瓶颈就是单行串行写"。**

---

## 六、怎么复现

```bash
# 0. 前置：MySQL 容器在跑，10 万行数据已灌好
make up
bash v0/03-baseline/setup.sh

# 1. 编译并启动应用
make app-build
make app-bg
curl -s http://127.0.0.1:8080/actuator/health     # 期望 status=UP

# 2. 复现超卖（约 10 秒）
docker exec -i -e MYSQL_PWD=root miaosha-mysql mysql -uroot --default-character-set=utf8mb4 miaosha \
  -e "UPDATE product SET stock=10 WHERE id=1; DELETE FROM orders;"

seq 1 60 | xargs -P 20 -I{} curl -sS -o /dev/null -w '%{http_code}\n' \
  -X POST http://127.0.0.1:8080/api/orders \
  -H 'Content-Type: application/json' \
  -d '{"userId":{},"productId":1,"quantity":1}' | sort | uniq -c

docker exec -i -e MYSQL_PWD=root miaosha-mysql mysql -uroot --default-character-set=utf8mb4 miaosha \
  -e "SELECT COUNT(*) AS 订单数 FROM orders; SELECT stock AS 库存 FROM product WHERE id=1;"
# 期望：订单数 ≈ 40~50，库存 0

# 3. 容量扫描（约 3 分钟）
bash loadtest/run-capacity.sh

# 4. 对照实验：分散到 9 万 SKU
K6=tools/k6/2.3.0/bin/k6
docker exec -i -e MYSQL_PWD=root miaosha-mysql mysql -uroot miaosha \
  -e "UPDATE product SET stock=10000000; DELETE FROM orders;"
$K6 run -e BROWSE_ON=0 -e PRODUCT_ID=random -e RATE=2000 -e SECKILL_DURATION=20s loadtest/k6/v1.js
# 期望：~1989/s，p99 ~46ms
```

---

## 七、已知限制（面试时要主动说）

| 限制 | 影响 |
|---|---|
| 压测机和应用在**同一台 Mac** | 系统饱和时 k6 自己会先撑不住，测出来是下限 |
| 应用在宿主机（8 核），MySQL 在容器（4 核） | 应用侧 CPU 数字偏乐观 |
| k6 与 Homebrew 都不通 Docker Hub | 镜像拉不到，应用只能跑在宿主机 |
| 数据全部放在一个 MySQL，无副本 | 单点，V3 再谈 |

> **主动说出这些限制，比掩饰它们更能证明你真的做过实验。**

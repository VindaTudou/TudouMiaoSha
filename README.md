# TudouMiaoSha — 秒杀商城

用「秒杀」这个场景，把后端架构的每一个决策**用压测数据逼出来**，而不是抄一套企业级配置。

目标：一个能复现、能压测、每个决策都有数据支撑的秒杀系统。
所有优化都必须先有瓶颈证据，再有改造。

**文档入口 → [docs/README.md](docs/README.md)**

## 进度

| 阶段 | 内容 | 状态 | 记录 |
|---|---|---|---|
| V0.1 | 丢失更新：并发写同一值的真相 | ✅ 完成 | [RESULTS](docs/v0/01-concurrency.md) |
| V0.2 | MySQL 行锁：亲眼看见 `UPDATE` 卡住 | ✅ 完成 | [RESULTS](docs/v0/02-rowlock.md) |
| V0.3 | 索引：10 万行上 `type=ALL` vs `ref` | ✅ 完成 | [RESULTS](docs/v0/03-baseline.md) |
| V0.4 | 热点行 TPS 基线：后面容量估算的锚点 | ✅ 完成 | 同上 |
| V1-a | 单体 + 直接查库，无锁下单 → 看超卖 | ✅ 完成 | [测试原理与结果](docs/v1/experiment.md) |
| V1-b | 条件更新修超卖 → 看吞吐代价 | ✅ 完成 | [BENCHMARK](docs/BENCHMARK.md) |
| V2 | Redis 预扣 + MQ 削峰 | ✅ 完成 | [实验记录](docs/v2/experiment.md) |
| V3-M1 | 可观测性：Prometheus + Grafana + 4 个自定义指标 | ✅ 完成 | [实验记录](docs/v3/experiment.md) |
| V3-M2 | 容量实测：**8,000/s 阈值**、12,000/s 拥塞崩溃 | 🚧 进行中 | 同上（实验 C 限流对比待做） |
| V3-M3 | 多实例 + 雪花号 + Nginx 负载均衡 | ⬜ 待做 | — |
| V3-M4 | 故障演练：杀 Redis / Kafka / MySQL + 熔断 | ⬜ 待做 | — |

### 一句话结论（截至 V3-M2）

| 问题 | 实测答案 |
|---|---|
| 能扛多少 | **可持续 ≈ 9,600/s**，阈值取 8,000/s |
| 崩溃长什么样 | 不是 5xx，是**吞吐倒挂**：投放 +20% → 吞吐 −11%，P99 1,518ms |
| 瓶颈在哪 | **Tomcat accept 队列**（服务端 P99 仅 124ms，客户端 1,518ms） |
| 加堆有用吗 | 没用（`-Xmx384m` vs `1024m`，堆峰值都只有 219MB） |

## 目录

```
docs/          ★ 所有文档都在这里，入口：docs/README.md
  README.md        文档索引
  BENCHMARK.md     每一版的压测数字（带 commit）
  architecture.md  各版本架构图与决策
  mysql-notes.md   MySQL 完整笔记
  locking-rules.md 锁的十条规则 + 面试十问
  v0/ v1/          各阶段实验记录

app/           Spring Boot 应用
db/            schema + seed
loadtest/      压测脚本（k6）
v0/            地基实验的代码（结论见 docs/v0/）
tools/         k6 二进制（不入库）
```

> **约定：代码目录只放能跑的东西，所有文字记录都进 `docs/`。**

## 复现

```bash
# 需要 JDK 17、Docker、bash
git checkout v0.1
cd v0/01-concurrency && bash run-sweep.sh
```

## 版本管理约定

**提交信息**：以阶段号开头，冒号后写做了什么、为什么。

```
V0.1: 丢失更新实验（三种实现 + 扫描脚本 + 数据）
V1-a: 单体下单接口，故意不加锁，复现超卖
V1-b: 改条件更新，超卖归零但 P99 变差
bench: V1-a 三轮压测原始数据（k6 summary json）
docs: 补充 BENCHMARK 的 V1-a/V1-b 两行
fix:  修 seed 脚本重复插入
```

**里程碑用 tag 标记**：`v0.1` `v1a` `v1b` `v2` `v3`

**为什么要 tag**：BENCHMARK.md 里的每个数字都必须能追溯到一份确定的代码。
压测前打 tag，压完把 tag 名填进表格——这是"怎么证明数字不是假的"最硬的答案。

**回滚**

```bash
git log --oneline --decorate     # 看历史
git checkout v0.1                # 临时看某个版本（只读）
git switch main                  # 回到主线
git revert <commit>              # 撤掉某次提交（保留历史，安全）
git reset --hard <commit>        # 丢弃提交（只在本地、确认无用时）
```


## 在 IDE（IntelliJ IDEA）里打开

本项目把 Maven 依赖装在**仓库内**的 `.m2repo`，不写全局 `~/.m2`。
IDE 没指向这个目录时，`@Repository` `@Service` `@RestController` 等注解会标红，
但代码本身是对的——命令行 `make app-build` 能编译通过即可确认。

### 配置步骤

1. `File → Open` 选择 **`app/pom.xml`**（不是仓库根目录），按 "Open as Project"
2. Settings → Build, Execution, Deployment → Build Tools → Maven
   - **Local repository**：勾选 Override，填 `<仓库根目录>/.m2repo`（绝对路径）
   - 或者保持默认——`app/.mvn/maven.config` 里已经写了
     `-Dmaven.repo.local=../.m2repo`，IDEA 导入时会读到
3. Maven 面板点 **Reload All Maven Projects**

### 如果还标红

- 检查 JDK：Project Structure → SDK 必须是 **17**
- `mvn` 面板 → Execute Maven Goal → `clean compile`，看真实报错
- 命令行验证：`make app-build`。**命令行能过，就是 IDE 配置问题，不是代码问题**

## 端口分配

宿主机已有服务占用默认端口时，容器按下表错开。改端口同步改 `docker-compose.yml`。

| 服务 | 宿主机端口 | 容器内 | 说明 |
|---|---|---|---|
| MySQL | **3307** | 3306 | 避开宿主机原生 MySQL |
| Redis | **6380** | 6379 | 避开宿主机原生 Redis |
| Kafka | 9092 | 9092 | — |
| 应用 | 8080 | 8080 | 跑在宿主机 |

## 运行环境要求

| 项 | 要求 |
|---|---|
| JDK | **17**（实现上用到 Spring Boot 3，最低 17） |
| 容器 | Docker + Compose（MySQL 8.4 / Redis 7 / Kafka 3.8） |
| 压测 | k6 ≥ 2.3 |
| 架构 | **arm64 原生镜像**。混入 amd64 会走 QEMU 模拟，测出来的是模拟器性能 |

> 具体的机器型号、核数、内存配额属于测量基准，记录在
> [BENCHMARK.md](docs/BENCHMARK.md) 顶部——因为压测数字只在同一配额下可比。

## 许可

[MIT](LICENSE)。压测数据、实验记录、踩坑过程都可以随便引用；
如果这些数字帮你省下一次翻车，那就值了。


# 文档索引

**所有文档都在 `docs/` 下。代码目录只放能跑的东西。**

## 怎么读

```
想快速了解项目      → BENCHMARK.md（数字）+ architecture.md（图）
想补基础            → mysql-notes.md → locking-rules.md
想看某个实验        → v0/ 下的对应记录
想复现              → 每篇文档末尾都有命令
面试前              → locking-rules.md 的「面试十问」+ BENCHMARK.md
```

## 总览

| 文档 | 内容 | 更新时机 |
|---|---|---|
| [BENCHMARK.md](BENCHMARK.md) | **每一版的压测数字**，每行带 commit、场景、到达率、P99、5xx、瓶颈、改造 | 每次压测后 |
| [architecture.md](architecture.md) | 各版本架构图（Mermaid）+ 决策表 + 为下一版留下的问题 | 每版完成时 |

## 基础知识

| 文档 | 内容 |
|---|---|
| [mysql-notes.md](mysql-notes.md) | B+ 树、聚簇/二级索引、回表、MRR、MVCC、S/X 锁、日志、连接池。含 10 道自测题 |
| [locking-rules.md](locking-rules.md) | **锁的十条规则**（每条带证据）、锁范围速查表、RR vs RC 决策、线上排查三步、面试十问 |

## 实验记录

| 阶段 | 文档 | 一句话结论 |
|---|---|---|
| V0.1 | [v0/01-concurrency.md](v0/01-concurrency.md) | 两个线程就丢 33%，并发正确性没有中间态 |
| V0.2 | [v0/02-rowlock.md](v0/02-rowlock.md) | 锁加在索引记录上；没索引 ≈ 锁全表 |
| V0.2 | [v0/02-rowlock-lab.md](v0/02-rowlock-lab.md) | 行锁实验手册（可照着敲） |
| V0.3/V0.4 | [v0/03-baseline.md](v0/03-baseline.md) | 没索引的 UPDATE 慢 142 倍；单机热点行 2000 TPS |
| V1-a/b | [v1/experiment.md](v1/experiment.md) | 超卖 33 单 → 0 单；吞吐封顶 950/s，根因是单行热点 |
| V2 | [v2/experiment.md](v2/experiment.md) | 请求侧 950 → 3,000/s（P99 16ms），但落库仍 950/s；瓶颈被搬走没被消灭。含 `linger.ms` 假设被推翻的记录 |
| V3 | [v3/experiment.md](v3/experiment.md) | 可观测性（M1）：计数 3 次对账误差 0.00%；发现延迟方差 19 倍、单商品只占 1 个分区 |
| V3 | [v3/m2-experiment-a.html](v3/m2-experiment-a.html) | **M2 实验 A**：容量拐点 1,000→5,000，P99 中位与范围 |
| V3 | [v3/m1-report.html](v3/m1-report.html) | **M1 数据图**（8 张）：预热曲线、对账、监控开销、进水和出水、积压水位、耗时分解、分区分布、GC |

## 代码在哪

| 实验 | 代码位置 |
|---|---|
| V0.1 并发 | `v0/01-concurrency/*.java` + `run-all.sh` |
| V0.2 行锁 | `v0/02-rowlock/demo.sh`、`lock-scope.sh` |
| V0.3/0.4 基线 | `v0/03-baseline/setup.sh`、`HotspotBench.java` |
| V1 应用 | `app/` |
| V2 应用 | `app/`（同上，V2 是在同一套代码上演进） |
| 压测 V1 | `loadtest/k6/v1.js`、`loadtest/run-capacity.sh` |
| 压测 V2 | `loadtest/k6/v2.js`、`loadtest/run-capacity-v2.sh`（含 lag 采样与对账） |
| 可观测性 V3 | `ops/observability.sh`（起停）、`ops/prometheus/`、`ops/grafana/`、`ops/verify-metrics.sh` |

## 写作约定

1. **数字必须带配置**：线程数、数据量、隔离级别、commit。缺一个就不可复现。
2. **结论只写"稳定的部分"**：比如"是否为 0"稳定，"丢失率多少"不稳定。
3. **失败也要记**：写错过的结论、被推翻的假设，保留 ⚠️ 更正记录。
4. **已知限制主动写**：环境不对称、压测机瓶颈、单点——说清楚比掩饰更可信。

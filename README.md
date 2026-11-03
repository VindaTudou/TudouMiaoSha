# TudouMiaoSha — 秒杀商城

用「秒杀」这个场景，把后端架构的每一个决策**用压测数据逼出来**，而不是抄一套企业级配置。

目标岗位：国内后端开发（Java + Spring Boot 3）。所有优化都必须先有瓶颈证据，再有改造。

## 进度

| 阶段 | 内容 | 状态 | 记录 |
|---|---|---|---|
| V0.1 | 丢失更新：并发写同一值的真相 | ✅ 完成 | [RESULTS](v0/01-concurrency/RESULTS.md) |
| V0.2 | MySQL 行锁：亲眼看见 `UPDATE` 卡住 | ✅ 完成 | [RESULTS](v0/02-rowlock/RESULTS.md) |
| V0.3 | 索引：10 万行上 `type=ALL` vs `ref` | ⬜ 待做 | — |
| V0.4 | 热点行 TPS 基线：后面容量估算的锚点 | ⬜ 待做 | — |
| V1-a | 单体 + 直接查库，无锁下单 → 看超卖 | ⬜ 待做 | — |
| V1-b | 条件更新修超卖 → 看吞吐代价 | ⬜ 待做 | — |
| V2 | Redis 预扣 + MQ 削峰 | ⬜ 待做 | — |
| V3 | 多实例 + 限流 + 可观测 + 故障演练 | ⬜ 待做 | — |

## 目录

```
v0/            地基实验（不写业务代码，只建立直觉）
  01-concurrency/
app/           Spring Boot 应用（V1 起）
db/            schema + seed
loadtest/k6/   压测脚本
docs/          笔记与文档
  mysql-notes.md   MySQL 完整笔记（索引/事务/锁/日志）
  BENCHMARK.md     压测记录（V1 起）
  architecture.md  架构图与决策（V1 起）
```

## 复现

```bash
# 需要 JDK 17、Docker Desktop（4 CPU / 8GB）
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

## 环境

| 项 | 值 |
|---|---|
| 机器 | Apple M2 / 8 核 / 16 GB / macOS |
| JDK | Temurin 17.0.18 |
| 容器 | Docker Desktop 29.7.2（Server 同版本，linux/arm64） |
| VM 配额 | **4 核 / 8,320,299,008 B（≈7.75 GiB）** ← 2026-11-02 实测 |
| 压测 | k6（V1 起） |

> 这个配额表是全项目的**测量基准**。V1/V2/V3 的每个数字都必须在同一配额下产生，
> 中途改配额 = 前面的数字全部作废。每次压测前跑一遍
> `docker info --format '{{.NCPU}} 核 / {{.MemTotal}} B / {{.Architecture}}'` 核对。
>
> 另：所有镜像必须是 `linux/arm64` 原生。混入 amd64 镜像会走 QEMU 模拟，
> 测出来的就不是应用性能而是模拟器性能。

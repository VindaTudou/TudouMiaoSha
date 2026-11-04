# TudouMiaoSha — 秒杀商城

用「秒杀」这个场景，把后端架构的每一个决策**用压测数据逼出来**，而不是抄一套企业级配置。

目标岗位：国内后端开发（Java + Spring Boot 3）。所有优化都必须先有瓶颈证据，再有改造。

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
| V2 | Redis 预扣 + MQ 削峰 | ⬜ 待做 | — |
| V3 | 多实例 + 限流 + 可观测 + 故障演练 | ⬜ 待做 | — |

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


## 在 IDE（IntelliJ IDEA）里打开

**先说明一件事**：这台机器的全局 Maven 仓库在 `~/ComputerScience/maven/repository`，
里面**没有** 3.3.5（只有 3.4.5）。所以直接用 IDE 打开，所有 Spring 注解都会标红
（`@Repository` `@Service` `@RestController` 全都找不到），但**代码本身是对的**，
命令行 `make app-build` 能编译通过。

原因是本项目把依赖装在**项目内**的 `.m2repo`，避免写沙箱外的目录。

### 配置步骤

1. `File → Open` 选择 **`app/pom.xml`**（不是仓库根目录），按 "Open as Project"
2. Settings → Build, Execution, Deployment → Build Tools → Maven
   - **Local repository**：勾选 Override，填
     `/Users/fangtudou/ComputerScience/Projects/TudouMiaoSha/.m2repo`
   - 或者保持默认——`app/.mvn/maven.config` 里已经写了
     `-Dmaven.repo.local=../.m2repo`，IDEA 导入时会读到
3. Maven 面板点 **Reload All Maven Projects**

### 如果还标红

- 检查 JDK：Project Structure → SDK 必须是 **17**
- `mvn` 面板 → Execute Maven Goal → `clean compile`，看真实报错
- 命令行验证：`make app-build`。**命令行能过，就是 IDE 配置问题，不是代码问题**

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

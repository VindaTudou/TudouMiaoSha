# 文档索引

这个目录放"知识与结论"，实验的原始数据在 `v0/` 下面。

## 三层结构

```
理论  docs/mysql-notes.md         MySQL 的机制怎么运作
  ↓
证据  v0/*/RESULTS.md             实测数据，可复现
  ↓
结论  docs/locking-rules.md       能直接拿去做设计/面试的规则
```

**为什么要分三层**：理论容易背完就忘，结论容易没有依据。
中间的"证据"才是这个项目和网上教程的差别——**每个结论背后都有一组能重跑出来的数字**。

## 现有文档

| 文档 | 内容 | 什么时候看 |
|---|---|---|
| [mysql-notes.md](mysql-notes.md) | B+ 树、索引、回表、MRR、MVCC、S/X 锁、日志、连接池 | 学机制、补底子 |
| [locking-rules.md](locking-rules.md) | 十条锁规则、锁范围速查、RR/RC 选择、排查 SQL、面试十问 | 设计阶段、面试前 |
| （V1 起）BENCHMARK.md | 每个版本的压测数字 | 复盘、被问"数字怎么来的" |
| （V1 起）architecture.md | 架构图与决策理由 | 讲项目时 |

## 实验记录

| 记录 | 内容 |
|---|---|
| [v0/01-concurrency/RESULTS.md](../v0/01-concurrency/RESULTS.md) | 丢失更新、volatile、竞争窗口 |
| [v0/02-rowlock/RESULTS.md](../v0/02-rowlock/RESULTS.md) | 行锁、S/X 锁、间隙锁、RR vs RC |

## 写作约定

1. **数字必须带配置**：线程数、数据量、隔离级别、commit。缺一个就不可复现。
2. **结论只写"稳定的部分"**：比如"是否为 0"稳定，"丢失率多少"不稳定。
3. **失败也要记**：写错过的结论、被推翻的假设，保留更正记录。

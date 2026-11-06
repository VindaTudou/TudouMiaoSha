#!/usr/bin/env python3
"""汇总实验 A 的所有轮次，输出「每档中位数」表。

为什么要单独一步：
  同一档跑多次，P99 会抖（M1 已经证明这套环境噪声很大）。
  直接拿单次结果画曲线，会把噪声当成拐点。
  所以每档取中位数，同时保留 min/max，让读者看得到波动范围。

口径统一：
  线程数第一轮采的是"峰值"，重复轮改成了 p90（峰值容易被单次尖刺带偏）。
  为了同一张表可比，这里把第一轮的原始采样重新算成 p90。
  原始采样在 /tmp/busy-<rate>.txt，每行一个样本。

用法：python3 ops/analyze-sweep.py
"""

import statistics as st
from pathlib import Path

FILES = ["/tmp/sweep.tsv", "/tmp/sweep-repeat.tsv"]
OUT = Path("/tmp/sweep-summary.tsv")

# 列：目标 实际 成功/s p50 p95 p99 丢弃 线程峰 5xx 429 丢弃% 可信
FIELDS = ["rate", "qps", "succ", "p50", "p95", "p99", "drop", "busy",
          "other", "rl", "drop_pct", "verdict"]


def busy_stats(rate):
    """从原始采样算 (中位数, 峰值)。

    为什么用中位数而不是 p90：一轮只采到 ~20 个点，p90 实际就是"第二大值"，
    一次瞬时扩容就会把它带偏（2,000/s 那轮中位 12，p90 却是 64）。
    """
    p = Path(f"/tmp/busy-{int(rate)}.txt")   # rate 是 float，文件名里是整数
    if not p.exists():
        return None, None
    vals = sorted(int(x) for x in p.read_text().split() if x.strip())
    if not vals:
        return None, None
    return st.median(vals), max(vals)


def main():
    runs = []
    for f in FILES:
        p = Path(f)
        if not p.exists():
            continue
        for line in p.read_text().strip().splitlines():
            fs = line.split("\t")
            if len(fs) < len(FIELDS):
                continue
            r = dict(zip(FIELDS, fs))
            for k in FIELDS[:-1]:
                r[k] = float(r[k])
            r["source"] = p.name
            runs.append(r)

    if not runs:
        print("没有数据")
        return

    by_rate = {}
    for r in runs:
        by_rate.setdefault(r["rate"], []).append(r)

    print(f"共 {len(runs)} 轮，{len(by_rate)} 个档位\n")
    hdr = f"{'目标':>6} {'轮次':>4} {'实际QPS':>8} {'P50':>5} {'P95':>5} {'P99中位':>8} {'P99范围':>12} {'线程中位':>8} {'线程峰':>7} {'丢弃%':>6} {'判定':>5}"
    print(hdr)
    print("-" * len(hdr))

    out_rows = []
    for rate in sorted(by_rate):
        rs = by_rate[rate]
        # 线程数：优先用原始采样重算（保证口径一致），否则用表里的值
        busy, busy_max = busy_stats(rate)
        if busy is None:
            busy = st.median([r["busy"] for r in rs])
            busy_max = max(r["busy"] for r in rs)
        p99s = [r["p99"] for r in rs]
        med = st.median
        row = {
            "rate": rate,
            "runs": len(rs),
            "qps": med([r["qps"] for r in rs]),
            "p50": med([r["p50"] for r in rs]),
            "p95": med([r["p95"] for r in rs]),
            "p99": med(p99s),
            "p99_min": min(p99s),
            "p99_max": max(p99s),
            "busy": busy,
            "busy_max": busy_max,
            "drop_pct": max(r["drop_pct"] for r in rs),
            "other": max(r["other"] for r in rs),
        }
        # 判定：有任意一轮丢弃 > 5% → 不可信；否则看中位
        if row["drop_pct"] > 5:
            row["verdict"] = "NO"
        elif len(rs) == 1 and row["drop_pct"] > 1:
            row["verdict"] = "~"
        else:
            row["verdict"] = "YES"
        out_rows.append(row)
        print(f"{rate:>6.0f} {len(rs):>4} {row['qps']:>8.0f} {row['p50']:>5.0f} {row['p95']:>5.0f} "
              f"{row['p99']:>8.0f} {row['p99_min']:>5.0f}~{row['p99_max']:<6.0f} "
              f"{row['busy']:>8.0f} {row['busy_max']:>7.0f} {row['drop_pct']:>6.1f} {row['verdict']:>5}")

    with OUT.open("w") as f:
        f.write("rate\truns\tqps\tp50\tp95\tp99\tp99_min\tp99_max\tbusy\tbusy_max\tdrop_pct\tverdict\n")
        for r in out_rows:
            f.write("\t".join(str(r[k]) for k in
                              ["rate", "runs", "qps", "p50", "p95", "p99",
                               "p99_min", "p99_max", "busy", "busy_max",
                               "drop_pct", "verdict"]) + "\n")
    print(f"\n汇总写入 {OUT}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""实验 A 的可视化：拐点图 + 逐轮明细。

数据来源：
  /tmp/sweep-summary.tsv  —— 每档汇总（中位数 + 范围），由 ops/analyze-sweep.py 生成
  /tmp/sweep.tsv          —— 第一轮阶梯扫描的逐档原始结果
  /tmp/sweep-repeat.tsv   —— 关键档位的重复轮

为什么图上要画 min/max 范围：
  同一档跑 3~4 次，P99 能差 10 倍（13ms vs 132ms）。
  只画中位数会把波动藏起来，让拐点看起来很确定——那是假的。

用法：python3 ops/render-sweep.py [输出 html]
"""

import importlib.util
from pathlib import Path


def _load_charts():
    """复用 render-report.py 里的绘图函数（文件名带连字符，只能按路径加载）。"""
    path = Path(__file__).parent / "render-report.py"
    spec = importlib.util.spec_from_file_location("render_report", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


rr = _load_charts()
OUT = Path(__import__("sys").argv[1] if len(__import__("sys").argv) > 1 else "docs/v3/m2-experiment-a.html")

SUM = Path("/tmp/sweep-summary.tsv")
RAW = [Path("/tmp/sweep.tsv"), Path("/tmp/sweep-repeat.tsv")]


def load_summary():
    rows = []
    if not SUM.exists():
        return rows
    lines = SUM.read_text().strip().splitlines()[1:]
    for line in lines:
        f = line.split("\t")
        if len(f) < 11:
            continue
        rows.append({
            "rate": float(f[0]), "runs": int(float(f[1])), "qps": float(f[2]),
            "p50": float(f[3]), "p95": float(f[4]), "p99": float(f[5]),
            "p99_min": float(f[6]), "p99_max": float(f[7]),
            "busy": float(f[8]), "busy_max": float(f[9]),
            "drop_pct": float(f[10]), "verdict": f[11].strip(),
        })
    return rows


def load_raw():
    runs = []
    for p in RAW:
        if not p.exists():
            continue
        for line in p.read_text().strip().splitlines():
            f = line.split("\t")
            if len(f) < 11:
                continue
            runs.append({
                "rate": float(f[0]), "qps": float(f[1]), "succ": float(f[2]),
                "p50": float(f[3]), "p95": float(f[4]), "p99": float(f[5]),
                "drop": float(f[6]), "busy": float(f[7]), "other": float(f[8]),
                "rl": float(f[9]), "drop_pct": float(f[10]),
                "source": "首轮" if p.name == "sweep.tsv" else "重复",
            })
    return sorted(runs, key=lambda r: (r["rate"], r["source"]))


def main():
    S = load_summary()
    R = load_raw()
    if not S:
        print("没有汇总数据，先跑 ops/analyze-sweep.py")
        return
    print(f"汇总 {len(S)} 档，明细 {len(R)} 轮")

    x = lambda v: f"{v:.0f}"
    charts = []

    # 图 A1：P99 中位数 + 范围
    charts.append(rr.xy_chart(
        [{"label": "P99 中位", "points": [(r["rate"], r["p99"]) for r in S], "color": 1},
         {"label": "P99 最好", "points": [(r["rate"], r["p99_min"]) for r in S], "color": 2},
         {"label": "P99 最差", "points": [(r["rate"], r["p99_max"]) for r in S], "color": 3}],
        "图 A1 · P99 随到达率变化（中位 + 最好/最差）",
        "三条线的间距就是这套环境的噪声。范围越宽，越说明这一档「站在边缘上」",
        "目标到达率（/s）", "P99（ms）",
        fmt_x=x, fmt_y=lambda v: f"{v:.0f}",
        hlines=[(50, "50ms"), (200, "200ms")],
        note="1,000~3,000 三条线几乎重合（噪声很小）；3,500 以上范围拉开，说明已经贴着能力边界。"))

    # 图 A2：P50 / P95
    charts.append(rr.xy_chart(
        [{"label": "P50", "points": [(r["rate"], r["p50"]) for r in S], "color": 0},
         {"label": "P95", "points": [(r["rate"], r["p95"]) for r in S], "color": 3}],
        "图 A2 · P50 / P95",
        "P50 一直贴在 4~5ms 说明绝大多数请求一直很快；抬头的是尾部，不是整体",
        "目标到达率（/s）", "延迟（ms）", fmt_x=x, fmt_y=lambda v: f"{v:.0f}"))

    # 图 A3：线程
    charts.append(rr.xy_chart(
        [{"label": "忙碌线程（中位）", "points": [(r["rate"], r["busy"]) for r in S], "color": 4},
         {"label": "忙碌线程（峰值）", "points": [(r["rate"], r["busy_max"]) for r in S], "color": 5}],
        "图 A3 · Tomcat 忙碌线程",
        "峰值顶到 200 的那一档，就是真的排满了；中位数一直很低说明大部分时间线程不紧张",
        "目标到达率（/s）", "线程数", fmt_x=x, fmt_y=lambda v: f"{v:.0f}",
        hlines=[(200, "上限 200")], ymax=220))

    # 图 A4：丢弃
    charts.append(rr.grouped_bar(
        [f"{r['rate']:.0f}" for r in S],
        [{"label": "k6 丢弃占比（%）", "values": [r["drop_pct"] for r in S], "color": 1}],
        "图 A4 · 压测机供不上的比例",
        "超过 5% 的档位，测出来的可能是压测机的上限，不是系统的上限",
        "丢弃占比（%）", lambda v: f"{v:.0f}"))

    # 逐轮明细
    trs = []
    for r in R:
        cls = " class='hi'" if r["p99"] > 100 else ""
        trs.append(
            f"<tr><td>{r['rate']:.0f}</td><td>{r['source']}</td><td>{r['qps']:.0f}</td>"
            f"<td>{r['p50']:.0f}</td><td>{r['p95']:.0f}</td>"
            f"<td{cls}>{r['p99']:.0f}</td><td>{r['busy']:.0f}</td>"
            f"<td>{r['drop']:.0f}</td><td>{r['drop_pct']:.1f}%</td><td>{r['other']:.0f}</td></tr>")

    # 汇总表
    srs = []
    for r in S:
        mark = {"YES": "✅", "~": "⚠️", "NO": "❌"}.get(r["verdict"], "?")
        srs.append(
            f"<tr><td>{r['rate']:.0f}</td><td>{r['runs']}</td><td>{r['qps']:.0f}</td>"
            f"<td>{r['p50']:.0f}</td><td>{r['p95']:.0f}</td><td class='hi'>{r['p99']:.0f}</td>"
            f"<td>{r['p99_min']:.0f} ~ {r['p99_max']:.0f}</td>"
            f"<td>{r['busy']:.0f} / {r['busy_max']:.0f}</td><td>{r['drop_pct']:.1f}%</td>"
            f"<td>{mark}</td></tr>")

    table = (
        "<section class='card'><h3>汇总（每档取中位数）</h3><table>"
        "<thead><tr><th>目标 QPS</th><th>轮次</th><th>实际 QPS</th><th>P50</th><th>P95</th>"
        "<th>P99 中位</th><th>P99 范围</th><th>线程 中位/峰</th><th>丢弃%</th><th>可信</th></tr></thead>"
        f"<tbody>{''.join(srs)}</tbody></table></section>"
        "<section class='card'><h3>逐轮明细（每一轮都是一次独立压测）</h3><table>"
        "<thead><tr><th>目标 QPS</th><th>来源</th><th>实际 QPS</th><th>P50</th><th>P95</th>"
        "<th>P99</th><th>线程峰</th><th>丢弃数</th><th>丢弃%</th><th>5xx</th></tr></thead>"
        f"<tbody>{''.join(trs)}</tbody></table></section>")

    html = f"""<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>V3-M2 实验 A · 容量拐点</title>
<style>
  body {{ margin:0; background:#f6f7f9; color:#111827; font-family:{rr.FONT}; }}
  header {{ background:#111827; color:#fff; padding:28px 32px; }}
  header h1 {{ margin:0 0 6px; font-size:20px; }}
  header p {{ margin:0; color:#9ca3af; font-size:13px; line-height:1.6; }}
  main {{ max-width:900px; margin:0 auto; padding:24px 16px 64px; }}
  .card {{ background:#fff; border:1px solid #e5e7eb; border-radius:10px;
           padding:8px; margin:16px 0; overflow:hidden; }}
  .card h3 {{ margin:10px 12px 4px; font-size:14px; }}
  .note {{ margin:4px 12px 12px; font-size:12px; color:#6b7280; line-height:1.6; }}
  table {{ width:100%; border-collapse:collapse; font-size:12px; }}
  th, td {{ padding:6px 8px; text-align:right; border-bottom:1px solid #f1f2f4; }}
  th:first-child, td:first-child {{ text-align:left; }}
  th {{ color:#6b7280; font-weight:600; background:#fafbfc; }}
  td.hi {{ font-weight:700; color:#b91c1c; }}
  footer {{ text-align:center; color:#9ca3af; font-size:12px; padding:24px; }}
</style></head>
<body>
<header><h1>M2 · 实验 A：容量拐点</h1>
<p>1,000 → 5,000 步长 500，每档 20 秒；3,500 / 4,000 / 4,500 各重复 3~4 轮<br>
每档前热身、清空积压、重置库存</p></header>
<main>
{''.join(charts)}
{table}
</main>
<footer>秒杀商城架构演进 · V3-M2 · ops/render-sweep.py</footer>
</body></html>"""

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(html, encoding="utf-8")
    print(f"✅ 写出 {OUT}（{len(charts)} 张图 + 2 张表）")


if __name__ == "__main__":
    main()

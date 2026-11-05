#!/usr/bin/env python3
"""把 V3-M1 的数据画成一张自包含的 HTML 报告。

为什么不用 Grafana 截图：
  1. 这里的图有些是"跨实验"的对比（预热曲线、监控开销、对账），Grafana 存不了；
  2. 自包含 HTML 可以跟着仓库走，谁 clone 都能打开看；
  3. 内联 SVG 不依赖网络和 CDN。

数据来源：
  - 时间序列类：直接查 Prometheus（证明这些图是监控真的能画出来的）
  - 对比类：/tmp/warmup.tsv + 本文里写死的 M1 实验记录

用法：python3 ops/render-report.py [输出路径]
"""

import json
import math
import time
import urllib.parse
import urllib.request
from pathlib import Path

PROM = "http://127.0.0.1:9090"
OUT = Path(__import__("sys").argv[1] if len(__import__("sys").argv) > 1 else "docs/v3/m1-report.html")

# ---------- M1 实验记录（写死，都有 commit 可追溯） ----------
RECONCILE = [            # (轮次标签, k6 报的请求数, Prometheus 计数差值)
    ("第 1 轮\n(容器内)", 53763, 53763),
    ("第 2 轮\n(宿主机)", 86983, 86983),
    ("第 3 轮\n(重启 JVM)", 87947, 87947),
]
OVERHEAD = [             # 监控抓取开销对照（P99 ms，均已排空积压）
    ("抓取关", 17),
    ("抓取开 第1次", 18),
    ("抓取开 第2次", 13),
]
PARTITIONS = [("partition 0", 1832506), ("partition 1", 0), ("partition 2", 0)]
# 预热实验期间 JVM 启动后的每分钟 GC 暂停（来自 logs/gc.log）
GC_MINUTES = [(0, 346), (1, 82), (2, 53), (3, 15), (4, 14),
              (5, 63), (6, 6), (7, 6), (8, 8), (9, 78)]


# ---------- 取数 ----------
def qrange(expr, minutes, step=15):
    end = int(time.time())
    start = end - minutes * 60
    url = PROM + "/api/v1/query_range?" + urllib.parse.urlencode(
        {"query": expr, "start": start, "end": end, "step": step})
    try:
        r = json.load(urllib.request.urlopen(url, timeout=10))["data"]["result"]
    except Exception as e:
        print(f"  ⚠️ 查询失败 {expr}: {e}")
        return []
    if not r:
        return []
    pts = []
    for t, v in r[0]["values"]:
        f = float(v)
        pts.append((int(float(t)), None if math.isnan(f) or math.isinf(f) else f))
    return pts


def read_warmup(path="/tmp/warmup.tsv"):
    """预热曲线：轮次, 累计订单, p50, p95, p99, qps, 丢弃"""
    rows = []
    p = Path(path)
    if not p.exists():
        return rows
    for line in p.read_text().strip().splitlines():
        f = line.split("\t")
        if len(f) >= 6:
            rows.append({"round": int(f[0]), "cum": int(f[1]), "p50": int(f[2]),
                         "p95": int(f[3]), "p99": int(f[4]), "qps": int(f[5])})
    return rows


# ---------- SVG 基础 ----------
PALETTE = ["#2563eb", "#dc2626", "#16a34a", "#d97706", "#7c3aed", "#0891b2"]
FONT = "system-ui, -apple-system, 'PingFang SC', 'Microsoft YaHei', sans-serif"


def esc(s):
    return (str(s).replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;"))


def nice_ticks(lo, hi, n=5):
    if hi <= lo:
        hi = lo + 1
    raw = (hi - lo) / n
    mag = 10 ** math.floor(math.log10(raw)) if raw > 0 else 1
    for m in (1, 2, 2.5, 5, 10):
        if raw <= m * mag:
            step = m * mag
            break
    else:
        step = 10 * mag
    start = math.floor(lo / step) * step
    ticks = []
    v = start
    while v <= hi + step * 0.5:
        if v >= lo - step * 0.5:
            ticks.append(v)
        v += step
    return ticks


def xy_chart(series, title, subtitle, xlabel, ylabel, fmt_x, fmt_y,
             width=780, height=320, ymin=None, ymax=None,
             hlines=(), area=False, note=""):
    """series: [{'label': str, 'points': [(x,y|None)], 'color': idx}]"""
    ml, mr, mt, mb = 62, 18, 54, 46
    pw, ph = width - ml - mr, height - mt - mb

    xs = [x for s in series for x, _ in s["points"]]
    ys = [y for s in series for _, y in s["points"] if y is not None]
    if not xs or not ys:
        return card(title, "<p style='padding:24px;color:#888'>无数据</p>", note)
    x0, x1 = min(xs), max(xs)
    y0 = 0 if ymin is None else ymin
    y1 = (max(ys) * 1.15) if ymax is None else ymax
    if y1 <= y0:
        y1 = y0 + 1

    def px(x):
        return ml + (x - x0) / (x1 - x0 or 1) * pw

    def py(y):
        return mt + ph - (y - y0) / (y1 - y0) * ph

    g = [f'<rect x="0" y="0" width="{width}" height="{height}" fill="#fff"/>']
    # 网格 + y 轴
    for tv in nice_ticks(y0, y1, 5):
        y = py(tv)
        g.append(f'<line x1="{ml}" y1="{y:.1f}" x2="{ml+pw}" y2="{y:.1f}" stroke="#eef0f3"/>')
        g.append(f'<text x="{ml-8}" y="{y+4:.1f}" text-anchor="end" font-size="11" fill="#6b7280">{esc(fmt_y(tv))}</text>')
    # x 轴
    for i in range(6):
        tv = x0 + (x1 - x0) * i / 5
        x = px(tv)
        g.append(f'<line x1="{x:.1f}" y1="{mt}" x2="{x:.1f}" y2="{mt+ph}" stroke="#f3f4f6"/>')
        g.append(f'<text x="{x:.1f}" y="{mt+ph+18}" text-anchor="middle" font-size="11" fill="#6b7280">{esc(fmt_x(tv))}</text>')
    g.append(f'<line x1="{ml}" y1="{mt+ph}" x2="{ml+pw}" y2="{mt+ph}" stroke="#9ca3af"/>')
    g.append(f'<line x1="{ml}" y1="{mt}" x2="{ml}" y2="{mt+ph}" stroke="#9ca3af"/>')

    # 参考线
    for hy, hlabel in hlines:
        if y0 <= hy <= y1:
            y = py(hy)
            g.append(f'<line x1="{ml}" y1="{y:.1f}" x2="{ml+pw}" y2="{y:.1f}" stroke="#9ca3af" stroke-dasharray="4 3"/>')
            g.append(f'<text x="{ml+pw-4}" y="{y-4:.1f}" text-anchor="end" font-size="10" fill="#6b7280">{esc(hlabel)}</text>')

    # 曲线（None 处断开）
    for s in series:
        color = PALETTE[s.get("color", 0) % len(PALETTE)]
        seg, segs = [], []
        for x, y in s["points"]:
            if y is None:
                if len(seg) > 1:
                    segs.append(seg)
                seg = []
            else:
                seg.append((px(x), py(y)))
        if len(seg) > 1:
            segs.append(seg)

        if area and segs:
            allpts = [p for sg in segs for p in sg]
            if len(allpts) > 1:
                d = f"M {allpts[0][0]:.1f} {mt+ph} " + " ".join(f"L {x:.1f} {y:.1f}" for x, y in allpts) \
                    + f" L {allpts[-1][0]:.1f} {mt+ph} Z"
                g.append(f'<path d="{d}" fill="{color}" opacity="0.12"/>')

        for sg in segs:
            pts = " ".join(f"{x:.1f},{y:.1f}" for x, y in sg)
            g.append(f'<polyline points="{pts}" fill="none" stroke="{color}" stroke-width="2" '
                     f'stroke-linejoin="round" stroke-linecap="round"/>')
        for x, y in [p for sg in segs for p in sg][::max(1, len(segs[0]) // 40 if segs else 1)]:
            g.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="2" fill="{color}"/>')

    # 图例
    lx = ml
    for i, s in enumerate(series):
        color = PALETTE[s.get("color", 0) % len(PALETTE)]
        g.append(f'<rect x="{lx}" y="{mt-26}" width="10" height="10" rx="2" fill="{color}"/>')
        g.append(f'<text x="{lx+15}" y="{mt-17}" font-size="12" fill="#374151">{esc(s["label"])}</text>')
        lx += 18 + len(s["label"]) * 12

    g.append(f'<text x="{ml}" y="20" font-size="13" font-weight="600" fill="#111827">{esc(title)}</text>')
    g.append(f'<text x="{ml}" y="37" font-size="11" fill="#6b7280">{esc(subtitle)}</text>')
    g.append(f'<text x="{ml+pw/2}" y="{height-8}" text-anchor="middle" font-size="11" fill="#6b7280">{esc(xlabel)}</text>')
    g.append(f'<text x="14" y="{mt+ph/2}" text-anchor="middle" font-size="11" fill="#6b7280" '
             f'transform="rotate(-90 14 {mt+ph/2})">{esc(ylabel)}</text>')
    return card(title, f'<svg viewBox="0 0 {width} {height}" width="100%" role="img">{ "".join(g) }</svg>', note)


def grouped_bar(cats, groups, title, subtitle, ylabel, fmt_y, note="", width=780, height=300):
    """cats: [str]; groups: [{'label','values':[num|None],'color'}]"""
    ml, mr, mt, mb = 62, 18, 56, 46
    pw, ph = width - ml - mr, height - mt - mb
    vals = [v for g in groups for v in g["values"] if v is not None]
    y1 = max(vals) * 1.2 if vals else 1
    n = len(cats)
    bw = pw / n * 0.62 / max(1, len(groups))
    g = [f'<rect x="0" y="0" width="{width}" height="{height}" fill="#fff"/>']
    for tv in nice_ticks(0, y1, 5):
        y = mt + ph - tv / (y1 or 1) * ph
        g.append(f'<line x1="{ml}" y1="{y:.1f}" x2="{ml+pw}" y2="{y:.1f}" stroke="#eef0f3"/>')
        g.append(f'<text x="{ml-8}" y="{y+4:.1f}" text-anchor="end" font-size="11" fill="#6b7280">{esc(fmt_y(tv))}</text>')
    for ci, cat in enumerate(cats):
        cx = ml + pw / n * (ci + 0.5)
        for gi, grp in enumerate(groups):
            v = grp["values"][ci]
            if v is None:
                continue
            h = v / (y1 or 1) * ph
            x = cx - bw * len(groups) / 2 + gi * bw
            g.append(f'<rect x="{x:.1f}" y="{mt+ph-h:.1f}" width="{bw-3:.1f}" height="{h:.1f}" '
                     f'fill="{PALETTE[grp.get("color", gi) % len(PALETTE)]}" rx="2"/>')
            g.append(f'<text x="{x+(bw-3)/2:.1f}" y="{mt+ph-h-5:.1f}" text-anchor="middle" '
                     f'font-size="10" fill="#374151">{esc(fmt_y(v))}</text>')
        for li, line in enumerate(cat.split("\n")):
            g.append(f'<text x="{cx:.1f}" y="{mt+ph+17+li*13:.1f}" text-anchor="middle" '
                     f'font-size="11" fill="#6b7280">{esc(line)}</text>')
    g.append(f'<line x1="{ml}" y1="{mt+ph}" x2="{ml+pw}" y2="{mt+ph}" stroke="#9ca3af"/>')
    lx = ml
    for gi, grp in enumerate(groups):
        g.append(f'<rect x="{lx}" y="{mt-26}" width="10" height="10" rx="2" fill="{PALETTE[grp.get("color", gi) % len(PALETTE)]}"/>')
        g.append(f'<text x="{lx+15}" y="{mt-17}" font-size="12" fill="#374151">{esc(grp["label"])}</text>')
        lx += 18 + len(grp["label"]) * 12
    g.append(f'<text x="{ml}" y="20" font-size="13" font-weight="600" fill="#111827">{esc(title)}</text>')
    g.append(f'<text x="{ml}" y="37" font-size="11" fill="#6b7280">{esc(subtitle)}</text>')
    g.append(f'<text x="14" y="{mt+ph/2}" text-anchor="middle" font-size="11" fill="#6b7280" '
             f'transform="rotate(-90 14 {mt+ph/2})">{esc(ylabel)}</text>')
    return card(title, f'<svg viewBox="0 0 {width} {height}" width="100%" role="img">{ "".join(g) }</svg>', note)


def card(title, body, note=""):
    n = f'<p class="note">{esc(note)}</p>' if note else ""
    return f'<section class="card">{body}{n}</section>'


# ---------- 组装 ----------
def main():
    print("查 Prometheus ...")
    lag = qrange('sum(kafka_consumer_fetch_manager_records_lag)', 60)
    inflow = qrange('sum(rate(miaosha_order_total{result="success"}[1m]))', 60)
    outflow = qrange('sum(rate(miaosha_consumer_persist_total{result="ok"}[1m]))', 60)
    ksnd = qrange('max(miaosha_kafka_send_seconds{quantile="0.99"})', 60)
    red = qrange('max(miaosha_redis_deduct_seconds{quantile="0.99"})', 60)
    warm = read_warmup()
    print(f"  积压 {len(lag)} 点 / 进水 {len(inflow)} 点 / 预热轮次 {len(warm)}")

    hhmm = lambda t: time.strftime("%H:%M", time.localtime(t))
    ms = lambda v: f"{v*1000:.0f}ms" if v < 1 else f"{v:.2f}s"

    charts = []

    # ① 预热曲线（本轮最重要的新图）
    if warm:
        pts_p99 = [(w["cum"], w["p99"]) for w in warm]
        pts_p50 = [(w["cum"], w["p50"]) for w in warm]
        charts.append(xy_chart(
            [{"label": "P99", "points": pts_p99, "color": 1},
             {"label": "P50", "points": pts_p50, "color": 0}],
            "图 1 · JVM 预热曲线（同一进程连跑 5 轮）",
            "横轴是「这台 JVM 从启动到现在一共处理了多少单」，不是时间——所以它才叫预热",
            "累计处理订单数", "延迟（ms）",
            fmt_x=lambda v: f"{v/1000:.0f}k" if v >= 1000 else f"{v:.0f}",
            fmt_y=lambda v: f"{v:.0f}",
            hlines=[(16, "V2 稳态 16ms")],
            note="每轮开始前都等 Kafka 积压排空，排除了积压污染。5 轮相同配置、相同到达率 3,000/s。"
                 "前 3 轮（累计 0~11 万单）P99 在 83~313ms，第 4 轮起落到 11~12ms 并稳定——"
                 "也就是说这台 JVM 需要跑 15~17 万单（约 60 秒满负荷）才进入稳态。"))

    # ② 对账
    charts.append(grouped_bar(
        [c[0] for c in RECONCILE],
        [{"label": "k6 报的请求数", "values": [c[1] for c in RECONCILE], "color": 0},
         {"label": "Prometheus 计数差值", "values": [c[2] for c in RECONCILE], "color": 3}],
        "图 2 · 监控数字 vs 已知答案",
        "三次对账误差全部 0.00%——先证明监控自己是对的，再信它",
        "请求数", lambda v: f"{v/1000:.0f}k"))

    # ③ 监控开销
    charts.append(grouped_bar(
        [c[0] for c in OVERHEAD],
        [{"label": "P99", "values": [c[1] for c in OVERHEAD], "color": 2}],
        "图 3 · 监控自己的开销",
        "抓取关 vs 抓取开（全部排空后测）。差异落在噪声里，说明监控没有拖慢系统",
        "P99（ms）", lambda v: f"{v:.0f}"))

    # ④ 进水 vs 出水（水库）
    if inflow and outflow:
        charts.append(xy_chart(
            [{"label": "进水：下单成功", "points": inflow, "color": 0},
             {"label": "出水：落库成功", "points": outflow, "color": 2}],
            "图 4 · 进水 vs 出水（V2 那个「水库」的实时形状）",
            "两条线之间的面积就是积压。V2 只有压测脚本采的离散点，现在是一条连续曲线",
            "", "速率（/s）", fmt_x=hhmm, fmt_y=lambda v: f"{v:.0f}"))

    # ⑤ 积压水位
    if lag:
        charts.append(xy_chart(
            [{"label": "Kafka 积压（条）", "points": lag, "color": 4}],
            "图 5 · 积压水位随时间变化",
            "唯一能回答「活动还要多久排空」的指标；告警规则就挂在这条线上（>1 万条持续 2 分钟）",
            "", "待落库订单数", fmt_x=hhmm, fmt_y=lambda v: f"{v/1000:.0f}k" if v >= 1000 else f"{v:.0f}",
            area=True))

    # ⑥ 耗时分解
    if ksnd and red:
        charts.append(xy_chart(
            [{"label": "Kafka 发送 P99", "points": ksnd, "color": 3},
             {"label": "Redis 扣减 P99", "points": red, "color": 5}],
            "图 6 · 把 V2 的「37ms 花在哪」拆开",
            "V2 只知道端到端，现在两个大头各自可见。积压高的时段两条线一起抬头（互相印证）",
            "", "P99 延迟", fmt_x=hhmm, fmt_y=ms))

    # ⑦' GC 暂停分布
    charts.append(grouped_bar(
        [f"第 {m} 分" for m, _ in GC_MINUTES],
        [{"label": "该分钟内 GC 累计暂停（ms）", "values": [v for _, v in GC_MINUTES], "color": 5}],
        "图 8 · 预热期 GC 明显更频繁",
        "JVM 启动后第 0 分钟就发生 56 次 GC、累计 346ms，占全程 GC 时间的一半；之后每分钟只有 5~25 次",
        "GC 暂停（ms）", lambda v: f"{v:.0f}",
        note="单次最长 62.8ms、平均 4.2ms。它能解释一部分尾延迟，但解释不了 313ms——"
             "所以预热的主因更可能是 JIT 分层编译 + 连接池/线程池惰性建立。"))

    # ⑦ 分区分布
    charts.append(grouped_bar(
        [c[0] for c in PARTITIONS],
        [{"label": "分区偏移量（累计消息数）", "values": [c[1] for c in PARTITIONS], "color": 1}],
        "图 7 · 3 个分区只有 1 个有数据",
        "key = productId → 单商品永远哈希到同一分区 → 3 个消费者只有 1 个在干活",
        "消息数", lambda v: f"{v/1000000:.2f}M" if v >= 10000 else f"{v:.0f}",
        note="这一条解释了 V2「落库 950/s」的另一半原因，也决定 V4 分桶时必须同时改分区 key。"))

    body = "\n".join(charts)
    html = f"""<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>V3-M1 · 可观测性</title>
<style>
  :root {{ color-scheme: light; }}
  body {{ margin:0; background:#f6f7f9; color:#111827; font-family:{FONT}; }}
  header {{ background:#111827; color:#fff; padding:28px 32px; }}
  header h1 {{ margin:0 0 6px; font-size:20px; }}
  header p {{ margin:0; color:#9ca3af; font-size:13px; }}
  main {{ max-width:860px; margin:0 auto; padding:24px 16px 64px; }}
  .card {{ background:#fff; border:1px solid #e5e7eb; border-radius:10px;
           padding:8px 8px 4px; margin:16px 0; overflow:hidden; }}
  .note {{ margin:4px 12px 12px; font-size:12px; color:#6b7280; line-height:1.6; }}
  footer {{ text-align:center; color:#9ca3af; font-size:12px; padding:24px; }}
</style></head>
<body>
<header>
  <h1>V3 · M1 可观测性 —— 数据总览</h1>
  <p>生成时间 {time.strftime('%Y-%m-%d %H:%M')} · 数据来自 Prometheus + k6（3,000/s）</p>
</header>
<main>
{body}
</main>
<footer>秒杀商城架构演进 · V3-M1 · 生成脚本 ops/render-report.py</footer>
</body></html>"""

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(html, encoding="utf-8")
    print(f"✅ 写出 {OUT}（{len(charts)} 张图，{len(html)//1024} KB）")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""每秒采样应用指标，输出 CSV。

为什么需要它：
  实验 B 要看的是「随时间恶化」的过程，而 k6 只在结束时给一个汇总。
  Prometheus 默认 5 秒抓一次，也画不出 60 秒里的变化。
  所以直接每秒拉一次 /actuator/prometheus，把关键计数抓下来。

用法：python3 ops/sampler.py [输出csv] [秒数] [BASE]

列：
  t              相对秒数
  success/soldout/dup/ratelimited/sendfail   累计计数（用来算每秒增量）
  busy/current    Tomcat 忙碌 / 当前线程
  hikari_active/hikari_pending               连接池
  kafka_p99/redis_p99                        单次耗时 P99（秒）
  lag            Kafka 积压
  cpu            进程 CPU
  heap_mb        堆使用
"""

import re
import sys
import time
import urllib.request

OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/sampler.csv"
SECONDS = int(sys.argv[2]) if len(sys.argv) > 2 else 120
BASE = sys.argv[3] if len(sys.argv) > 3 else "http://127.0.0.1:8080"

LINE = re.compile(r'^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{[^}]*\})?\s+(\S+)$')


def num(v):
    try:
        return float(v)
    except ValueError:
        return 0.0


def fetch():
    with urllib.request.urlopen(BASE + "/actuator/prometheus", timeout=5) as r:
        return r.read().decode("utf-8", "replace")


def pick(text, name, label_filter=None, agg="sum"):
    """取一个指标的汇总值；label_filter 是 (k, v) 元组。"""
    vals = []
    for line in text.splitlines():
        if not line.startswith(name):
            continue
        m = LINE.match(line)
        if not m or m.group(1) != name:
            continue
        labels = m.group(2) or ""
        if label_filter and f'{label_filter[0]}="{label_filter[1]}"' not in labels:
            continue
        v = m.group(3)
        if v in ("NaN", "Inf", "+Inf", "-Inf"):
            continue
        vals.append(num(v))
    if not vals:
        return 0.0
    return sum(vals) if agg == "sum" else max(vals)


cols = ["t", "success", "soldout", "dup", "ratelimited", "sendfail",
        "busy", "current", "hikari_active", "hikari_pending",
        "kafka_p99", "redis_p99", "lag", "cpu", "heap_mb", "gc_cnt", "gc_pause_s"]

t0 = time.time()
with open(OUT, "w") as f:
    f.write(",".join(cols) + "\n")
    f.flush()
    while time.time() - t0 < SECONDS:
        try:
            txt = fetch()
            row = [
                round(time.time() - t0, 1),
                int(pick(txt, "miaosha_order_total", ("result", "success"))),
                int(pick(txt, "miaosha_order_total", ("result", "soldout"))),
                int(pick(txt, "miaosha_order_total", ("result", "duplicate"))),
                int(pick(txt, "miaosha_order_total", ("result", "ratelimited"))),
                int(pick(txt, "miaosha_order_total", ("result", "send_fail"))),
                int(pick(txt, "tomcat_threads_busy_threads", agg="max")),
                int(pick(txt, "tomcat_threads_current_threads", agg="max")),
                int(pick(txt, "hikaricp_connections_active", agg="max")),
                int(pick(txt, "hikaricp_connections_pending", agg="max")),
                round(pick(txt, "miaosha_kafka_send_seconds", None, "max"), 4),  # 各分位数一起，取最大= p99
                round(pick(txt, "miaosha_redis_deduct_seconds", None, "max"), 4),
                int(pick(txt, "kafka_consumer_fetch_manager_records_lag")),
                round(pick(txt, "process_cpu_usage", agg="max"), 4),
                round(pick(txt, "jvm_memory_used_bytes", ("area", "heap")) / 1048576, 1),
                int(pick(txt, "jvm_gc_pause_seconds_count")),
                round(pick(txt, "jvm_gc_pause_seconds_sum"), 2),
            ]
            f.write(",".join(str(x) for x in row) + "\n")
            f.flush()
        except Exception as e:
            f.write(",".join([str(round(time.time() - t0, 1))] + ["-1"] * (len(cols) - 1)) + "\n")
            f.flush()
            print(f"采样失败: {e}", file=sys.stderr)
        time.sleep(1)
print(f"采样完成 → {OUT}")

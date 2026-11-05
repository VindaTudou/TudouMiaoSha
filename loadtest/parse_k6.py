#!/usr/bin/env python3
"""从 k6 summary JSON 里抽指标，输出一行：
   qps  med  p99  other_pct  dropped  success
"""
import json
import sys

d = json.load(open(sys.argv[1]))['metrics']
ok = d.get('order_success', {}).get('count', 0)
so = d.get('order_soldout', {}).get('count', 0)
dup = d.get('order_duplicate', {}).get('count', 0)
ot = d.get('order_other', {}).get('count', 0)
drop = d.get('dropped_iterations', {}).get('count', 0)
qps = d.get('http_reqs', {}).get('rate', 0)
dur = d.get('http_req_duration{scenario:seckill}', {})
total = max(1, ok + so + dup + ot)
print(f"{qps:.0f} {dur.get('med', 0):.0f} {dur.get('p(99)', 0):.0f} "
      f"{ot * 100 / total:.2f} {drop:.0f} {ok}")

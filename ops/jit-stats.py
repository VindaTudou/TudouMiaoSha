#!/usr/bin/env python3
"""解析 JVM 的 -Xlog:jit+compilation 日志，回答一个问题：

    「预热到底持续了多久？」

输出：
  1. 编译事件随时间的分布（每 10 秒一格）
  2. C2(4 层) 编译的最后一次发生在第几秒
  3. 有多少次「made not entrant」—— 编译后的代码被推翻（去优化），说明优化还在反复调整

用法：python3 ops/jit-stats.py [logs/jit.log]
"""

import re
import sys
from collections import Counter

path = sys.argv[1] if len(sys.argv) > 1 else "logs/jit.log"
UP = re.compile(r"^\[(\d+\.\d+)s\]")

events = []      # (uptime_s, tier, is_osr, kind)
not_entrant = 0
for line in open(path, encoding="utf-8", errors="replace"):
    m = UP.match(line)
    if not m:
        continue
    t = float(m.group(1))
    if "made not entrant" in line:
        not_entrant += 1
        continue
    #   [1.234s][info][jit,compilation]  345   234 % 4  Foo::bar @ 12 (45 bytes)
    parts = line.split("]", 3)
    if len(parts) < 4:
        continue
    body = parts[3].strip()
    fields = body.split()
    if len(fields) < 3:
        continue
    is_osr = "%" in fields[1] or "%" in fields[2]
    tier = None
    for f in fields[:4]:
        if f.isdigit() and len(f) <= 2:
            tier = int(f)
    events.append((t, tier, is_osr))

if not events:
    print("没解析到编译事件，检查日志路径和 -Xlog 参数")
    sys.exit(1)

last = max(e[0] for e in events)
c2 = [e for e in events if e[1] == 4]
last_c2 = max((e[0] for e in c2), default=0)

print(f"编译事件总数        : {len(events)}")
print(f"其中 C2（4 层）     : {len(c2)}")
print(f"最后一次编译        : 第 {last:.1f} 秒")
print(f"最后一次 C2 编译    : 第 {last_c2:.1f} 秒")
print(f"made not entrant    : {not_entrant} 次（编译后又被推翻 = 优化还在调整）")
print()

buckets = Counter()
for t, *_ in events:
    buckets[int(t // 10) * 10] += 1

print("按 10 秒分桶（秒 → 编译次数）：")
peak = max(buckets.values())
for b in sorted(buckets)[:24]:
    n = buckets[b]
    bar = "█" * max(1, round(n / peak * 40))
    print(f"  {b:>4}-{b+10:<4}s {n:>5}  {bar}")
if len(buckets) > 24:
    print(f"  ... 之后还有 {sum(v for k, v in buckets.items() if k >= 240)} 次编译")

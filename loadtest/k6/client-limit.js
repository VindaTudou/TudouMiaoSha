// 压测机自身上限测试
//
// 目的：区分 dropped_iterations 的两种来源
//   A. 被测系统慢 → VU 被占住 → k6 凑不出足够的并发 → 丢弃
//   B. 压测机自己（k6 是单进程 JS 运行时）算不过来 → 定时器不准 → 丢弃
//
// 做法：打一个几乎零成本的接口（/actuator/health），它不查库、不碰 Redis、不写 Kafka。
//   如果打这么轻的接口仍然大量丢弃 → 说明瓶颈在压测机（B）
//   如果一点不丢 → 说明之前的丢弃确实来自系统变慢（A）

import http from 'k6/http';
import { Counter } from 'k6/metrics';

const BASE = __ENV.BASE || 'http://127.0.0.1:8080';
const RATE = Number(__ENV.RATE || 8000);
const DURATION = __ENV.SECKILL_DURATION || '20s';
const P = __ENV.PROBE_PATH || '/actuator/info';   // info 不碰 DB/Redis，才是真的轻

const okCount = new Counter('probe_ok');

export const options = {
  scenarios: {
    probe: {
      executor: 'constant-arrival-rate',
      exec: 'probe',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: 200,
      maxVUs: Number(__ENV.MAX_VUS || Math.max(2000, RATE * 2)),
      tags: { scenario: 'probe' },
    },
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(95)', 'p(99)', 'max'],
};

export function probe() {
  const res = http.get(`${BASE}${P}`, { tags: { name: 'probe' } });
  if (res.status === 200) okCount.add(1);
}

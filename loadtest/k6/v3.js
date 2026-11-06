// V3 压测脚本
//
// 和 v2.js 的区别只有一个，但很关键：
//   429 要单独统计，而且【不算错误】。
//
// 为什么：加了限流之后，被拒的请求会变成 429。如果把它算进"错误率"，
// 会得出"限流后错误率 60%，系统崩了"这种完全反过来的结论。
// 429 是系统主动的、预期的、快速的结果——它比"排 2 秒队然后超时"好得多。
//
// 其余沿用 v2.js 的约定：
//   - userId 绝对唯一（VU×1000万 + 迭代号），避免 409 DUPLICATE 污染售罄统计
//   - 200 的含义是"抢到名额，排队中"，不是"已落库"

import http from 'k6/http';
import { Counter } from 'k6/metrics';

const BASE = __ENV.BASE || 'http://127.0.0.1:8080';
const RATE = Number(__ENV.RATE || 1000);
const SECKILL_DURATION = __ENV.SECKILL_DURATION || '15s';

const orderSuccess = new Counter('order_success');       // 200
const orderSoldOut = new Counter('order_soldout');       // 409 SOLD_OUT
const orderDuplicate = new Counter('order_duplicate');   // 409 DUPLICATE
const orderRateLimited = new Counter('order_ratelimited'); // 429 ← V3 新增
const orderOther = new Counter('order_other');           // 5xx / 503 等

export const options = {
  scenarios: {
    seckill: {
      executor: 'constant-arrival-rate',
      exec: 'seckill',
      rate: RATE,
      timeUnit: '1s',
      duration: SECKILL_DURATION,
      preAllocatedVUs: 200,
      // 需要的 VU ≈ 到达率 × 预期 P99(秒)。
      // 给 2 倍余量：延迟涨到 2 秒时，5,000/s 需要 10,000 个 VU。
      maxVUs: Number(__ENV.MAX_VUS || Math.max(2000, RATE * 2)),
      tags: { scenario: 'seckill' },
    },
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

export function seckill() {
  const userId = __VU * 10_000_000 + __ITER + 1;
  const payload = JSON.stringify({ userId, productId: 1, quantity: 1 });

  const res = http.post(`${BASE}/api/orders`, payload, {
    headers: { 'Content-Type': 'application/json' },
    tags: { name: 'order' },
  });

  if (res.status === 200) {
    orderSuccess.add(1);
  } else if (res.status === 409) {
    let code = '';
    try { code = res.json('code'); } catch (e) { /* 忽略 */ }
    if (code === 'DUPLICATE') orderDuplicate.add(1);
    else orderSoldOut.add(1);
  } else if (res.status === 429) {
    // 被限流：这是系统在保护自己，不是故障
    orderRateLimited.add(1);
  } else {
    orderOther.add(1);
  }
}

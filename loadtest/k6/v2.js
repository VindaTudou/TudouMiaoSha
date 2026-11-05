// V2 压测脚本
//
// 和 V1 的区别：
//   1. userId 改成【绝对唯一】：V2 按用户去重，随机 ID 会撞车产生 409 DUPLICATE，
//      污染"售罄"统计（生日悖论：20 万次抽样 100 万空间，必撞）
//   2. 409 要区分 SOLD_OUT 和 DUPLICATE
//   3. 200 的含义变了：不是"订单已落库"，是"抢到名额，正在排队"

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter } from 'k6/metrics';

const BASE = __ENV.BASE || 'http://127.0.0.1:8080';
const RATE = Number(__ENV.RATE || 1000);
const SECKILL_DURATION = __ENV.SECKILL_DURATION || '15s';
const BROWSE_MAX = Number(__ENV.BROWSE_MAX || 100);
const BROWSE_ON = (__ENV.BROWSE_ON || '0') === '1';

const orderSuccess = new Counter('order_success');     // 200 QUEUED
const orderSoldOut = new Counter('order_soldout');    // 409 SOLD_OUT
const orderDuplicate = new Counter('order_duplicate'); // 409 DUPLICATE
const orderOther = new Counter('order_other');        // 5xx / 503 等

const scenarios = {
  seckill: {
    executor: 'constant-arrival-rate',
    exec: 'seckill',
    rate: RATE,
    timeUnit: '1s',
    duration: SECKILL_DURATION,
    preAllocatedVUs: 200,
    // 延迟高时需要大量 VU：需要的 VU ≈ 到达率 × P99(秒)
    maxVUs: 8000,
    startTime: BROWSE_ON ? '5s' : '0s',
    tags: { scenario: 'seckill' },
  },
};

if (BROWSE_ON) {
  scenarios.browse = {
    executor: 'ramping-vus',
    exec: 'browse',
    startVUs: 0,
    stages: [
      { duration: '10s', target: 20 },
      { duration: '10s', target: BROWSE_MAX },
      { duration: '5s', target: 0 },
    ],
    tags: { scenario: 'browse' },
  };
}

export const options = {
  scenarios,
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  thresholds: {
    'http_req_duration{scenario:seckill}': ['p(99)<3000'],
  },
};

export function browse() {
  const res = http.get(`${BASE}/api/products?page=${Math.floor(Math.random() * 100)}&size=20`, {
    tags: { name: 'list' },
  });
  check(res, { 'list 200': (r) => r.status === 200 });
  sleep(1);
}

export function seckill() {
  // __VU 是虚拟用户编号，__ITER 是该 VU 的迭代计数 → 组合起来绝对唯一
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
    if (code === 'DUPLICATE') {
      orderDuplicate.add(1);   // 用户重复：说明去重生效，但不该出现
    } else {
      orderSoldOut.add(1);     // 售罄：正常业务结果
    }
  } else {
    orderOther.add(1);
  }
}

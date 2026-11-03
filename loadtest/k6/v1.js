// V1 压测脚本
//
// 两个场景同时跑，模拟真实情况：有人在逛列表，有人在抢单。
//
// 为什么下单用 constant-arrival-rate 而不是 ramping-vus：
//   ramping-vus 的请求速率会随响应变慢而自动下降（VU 被阻塞在等待上），
//   系统越慢压力反而越小，永远测不到真实上限。
//   constant-arrival-rate 是"不管你快不快，每秒就是来 N 个人"，这才是秒杀。
//
// 用法：
//   k6 run -e RATE=200 -e SECKILL_DURATION=30s loadtest/k6/v1.js
//
// 关键环境变量：
//   BASE              应用地址，默认 http://127.0.0.1:8080
//   RATE              下单到达率（个/秒）
//   SECKILL_DURATION  下单场景持续时长
//   BROWSE_MAX        列表场景最大并发 VU

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter } from 'k6/metrics';

const BASE = __ENV.BASE || 'http://127.0.0.1:8080';
const RATE = Number(__ENV.RATE || 200);
const SECKILL_DURATION = __ENV.SECKILL_DURATION || '30s';
const BROWSE_MAX = Number(__ENV.BROWSE_MAX || 200);
// BROWSE_ON=0 时只跑下单场景，用于纯容量测量
const BROWSE_ON = (__ENV.BROWSE_ON || '1') === '1';
// PRODUCT_ID=random 时把请求分散到不同商品，用来对照「单行热点」的影响
const PRODUCT_MODE = __ENV.PRODUCT_ID || '1';

// 三个计数器，把下单结果分开统计。
// 这是压测数据可信的前提：409 是业务结果，不是错误。
const orderSuccess = new Counter('order_success');
const orderSoldOut = new Counter('order_soldout');
const orderOther = new Counter('order_other');

const scenarios = {
  seckill: {
      executor: 'constant-arrival-rate',
      exec: 'seckill',
      rate: RATE,
      timeUnit: '1s',
      duration: SECKILL_DURATION,
      preAllocatedVUs: 50,
      maxVUs: 3000,
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
      { duration: '20s', target: BROWSE_MAX },
      { duration: '10s', target: 0 },
    ],
    gracefulRampDown: '5s',
    tags: { scenario: 'browse' },
  };
}

export const options = {
  scenarios,
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
  thresholds: {
    // 先设宽一点，V1 打算被打破；打破本身是结果，不是失败
    'http_req_duration{scenario:seckill}': ['p(99)<5000'],
  },
};

export function browse() {
  const page = Math.floor(Math.random() * 100);
  const res = http.get(`${BASE}/api/products?page=${page}&size=20`, {
    tags: { name: 'list' },
  });
  check(res, { 'list 200': (r) => r.status === 200 });
  sleep(1);
}

export function seckill() {
  const pid = PRODUCT_MODE === 'random'
    ? Math.floor(Math.random() * 90000) + 2   // 2~90001，避开热点商品 1
    : Number(PRODUCT_MODE);
  const payload = JSON.stringify({
    userId: Math.floor(Math.random() * 1_000_000) + 1,
    productId: pid,
    quantity: 1,
  });
  const res = http.post(`${BASE}/api/orders`, payload, {
    headers: { 'Content-Type': 'application/json' },
    tags: { name: 'order' },
  });

  if (res.status === 200) {
    orderSuccess.add(1);
  } else if (res.status === 409) {
    orderSoldOut.add(1);      // 售罄：业务正常结果
  } else {
    orderOther.add(1);        // 5xx / 超时 / 其他：这才是故障
    if (orderOther.count < 5) {
      console.log(`非预期状态码 ${res.status}: ${String(res.body).slice(0, 120)}`);
    }
  }
}

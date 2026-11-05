-- 秒杀扣库存：判断 + 扣减 + 去重，三件事一次原子完成
--
-- KEYS[1] = 库存 key       seckill:stock:{productId}
-- KEYS[2] = 去重集合 key    seckill:users:{productId}
-- ARGV[1] = 购买数量
-- ARGV[2] = userId
--
-- 返回：
--   1  抢到了，库存已扣
--   0  库存不足
--   -1 这个用户已经下过单（幂等）
--   -2 库存没预热
--
-- 为什么必须是 Lua：Redis 单线程执行整个脚本，中间不会插入任何其他命令。
-- 等价于 V0.1 里 AtomicInteger 的那一次 CAS，而不是 count++ 的三步。

-- ① 幂等：同一个用户只放一次
if redis.call('SISMEMBER', KEYS[2], ARGV[2]) == 1 then
  return -1
end

-- ② 读库存
local stock = redis.call('GET', KEYS[1])
if not stock then
  return -2
end

-- ③ 判断
if tonumber(stock) < tonumber(ARGV[1]) then
  return 0
end

-- ④ 扣减 + 记录用户，无条件执行（已通过判断）
redis.call('DECRBY', KEYS[1], ARGV[1])
redis.call('SADD', KEYS[2], ARGV[2])
-- 去重集合设 1 天过期，活动结束后自动清理，避免长期占内存
redis.call('EXPIRE', KEYS[2], 86400)

return 1

-- V2：幂等的最后一道防线
--
-- 同一个用户对同一个商品只能有一笔订单。
-- 为什么需要它：Kafka 是「至少一次」投递，同一条消息可能被消费两次；
-- 消费者重试、重平衡、位点回退都会导致重复消费。
-- 唯一索引让重复插入直接报错，应用捕获后 ack 掉即可。
--
-- 注意：V1 时期这张表没有这个约束，所以升级前要清掉历史订单（本项目是实验数据）。

SET @has_idx = (SELECT COUNT(*) FROM information_schema.STATISTICS
                WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'orders'
                  AND INDEX_NAME = 'uk_user_product');
SET @sql = IF(@has_idx = 0,
    'ALTER TABLE orders ADD UNIQUE KEY uk_user_product (user_id, product_id)',
    'SELECT 1');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

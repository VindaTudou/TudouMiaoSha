-- V1 订单表
--
-- 注意：这里【故意没有】 UNIQUE(user_id, product_id)。
-- 结果就是同一个用户连点两次会产生两笔订单。
-- 幂等方案（Token / 唯一索引）留到 V2 讲，那时会做一次表结构变更。

CREATE TABLE IF NOT EXISTS orders (
    id          BIGINT       NOT NULL AUTO_INCREMENT,
    order_no    VARCHAR(40)  NOT NULL,
    user_id     BIGINT       NOT NULL,
    product_id  BIGINT       NOT NULL,
    quantity    INT          NOT NULL,
    amount      DECIMAL(10,2) NOT NULL,
    status      TINYINT      NOT NULL DEFAULT 0 COMMENT '0=待支付 1=已支付 2=已取消',
    created_at  DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    PRIMARY KEY (id),
    UNIQUE KEY uk_order_no (order_no),
    KEY idx_user (user_id),
    KEY idx_product (product_id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COMMENT '订单';

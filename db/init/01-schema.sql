-- V0.2 / V1 共用的最小表结构
-- 只在数据卷为空时执行一次（docker 的 initdb 机制）

CREATE TABLE IF NOT EXISTS product (
    id          BIGINT      NOT NULL COMMENT '商品 ID',
    name        VARCHAR(64) NOT NULL COMMENT '商品名',
    price       DECIMAL(10, 2) NOT NULL DEFAULT 0.00 COMMENT '单价',
    stock       INT         NOT NULL COMMENT '库存。V1 的热点就集中在这一列',
    version     INT         NOT NULL DEFAULT 0 COMMENT '乐观锁版本号，V1-b 之后可能用到',
    updated_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    PRIMARY KEY (id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4 COMMENT '商品';

-- 只插一行。V0.2 要观察的就是"所有会话抢同一行"。
INSERT INTO product (id, name, price, stock)
VALUES (1, '测试商品-库存1000', 99.00, 1000)
ON DUPLICATE KEY UPDATE stock = VALUES(stock);

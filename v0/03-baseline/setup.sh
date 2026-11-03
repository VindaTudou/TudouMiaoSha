#!/usr/bin/env bash
# 造 10 万行商品数据（V0.3 / V1 共用）
#
# 为什么要固定数据量：压测数字必须和同一份数据规模绑定，否则不可比。
# 这里的 10 万行会被写进 BENCHMARK.md 的环境说明。

set -eu
DB=miaosha
ROWS=${ROWS:-100000}
BATCH=1000

M() { docker exec -i -e MYSQL_PWD=root miaosha-mysql mysql -uroot --default-character-set=utf8mb4 "$DB"; }

echo "清空并重建 product 表..."
M <<'SQL'
DROP TABLE IF EXISTS product;
CREATE TABLE product (
    id          BIGINT       NOT NULL,
    name        VARCHAR(64)  NOT NULL,
    price       DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    stock       INT          NOT NULL,
    version     INT          NOT NULL DEFAULT 0,
    updated_at  DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    PRIMARY KEY (id)
) ENGINE = InnoDB DEFAULT CHARSET = utf8mb4;
SQL

echo "生成 ${ROWS} 行..."
python3 - "$ROWS" "$BATCH" > /tmp/seed.sql <<'PY'
import sys
rows, batch = int(sys.argv[1]), int(sys.argv[2])
out = ["SET autocommit=0;"]
for start in range(1, rows + 1, batch):
    end = min(start + batch, rows + 1)
    vals = []
    for i in range(start, end):
        # id=1 是秒杀热点商品；其余商品随机库存
        stock = 1000 if i == 1 else (i * 37) % 1000
        price = (i % 900) + 9.9
        vals.append(f"({i},'商品-{i}',{price:.2f},{stock},0)")
    out.append("INSERT INTO product (id,name,price,stock,version) VALUES " + ",".join(vals) + ";")
out.append("COMMIT;")
print("\n".join(out))
PY

echo "导入..."
time M < /tmp/seed.sql

M -e "SELECT COUNT(*) AS 行数, MIN(id) AS 最小ID, MAX(id) AS 最大ID FROM product; ANALYZE TABLE product;" 
echo "完成。id=1 的库存是 1000（秒杀商品），其余为随机值。"

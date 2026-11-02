# 秒杀项目 —— 常用命令
# 用法：make help

COMPOSE := docker compose

.PHONY: help up down reset logs sql status

help: ## 显示所有命令
	@grep -E '^[a-z-]+:.*## ' Makefile | awk -F':.*## ' '{printf "  %-8s %s\n", $$1, $$2}'

up: ## 起 MySQL 并等到就绪
	$(COMPOSE) up -d
	@printf "等待 MySQL 就绪"
	@until docker exec miaosha-mysql mysqladmin ping -uroot -proot --silent >/dev/null 2>&1; do printf "."; sleep 1; done
	@echo " ok"
	@echo ""
	@echo "连接方式：mysql -h127.0.0.1 -P3306 -uroot -proot miaosha"

down: ## 停容器，数据保留
	$(COMPOSE) down

reset: ## 停容器并删数据卷（下次 up 重新建表）
	$(COMPOSE) down -v
	@echo "数据卷已删除。下次 make up 会重新执行 db/init/01-schema.sql"

logs: ## 实时看 MySQL 日志
	$(COMPOSE) logs -f mysql

sql: ## 进入 mysql 客户端
	docker exec -it miaosha-mysql mysql -uroot -proot miaosha

status: ## 容器状态
	$(COMPOSE) ps

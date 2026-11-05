# 秒杀项目 —— 常用命令
# 用法：make help

# BUILDX_CONFIG 指到项目内：否则 buildx 会往 ~/.docker 写，沙箱不允许
COMPOSE := BUILDX_CONFIG=$(CURDIR)/.buildx docker compose

.PHONY: help up down reset logs sql status app-build app-run app-bg app-stop obs-up obs-down obs-status verify-metrics

help: ## 显示所有命令
	@grep -E '^[a-z-]+:.*## ' Makefile | awk -F':.*## ' '{printf "  %-8s %s\n", $$1, $$2}'

up: ## 起 MySQL 并等到就绪
	$(COMPOSE) up -d
	@printf "等待 MySQL 就绪"
	@until docker exec miaosha-mysql mysqladmin ping -uroot -proot --silent >/dev/null 2>&1; do printf "."; sleep 1; done
	@echo " ok"
	@echo ""
	@echo "连接方式：mysql -h127.0.0.1 -P3307 -uroot -proot miaosha"

down: ## 停容器，数据保留
	$(COMPOSE) down

reset: ## 停容器并删数据卷（下次 up 重新建表）
	$(COMPOSE) down -v
	@echo "数据卷已删除。下次 make up 会重新执行 db/init/01-schema.sql"

logs: ## 实时看 MySQL 日志
	$(COMPOSE) logs -f mysql

sql: ## 进入 mysql 客户端
	docker exec -it miaosha-mysql mysql -uroot -proot --default-character-set=utf8mb4 miaosha

status: ## 容器状态
	$(COMPOSE) ps

# ---------- 应用 ----------

M2 = $(CURDIR)/.m2repo

app-build: ## 编译应用（项目内 Maven 仓库，避免写 ~/.m2）
	cd app && mvn -q -Dmaven.repo.local=$(M2) -DskipTests package
	@ls -lh app/target/miaosha.jar

app-run: ## 前台跑应用（连 127.0.0.1:3307）
	java -Xms256m -Xmx384m -jar app/target/miaosha.jar

app-bg: ## 后台跑应用，日志写 logs/app.log
	@mkdir -p logs
	@nohup java -Xms256m -Xmx384m -jar app/target/miaosha.jar > logs/app.log 2>&1 & echo $$! > logs/app.pid
	@echo "应用 pid=$$(cat logs/app.pid)，日志: logs/app.log"

app-stop: ## 停后台应用
	@if [ -f logs/app.pid ]; then kill $$(cat logs/app.pid) 2>/dev/null; rm -f logs/app.pid; echo "已停止"; else echo "没在跑"; fi

obs-up: ## 起 Prometheus(9090) + Grafana(3000)
	@ops/observability.sh up

obs-down: ## 停 Prometheus + Grafana
	@ops/observability.sh down

obs-status: ## 看可观测性组件状态
	@ops/observability.sh status

verify-metrics: ## M1 验收：核对监控数字与 k6 数字（攻击性压测，约 4 分钟）
	@bash ops/verify-metrics.sh 3000 30s

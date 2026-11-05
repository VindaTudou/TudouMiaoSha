# 用 eclipse-temurin 的 arm64 原生镜像，避免 QEMU 模拟拖慢压测
# 固定小版本：避免 base 镜像漂移导致"昨天能跑今天不能跑"
FROM eclipse-temurin:17.0.13_11-jre

# 只为 healthcheck 装 curl（镜像里默认没有）
RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY target/miaosha.jar app.jar

EXPOSE 8080
# MaxRAMPercentage 让 JVM 按容器内存比例取堆，避免写死导致 OOM
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-jar", "/app/app.jar"]

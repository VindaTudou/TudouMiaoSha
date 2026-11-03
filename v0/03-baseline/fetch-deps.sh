#!/usr/bin/env bash
# 下载压测用的 JDBC 驱动（jar 不进 git，避免仓库膨胀）
set -eu
cd "$(dirname "$0")"
mkdir -p lib
URL=https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/8.4.0/mysql-connector-j-8.4.0.jar
[ -f lib/mysql-connector-j-8.4.0.jar ] || curl -sSL -o lib/mysql-connector-j-8.4.0.jar "$URL"
echo "驱动就绪：$(ls -lh lib/*.jar | awk '{print $9, $5}')"

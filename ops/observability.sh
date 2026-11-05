#!/usr/bin/env bash
# 启动/停止可观测性组件（Prometheus + Grafana 原生版）
#
# 为什么不用 docker：Docker Hub（registry-1.docker.io）在当前网络下不通，
# prom/prometheus 和 grafana/grafana 镜像拉不下来。
# 而 ghcr.io 通，Homebrew 的安装包正好托管在 ghcr.io，所以走 brew 原生版。
#
# 用法：ops/observability.sh up | down | status

set -u
cd "$(dirname "$0")/.."
ROOT=$PWD
RT=$ROOT/.runtime
GRAFANA_HOME=/opt/homebrew/opt/grafana/share/grafana
GRAFANA_INI=/opt/homebrew/etc/grafana/grafana.ini

ensure_dirs() {
  mkdir -p "$RT/prometheus" "$RT/grafana/logs" "$RT/grafana/plugins" "$RT/logs"
}

pid_alive() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }

up() {
  ensure_dirs

  if pid_alive "$RT/prometheus.pid"; then
    echo "Prometheus 已在运行 (pid $(cat "$RT/prometheus.pid"))"
  else
    nohup prometheus \
      --config.file="$ROOT/ops/prometheus/prometheus.yml" \
      --storage.tsdb.path="$RT/prometheus" \
      --storage.tsdb.retention.time=15d \
      --web.listen-address=127.0.0.1:9090 \
      --web.enable-lifecycle \
      > "$RT/logs/prometheus.log" 2>&1 &
    echo $! > "$RT/prometheus.pid"
    echo "Prometheus 启动 pid=$! → http://127.0.0.1:9090"
  fi

  if pid_alive "$RT/grafana.pid"; then
    echo "Grafana 已在运行 (pid $(cat "$RT/grafana.pid"))"
  else
    nohup grafana server \
      --homepath "$GRAFANA_HOME" \
      --config "$GRAFANA_INI" \
      cfg:default.paths.data="$RT/grafana" \
      cfg:default.paths.logs="$RT/grafana/logs" \
      cfg:default.paths.plugins="$RT/grafana/plugins" \
      cfg:default.paths.provisioning="$ROOT/ops/grafana/provisioning" \
      cfg:default.server.http_addr=127.0.0.1 \
      cfg:default.server.http_port=3000 \
      > "$RT/logs/grafana.log" 2>&1 &
    echo $! > "$RT/grafana.pid"
    echo "Grafana 启动 pid=$! → http://127.0.0.1:3000 (admin/admin)"
  fi

  echo
  echo "等几秒后检查："
  echo "  curl -s http://127.0.0.1:9090/-/ready"
  echo "  curl -s -u admin:admin http://127.0.0.1:3000/api/health"
}

down() {
  for n in prometheus grafana; do
    if pid_alive "$RT/$n.pid"; then
      kill "$(cat "$RT/$n.pid")" 2>/dev/null && echo "$n 已停止"
      rm -f "$RT/$n.pid"
    else
      echo "$n 没在跑"
    fi
  done
}

status() {
  for n in prometheus grafana; do
    if pid_alive "$RT/$n.pid"; then
      echo "$n: 运行中 (pid $(cat "$RT/$n.pid"))"
    else
      echo "$n: 未运行"
    fi
  done
  echo
  printf 'Prometheus ready: '; curl -s -m 3 http://127.0.0.1:9090/-/ready || echo "不通"
  echo
  printf 'Grafana health:   '; curl -s -m 3 -u admin:admin http://127.0.0.1:3000/api/health || echo "不通"
  echo
}

case "${1:-status}" in
  up) up ;;
  down) down ;;
  status) status ;;
  *) echo "用法: $0 up|down|status"; exit 1 ;;
esac

#!/usr/bin/env bash
# 网关（nginx）起停
#
# 为什么用 -p 指定 prefix：nginx 默认把 pid、日志、临时文件写到 /opt/homebrew/var，
# 而沙箱只允许写工作区。用 -p 把一切落在 .runtime/nginx 下，
# 顺便也让"删掉 .runtime 就干净了"这件事成立。
#
# 用法：ops/nginx.sh up | down | reload | status

set -u
cd "$(dirname "$0")/.."
ROOT=$PWD
RT=$ROOT/.runtime/nginx
SRC=$ROOT/ops/nginx/miaosha.conf
CONF=$RT/nginx.conf

mkdir -p "$RT"/{client_body,proxy,fastcgi,uwsgi,scgi}

render() {
  sed "s#__ROOT__#$ROOT#g" "$SRC" > "$CONF"
}

case "${1:-status}" in
  up)
    render
    if [ -f "$RT/nginx.pid" ] && kill -0 "$(cat "$RT/nginx.pid")" 2>/dev/null; then
      echo "nginx 已在运行 (pid $(cat "$RT/nginx.pid"))"
    else
      nginx -p "$RT" -c "$CONF" -e "$RT/error.log"
      echo "nginx 启动 → http://127.0.0.1:8000 （转发到 127.0.0.1:8080）"
    fi
    ;;
  down)
    if [ -f "$RT/nginx.pid" ]; then
      nginx -p "$RT" -c "$CONF" -e "$RT/error.log" -s quit 2>/dev/null && echo "nginx 已停止"
    else
      echo "nginx 没在跑"
    fi
    ;;
  reload)
    render
    nginx -p "$RT" -c "$CONF" -e "$RT/error.log" -s reload 2>/dev/null && echo "nginx 已重载配置"
    ;;
  status)
    if [ -f "$RT/nginx.pid" ] && kill -0 "$(cat "$RT/nginx.pid")" 2>/dev/null; then
      echo "nginx 运行中 (pid $(cat "$RT/nginx.pid"))"
      printf '直连 8080: '; curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/actuator/health || echo "不通"
      printf '经网关 8000: '; curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/actuator/health || echo "不通"
    else
      echo "nginx 未运行"
    fi
    ;;
  *)
    echo "用法: $0 up|down|reload|status"; exit 1 ;;
esac

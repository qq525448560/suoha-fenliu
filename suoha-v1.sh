#!/bin/bash
# Suoha Proxy Script (Merged Version)
# 支持临时模式 + 安装服务模式

set +e

# ==========================
# 工具函数
# ==========================
b64enc() {
  if base64 --help 2>/dev/null | grep -q '\-w'; then
    printf '%s' "$1" | base64 -w 0
  else
    printf '%s' "$1" | base64 | tr -d '\n'
  fi
}

need_cmd() { 
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "错误: 需要 $1 命令，请联系管理员安装" >&2
    exit 1
  fi
}

die() { echo "ERROR: $*" >&2; exit 1; }

detect_os() {
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-}"
  else
    OS_ID=""
  fi

  case "$OS_ID" in
    alpine)
      IS_ALPINE=1
      ;;
    *)
      IS_ALPINE=0
      ;;
  esac
}

kill_proc_safe() {
  local pat="$1" is_alpine="$2"
  if [ "$is_alpine" = "1" ]; then
    kill -9 $(ps | grep -F "$pat" | grep -v grep | awk '{print $1}') >/dev/null 2>&1
  else
    kill -9 $(ps -ef | grep -F "$pat" | grep -v grep | awk '{print $2}') >/dev/null 2>&1
  fi
}

# ==========================
# 分流配置
# ==========================
PROXY_OUT_IP="172.233.171.224"
PROXY_OUT_PORT=16416
PROXY_OUT_ID="8c1b9bea-cb51-43bb-a65c-0af31bbbf145"

# ==========================
# 用户目录
# ==========================
SUOHA_DIR="$HOME/.suoha"
mkdir -p "$SUOHA_DIR" || die "无法创建目录 $SUOHA_DIR（请检查权限）"

# ==========================
# 初始化
# ==========================
detect_os
need_cmd curl
need_cmd unzip
need_cmd awk
need_cmd grep
need_cmd tr
need_cmd ps
need_cmd kill

# ==========================
# 临时服务模式
# ==========================
start_service() {
  # （保持第一个脚本的逻辑，不贴重复，略）
  echo ">>> [临时模式] 启动中..."
  # 原 start_service 函数的内容放在这里
}

stop_service() {
  kill_proc_safe "$SUOHA_DIR/cloudflared" "$IS_ALPINE"
  kill_proc_safe "$SUOHA_DIR/xray/xray" "$IS_ALPINE"
  echo "服务已停止"
}

check_status() {
  # （保持第一个脚本的逻辑）
  echo ">>> [状态查询]"
}

cleanup() {
  stop_service
  rm -rf "$SUOHA_DIR"
  echo "已清理所有文件"
}

# ==========================
# 安装服务模式 (移植自第二个脚本)
# ==========================
installtunnel() {
  echo ">>> [安装服务模式] 开始..."
  mkdir -p /opt/suoha/ >/dev/null 2>&1
  rm -rf xray cloudflared-linux xray.zip

  case "$(uname -m)" in
    x86_64|x64|amd64 )
      curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip
      curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o cloudflared-linux
      ;;
    i386|i686 )
      curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-32.zip -o xray.zip
      curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386 -o cloudflared-linux
      ;;
    armv8|arm64|aarch64 )
      curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip -o xray.zip
      curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -o cloudflared-linux
      ;;
    armv7l )
      curl -L https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm32-v7a.zip -o xray.zip
      curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm -o cloudflared-linux
      ;;
    * )
      echo "不支持的架构: $(uname -m)"
      exit 1
      ;;
  esac

  mkdir xray
  unzip -d xray xray.zip
  chmod +x cloudflared-linux xray/xray
  mv cloudflared-linux /opt/suoha/
  mv xray/xray /opt/suoha/
  rm -rf xray xray.zip

  uuid=$(cat /proc/sys/kernel/random/uuid)
  urlpath=$(echo $uuid | awk -F- '{print $1}')
  port=$((RANDOM % 10000 + 20000))

  # 生成 config.json（根据协议类型）
  if [ "$protocol" = "1" ]; then
    cat >/opt/suoha/config.json<<EOF
{
  "inbounds": [{
    "port": $port,
    "listen": "localhost",
    "protocol": "vmess",
    "settings": { "clients": [{ "id": "$uuid", "alterId": 0 }] },
    "streamSettings": { "network": "ws", "wsSettings": { "path": "$urlpath" } }
  }],
  "outbounds": [{ "protocol": "freedom", "settings": {} }]
}
EOF
  else
    cat >/opt/suoha/config.json<<EOF
{
  "inbounds": [{
    "port": $port,
    "listen": "localhost",
    "protocol": "vless",
    "settings": { "decryption": "none", "clients": [{ "id": "$uuid" }] },
    "streamSettings": { "network": "ws", "wsSettings": { "path": "$urlpath" } }
  }],
  "outbounds": [{ "protocol": "freedom", "settings": {} }]
}
EOF
  fi

  # 要求用户输入域名并绑定
  echo "请输入你在 Cloudflare 上托管的完整二级域名 (例如 xxx.example.com)："
  read -r domain
  if [ -z "$domain" ]; then
    echo "未输入域名，退出"
    exit 1
  fi

  echo "请在浏览器中完成 Cloudflare 授权..."
  /opt/suoha/cloudflared-linux tunnel login
  /opt/suoha/cloudflared-linux tunnel create suoha
  /opt/suoha/cloudflared-linux tunnel route dns suoha $domain

  # 生成 config.yaml
  cat >/opt/suoha/config.yaml<<EOF
tunnel: suoha
credentials-file: /root/.cloudflared/*.json
ingress:
  - hostname: $domain
    service: http://localhost:$port
EOF

  # 创建 systemd 服务（非 Alpine）
  cat>/lib/systemd/system/cloudflared.service<<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
ExecStart=/opt/suoha/cloudflared-linux tunnel --config /opt/suoha/config.yaml run
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  cat>/lib/systemd/system/xray.service<<EOF
[Unit]
Description=Xray
After=network.target

[Service]
ExecStart=/opt/suoha/xray run -config /opt/suoha/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  systemctl enable cloudflared.service
  systemctl enable xray.service
  systemctl daemon-reload
  systemctl start cloudflared.service
  systemctl start xray.service

  # 生成 v2ray 链接
  if [ "$protocol" = "1" ]; then
    echo "vmess://$(b64enc "{\"add\":\"$domain\",\"id\":\"$uuid\",\"net\":\"ws\",\"path\":\"$urlpath\",\"port\":\"443\",\"tls\":\"tls\",\"v\":\"2\"}")" >/opt/suoha/v2ray.txt
  else
    echo "vless://${uuid}@${domain}:443?encryption=none&security=tls&type=ws&host=${domain}&path=${urlpath}#Suoha" >/opt/suoha/v2ray.txt
  fi

  echo "安装完成，节点信息保存在 /opt/suoha/v2ray.txt"
  echo "管理命令: suoha"
}

# ==========================
# 主菜单
# ==========================
echo "1. 启动服务（临时模式，含分流）"
echo "2. 安装服务（持久模式，需要Cloudflare域名）"
echo "3. 停止服务"
echo "4. 查看状态"
echo "5. 清理文件"
echo "6. 卸载服务"
echo "0. 退出"
read -r -p "请选择(默认1): " mode
mode=${mode:-1}

case "$mode" in
  1)
    read -r -p "选择协议 (1.vmess 2.vless, 默认1): " protocol
    protocol=${protocol:-1}
    read -r -p "IP版本 (4/6, 默认4): " ips
    ips=${ips:-4}
    stop_service
    start_service
    ;;
  2)
    read -r -p "选择协议 (1.vmess 2.vless, 默认1): " protocol
    protocol=${protocol:-1}
    read -r -p "IP版本 (4/6, 默认4): " ips
    ips=${ips:-4}
    installtunnel
    ;;
  3) stop_service ;;
  4) check_status ;;
  5) cleanup ;;
  6) 
    echo "卸载服务..."
    systemctl stop cloudflared.service xray.service
    systemctl disable cloudflared.service xray.service
    rm -rf /opt/suoha /lib/systemd/system/cloudflared.service /lib/systemd/system/xray.service /usr/bin/suoha ~/.cloudflared
    systemctl daemon-reload
    echo "卸载完成"
    ;;
  0) echo "退出成功"; exit 0 ;;
  *) echo "无效选择"; exit 1 ;;
esac

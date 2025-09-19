#!/bin/bash
# 无root权限版代理脚本 + 安装服务选项
set +e

# 基础工具函数
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
    pkill -f "$pat" >/dev/null 2>&1 || true
  else
    pkill -f "$pat" >/dev/null 2>&1 || true
  fi
}

# 分流配置（可根据需要修改）
PROXY_OUT_IP="172.233.171.224"
PROXY_OUT_PORT=16416
PROXY_OUT_ID="8c1b9bea-cb51-43bb-a65c-0af31bbbf145"

# 用户目录（非root可访问）
SUOHA_DIR="$HOME/.suoha"
mkdir -p "$SUOHA_DIR" || die "无法创建目录 $SUOHA_DIR（请检查权限）"

# 初始化
detect_os
need_cmd curl
need_cmd unzip
need_cmd awk
need_cmd grep
need_cmd tr
need_cmd ps
need_cmd kill

# ---------- 启动服务（原有无root快速模式） ----------
start_service() {
  rm -rf "$SUOHA_DIR/xray" "$SUOHA_DIR/cloudflared" "$SUOHA_DIR/xray.zip" "$SUOHA_DIR/argo.log"

  arch="$(uname -m)"
  case "$arch" in
    x86_64|x64|amd64 )
      curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o "$SUOHA_DIR/xray.zip" || die "下载Xray失败"
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o "$SUOHA_DIR/cloudflared" || die "下载cloudflared失败"
      ;;
    i386|i686 )
      curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-32.zip -o "$SUOHA_DIR/xray.zip" || die "下载Xray失败"
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386 -o "$SUOHA_DIR/cloudflared" || die "下载cloudflared失败"
      ;;
    armv8|arm64|aarch64 )
      curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip -o "$SUOHA_DIR/xray.zip" || die "下载Xray失败"
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -o "$SUOHA_DIR/cloudflared" || die "下载cloudflared失败"
      ;;
    armv7l )
      curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm32-v7a.zip -o "$SUOHA_DIR/xray.zip" || die "下载Xray失败"
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm -o "$SUOHA_DIR/cloudflared" || die "下载cloudflared失败"
      ;;
    * )
      echo "不支持的架构: $(uname -m)"; exit 1;;
  esac

  mkdir -p "$SUOHA_DIR/xray"
  unzip -q -d "$SUOHA_DIR/xray" "$SUOHA_DIR/xray.zip" || die "解压Xray失败"
  chmod +x "$SUOHA_DIR/cloudflared" "$SUOHA_DIR/xray/xray"
  rm -f "$SUOHA_DIR/xray.zip"

  uuid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "uuid-$(date +%s)")"
  urlpath="$(echo "$uuid" | awk -F- '{print $1}')"
  port=$((RANDOM % 10000 + 20000))  # 非root端口

  # 生成Xray配置（分流 YouTube / OpenAI）
  if [ "$protocol" = "1" ]; then
cat > "$SUOHA_DIR/xray/config.json" <<EOF
{
  "inbounds": [ {
    "port": $port,
    "listen": "localhost",
    "protocol": "vmess",
    "settings": { "clients": [{ "id": "$uuid", "alterId": 0 }] },
    "streamSettings": { "network": "ws", "wsSettings": { "path": "$urlpath" } }
  } ],
  "outbounds": [
    { "protocol": "freedom", "settings": {}, "tag": "direct" },
    { "protocol": "vmess", "tag": "proxy",
      "settings": { "vnext": [{ "address": "$PROXY_OUT_IP", "port": $PROXY_OUT_PORT,
        "users": [{ "id": "$PROXY_OUT_ID", "alterId": 0 }] }] } },
    { "protocol": "blackhole", "tag": "block", "settings": {} }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "domain": [
          "youtube.com", "googlevideo.com", "ytimg.com", "gstatic.com",
          "googleapis.com", "ggpht.com", "googleusercontent.com"
        ],
        "outboundTag": "proxy"
      },
      {
        "type": "field",
        "domain": [
          "openai.com", "chat.openai.com", "api.openai.com",
          "auth0.openai.com", "cdn.openai.com", "oaiusercontent.com"
        ],
        "outboundTag": "proxy"
      }
    ]
  }
}
EOF
  else
cat > "$SUOHA_DIR/xray/config.json" <<EOF
{
  "inbounds": [ {
    "port": $port,
    "listen": "localhost",
    "protocol": "vless",
    "settings": { "decryption": "none", "clients": [{ "id": "$uuid" }] },
    "streamSettings": { "network": "ws", "wsSettings": { "path": "$urlpath" } }
  } ],
  "outbounds": [
    { "protocol": "freedom", "settings": {}, "tag": "direct" },
    { "protocol": "vmess", "tag": "proxy",
      "settings": { "vnext": [{ "address": "$PROXY_OUT_IP", "port": $PROXY_OUT_PORT,
        "users": [{ "id": "$PROXY_OUT_ID", "alterId": 0 }] }] } },
    { "protocol": "blackhole", "tag": "block", "settings": {} }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "domain": [
          "youtube.com", "googlevideo.com", "ytimg.com", "gstatic.com",
          "googleapis.com", "ggpht.com", "googleusercontent.com"
        ],
        "outboundTag": "proxy"
      },
      {
        "type": "field",
        "domain": [
          "openai.com", "chat.openai.com", "api.openai.com",
          "auth0.openai.com", "cdn.openai.com", "oaiusercontent.com"
        ],
        "outboundTag": "proxy"
      }
    ]
  }
}
EOF
  fi

  # 启动 xray 与 cloudflared（快速模式）
  "$SUOHA_DIR/xray/xray" run -config "$SUOHA_DIR/xray/config.json" >"$SUOHA_DIR/xray.log" 2>&1 &
  "$SUOHA_DIR/cloudflared" tunnel --url "http://localhost:$port" --no-autoupdate --edge-ip-version "$ips" --protocol http2 > "$SUOHA_DIR/argo.log" 2>&1 &
  sleep 1

  # 获取Argo地址
  n=0
  while :; do
    n=$((n+1))
    clear
    echo "等待Cloudflare Argo生成地址（$n秒）"
    argo_url="$(grep -oE 'https://[a-zA-Z0-9.-]+trycloudflare\.com' "$SUOHA_DIR/argo.log" | tail -n1)"

    if [ $n -ge 30 ]; then
      n=0
      kill_proc_safe "$SUOHA_DIR/cloudflared" "$IS_ALPINE"
      kill_proc_safe "$SUOHA_DIR/xray/xray" "$IS_ALPINE"
      rm -f "$SUOHA_DIR/argo.log"
      echo "超时，重试中..."
      "$SUOHA_DIR/cloudflared" tunnel --url "http://localhost:$port" --no-autoupdate --edge-ip-version "$ips" --protocol http2 > "$SUOHA_DIR/argo.log" 2>&1 &
      "$SUOHA_DIR/xray/xray" run -config "$SUOHA_DIR/xray/config.json" >"$SUOHA_DIR/xray.log" 2>&1 &
      sleep 1
    elif [ -z "$argo_url" ]; then
      sleep 1
    else
      rm -f "$SUOHA_DIR/argo.log"
      break
    fi
  done

  clear
  argo_host="${argo_url#https://}"

  # 生成本地v2ray/vless 链接文件
  if [ "$protocol" = "1" ]; then
    {
      echo -e "VMess链接（含YouTube和ChatGPT分流）\n"
      json_tls='{"add":"x.cf.090227.xyz","aid":"0","host":"'"$argo_host"'","id":"'"$uuid"'","net":"ws","path":"'"$urlpath"'","port":"2053","ps":"X-分流_TLS","tls":"tls","type":"none","v":"2"}'
      echo "vmess://$(b64enc "$json_tls")"
      echo -e "\nTLS端口: 2053/2083/2087/2096/8443\n"
      json_nontls='{"add":"x.cf.090227.xyz","aid":"0","host":"'"$argo_host"'","id":"'"$uuid"'","net":"ws","path":"'"$urlpath"'","port":"2052","ps":"X-分流","tls":"","type":"none","v":"2"}'
      echo "vmess://$(b64enc "$json_nontls")"
      echo -e "\n非TLS端口: 2052/2082/2086/2095/8080/8880"
    } > "$SUOHA_DIR/v2ray.txt"
  else
    {
      echo -e "VLESS链接（含YouTube和ChatGPT分流）\n"
      echo "vless://${uuid}@x.cf.090227.xyz:2053?encryption=none&security=tls&type=ws&host=${argo_host}&path=${urlpath}#X-分流_TLS"
      echo -e "\nTLS端口: 2053/2083/2087/2096/8443\n"
      echo "vless://${uuid}@x.cf.090227.xyz:2052?encryption=none&security=none&type=ws&host=${argo_host}&path=${urlpath}#X-分流"
      echo -e "\n非TLS端口: 2052/2082/2086/2095/8080/8880"
    } > "$SUOHA_DIR/v2ray.txt"
  fi

  cat "$SUOHA_DIR/v2ray.txt"
  echo -e "\n链接已保存至 $SUOHA_DIR/v2ray.txt"
  echo "停止服务: $0 stop"
}

# ---------- 停止服务 ----------
stop_service() {
  kill_proc_safe "$SUOHA_DIR/cloudflared" "$IS_ALPINE"
  kill_proc_safe "$SUOHA_DIR/xray/xray" "$IS_ALPINE"
  echo "服务已停止"
}

# ---------- 查看状态 ----------
check_status() {
  if [ "$IS_ALPINE" = "1" ]; then
    [ $(ps | grep -F "$SUOHA_DIR/cloudflared" | grep -v grep | wc -l) -gt 0 ] && echo "cloudflared: 运行中" || echo "cloudflared: 已停止"
    [ $(ps | grep -F "$SUOHA_DIR/xray/xray" | grep -v grep | wc -l) -gt 0 ] && echo "xray: 运行中" || echo "xray: 已停止"
  else
    [ $(ps -ef | grep -F "$SUOHA_DIR/cloudflared" | grep -v grep | wc -l) -gt 0 ] && echo "cloudflared: 运行中" || echo "cloudflared: 已停止"
    [ $(ps -ef | grep -F "$SUOHA_DIR/xray/xray" | grep -v grep | wc -l) -gt 0 ] && echo "xray: 运行中" || echo "xray: 已停止"
  fi
  
  [ -f "$SUOHA_DIR/v2ray.txt" ] && echo -e "\n当前链接:\n$(cat "$SUOHA_DIR/v2ray.txt")" || echo -e "\n未找到链接"
}

# ---------- 清理文件 ----------
cleanup() {
  stop_service
  rm -rf "$SUOHA_DIR"
  echo "已清理所有文件"
}

# ---------- 安装服务（需要 root） ----------
install_service() {
  if [ "$(id -u)" -ne 0 ]; then
    die "安装服务需要 root 权限，请以 root 用户或使用 sudo 运行脚本并选择安装服务（选项2）"
  fi

  read -r -p "选择协议 (1.vmess 2.vless, 默认1): " protocol_inst
  protocol_inst=${protocol_inst:-1}
  [ "$protocol_inst" != "1" ] && [ "$protocol_inst" != "2" ] && die "请输入1或2"

  read -r -p "IP版本 (4/6, 默认4): " ips_inst
  ips_inst=${ips_inst:-4}
  [ "$ips_inst" != "4" ] && [ "$ips_inst" != "6" ] && die "请输入4或6"

  echo "将安装到 /opt/suoha ，并创建 systemd 服务（或 Alpine 的 local.d）。"
  mkdir -p /opt/suoha || die "无法创建 /opt/suoha"
  rm -rf /opt/suoha/xray /opt/suoha/cloudflared /opt/suoha/xray.zip

  arch="$(uname -m)"
  case "$arch" in
    x86_64|x64|amd64 )
      curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o /opt/suoha/xray.zip || die "下载Xray失败"
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /opt/suoha/cloudflared || die "下载cloudflared失败"
      ;;
    i386|i686 )
      curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-32.zip -o /opt/suoha/xray.zip || die "下载Xray失败"
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386 -o /opt/suoha/cloudflared || die "下载cloudflared失败"
      ;;
    armv8|arm64|aarch64 )
      curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip -o /opt/suoha/xray.zip || die "下载Xray失败"
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -o /opt/suoha/cloudflared || die "下载cloudflared失败"
      ;;
    armv7l )
      curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm32-v7a.zip -o /opt/suoha/xray.zip || die "下载Xray失败"
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm -o /opt/suoha/cloudflared || die "下载cloudflared失败"
      ;;
    * )
      die "不支持的架构: $(uname -m)"
      ;;
  esac

  unzip -q -d /opt/suoha/xray /opt/suoha/xray.zip || die "解压Xray失败"
  chmod +x /opt/suoha/cloudflared /opt/suoha/xray/xray
  rm -f /opt/suoha/xray.zip

  uuid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "uuid-$(date +%s)")"
  urlpath="$(echo "$uuid" | awk -F- '{print $1}')"
  port=$((RANDOM % 10000 + 20000))

  # 生成持久化 config.json（/opt/suoha/config.json）
  if [ "$protocol_inst" = "1" ]; then
cat > /opt/suoha/config.json <<EOF
{
  "inbounds": [ {
    "port": $port,
    "listen": "localhost",
    "protocol": "vmess",
    "settings": { "clients": [{ "id": "$uuid", "alterId": 0 }] },
    "streamSettings": { "network": "ws", "wsSettings": { "path": "$urlpath" } }
  } ],
  "outbounds": [
    { "protocol": "freedom", "settings": {}, "tag": "direct" },
    { "protocol": "vmess", "tag": "proxy",
      "settings": { "vnext": [{ "address": "$PROXY_OUT_IP", "port": $PROXY_OUT_PORT,
        "users": [{ "id": "$PROXY_OUT_ID", "alterId": 0 }] }] } },
    { "protocol": "blackhole", "tag": "block", "settings": {} }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "domain": [
          "youtube.com", "googlevideo.com", "ytimg.com", "gstatic.com",
          "googleapis.com", "ggpht.com", "googleusercontent.com"
        ],
        "outboundTag": "proxy"
      },
      {
        "type": "field",
        "domain": [
          "openai.com", "chat.openai.com", "api.openai.com",
          "auth0.openai.com", "cdn.openai.com", "oaiusercontent.com"
        ],
        "outboundTag": "proxy"
      }
    ]
  }
}
EOF
  else
cat > /opt/suoha/config.json <<EOF
{
  "inbounds": [ {
    "port": $port,
    "listen": "localhost",
    "protocol": "vless",
    "settings": { "decryption": "none", "clients": [{ "id": "$uuid" }] },
    "streamSettings": { "network": "ws", "wsSettings": { "path": "$urlpath" } }
  } ],
  "outbounds": [
    { "protocol": "freedom", "settings": {}, "tag": "direct" },
    { "protocol": "vmess", "tag": "proxy",
      "settings": { "vnext": [{ "address": "$PROXY_OUT_IP", "port": $PROXY_OUT_PORT,
        "users": [{ "id": "$PROXY_OUT_ID", "alterId": 0 }] }] } },
    { "protocol": "blackhole", "tag": "block", "settings": {} }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "domain": [
          "youtube.com", "googlevideo.com", "ytimg.com", "gstatic.com",
          "googleapis.com", "ggpht.com", "googleusercontent.com"
        ],
        "outboundTag": "proxy"
      },
      {
        "type": "field",
        "domain": [
          "openai.com", "chat.openai.com", "api.openai.com",
          "auth0.openai.com", "cdn.openai.com", "oaiusercontent.com"
        ],
        "outboundTag": "proxy"
      }
    ]
  }
}
EOF
  fi

  # cloudflared 登录并创建 tunnel
  echo "接下来将打开 Cloudflare 登录流程，请在浏览器中完成授权。"
  /opt/suoha/cloudflared tunnel login --edge-ip-version "$ips_inst" --protocol http2 || echo "请按提示在浏览器完成登录（如果失败请手动运行 /opt/suoha/cloudflared tunnel login）"

  # 列出现有 tunnel
  /opt/suoha/cloudflared tunnel list > /opt/suoha/argo.log 2>&1
  echo -e "当前已绑定的 TUNNEL:\n"
  sed 1,2d /opt/suoha/argo.log | awk '{print $2}' || true

  read -r -p "请输入要绑定的完整二级域名 (例如: sub.example.com): " domain
  [ -z "$domain" ] && die "未输入域名，退出"
  if [ "$(echo "$domain" | grep -c '\.')" -eq 0 ]; then
    die "域名格式不正确"
  fi

  name=$(echo "$domain" | awk -F. '{print $1}')
  if [ $(sed 1,2d /opt/suoha/argo.log | awk '{print $2}' | grep -w "$name" | wc -l) -eq 0 ]; then
    echo "创建 TUNNEL $name ..."
    /opt/suoha/cloudflared tunnel create "$name" > /opt/suoha/argo.log 2>&1 || die "创建 tunnel 失败，查看 /opt/suoha/argo.log"
    echo "TUNNEL $name 创建成功"
  else
    echo "TUNNEL $name 已存在，尝试 cleanup"
    /opt/suoha/cloudflared tunnel cleanup "$name" > /opt/suoha/argo.log 2>&1 || true
  fi

  echo "绑定 TUNNEL $name 到域名 $domain ..."
  /opt/suoha/cloudflared tunnel route dns --overwrite-dns "$name" "$domain" > /opt/suoha/argo.log 2>&1 || die "绑定域名失败，查看 /opt/suoha/argo.log"
  tunneluuid=$(cut -d= -f2 /opt/suoha/argo.log || true)
  echo "绑定成功。tunneluuid: $tunneluuid"

  # 生成 config.yaml（cloudflared）
cat > /opt/suoha/config.yaml <<EOF
tunnel: $tunneluuid
credentials-file: /root/.cloudflared/$tunneluuid.json

ingress:
  - hostname: $domain
    service: http://localhost:$port
  - service: http_status:404
EOF

  # 创建 systemd 服务或 Alpine local.d
  if [ "$IS_ALPINE" -eq 1 ]; then
    cat > /etc/local.d/cloudflared.start <<EOF
/opt/suoha/cloudflared --edge-ip-version $ips_inst --protocol http2 tunnel --config /opt/suoha/config.yaml run $name &
EOF
    cat > /etc/local.d/xray.start <<EOF
/opt/suoha/xray/xray run -config /opt/suoha/config.json &
EOF
    chmod +x /etc/local.d/cloudflared.start /etc/local.d/xray.start
    rc-update add local
    /etc/local.d/cloudflared.start >/dev/null 2>&1 || true
    /etc/local.d/xray.start >/dev/null 2>&1 || true
    echo "Alpine local.d 启动脚本已创建并启动（如果可用）"
  else
    # systemd units
    cat > /lib/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
TimeoutStartSec=0
Type=simple
ExecStart=/opt/suoha/cloudflared --edge-ip-version $ips_inst --protocol http2 tunnel --config /opt/suoha/config.yaml run $name
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    cat > /lib/systemd/system/xray.service <<EOF
[Unit]
Description=Xray
After=network.target

[Service]
TimeoutStartSec=0
Type=simple
ExecStart=/opt/suoha/xray/xray run -config /opt/suoha/config.json
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload || true
    systemctl enable cloudflared.service >/dev/null 2>&1 || true
    systemctl enable xray.service >/dev/null 2>&1 || true
    systemctl restart cloudflared.service || true
    systemctl restart xray.service || true

    echo "systemd 服务已创建并启动（/lib/systemd/system/cloudflared.service, xray.service）"
  fi

  # 保存一份连接信息供查看
  if [ "$protocol_inst" = "1" ]; then
    {
      echo -e "VMess链接（持久安装模式）\n"
      json_tls='{"add":"x.cf.090227.xyz","aid":"0","host":"'"$domain"'","id":"'"$uuid"'","net":"ws","path":"'"$urlpath"'","port":"2053","ps":"Installed-分流_TLS","tls":"tls","type":"none","v":"2"}'
      echo "vmess://$(b64enc "$json_tls")"
    } > /opt/suoha/v2ray.txt
  else
    {
      echo -e "VLESS链接（持久安装模式）\n"
      echo "vless://${uuid}@x.cf.090227.xyz:2053?encryption=none&security=tls&type=ws&host=${domain}&path=${urlpath}#Installed-分流_TLS"
    } > /opt/suoha/v2ray.txt
  fi

  echo "安装并绑定完成。v2ray 信息保存在 /opt/suoha/v2ray.txt"
  echo "管理命令示例：systemctl status cloudflared.service  systemctl status xray.service"
}

# ---------- 主菜单 ----------
echo "1. 启动服务（含YouTube和ChatGPT分流）"
echo "2. 安装服务 需要cloudflare域名重启不会失效！"
echo "3. 停止服务"
echo "4. 查看状态"
echo "5. 清理文件"
echo "0. 退出"
read -r -p "请选择(默认1): " mode
mode=${mode:-1}

case "$mode" in
  1)
    read -r -p "选择协议 (1.vmess 2.vless, 默认1): " protocol
    protocol=${protocol:-1}
    [ "$protocol" != "1" ] && [ "$protocol" != "2" ] && die "请输入1或2"
    
    read -r -p "IP版本 (4/6, 默认4): " ips
    ips=${ips:-4}
    [ "$ips" != "4" ] && [ "$ips" != "6" ] && die "请输入4或6"
    
    isp="$(curl -s -"${ips}" https://speed.cloudflare.com/meta 2>/dev/null | awk -F\" '{print $26"-"$18"-"$30}' | sed 's/ /_/g')"
    [ -z "$isp" ] && isp="unknown-$(date +%s)"

    stop_service
    start_service
    ;;
  2)
    # 调用安装流程（需要 root）
    install_service
    ;;
  3)
    stop_service
    ;;
  4)
    check_status
    ;;
  5)
    read -r -p "确定清理所有文件? (y/N) " confirm
    [ "$confirm" = "y" ] && cleanup || echo "取消清理"
    ;;
  0)
    echo "退出成功"; exit 0;;
  *)
    echo "无效选择"; exit 1;;
esac

#!/bin/bash
# 无root权限版代理脚本（含“安装服务”选项 + 若缺 config 自动生成分流配置）
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
  # 使用 pkill -f 更简单，兼容性较好
  pkill -9 -f "$pat" >/dev/null 2>&1 || true
}

# ---------- 可配置项（按需修改） ----------
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
need_cmd sed
need_cmd crontab || true  # crontab 不是必须，但若存在则可用

# ---------- 启动（临时）服务（quick / 梭哈 模式） ----------
start_service() {
  # 清理旧文件
  rm -rf "$SUOHA_DIR/xray" "$SUOHA_DIR/cloudflared" "$SUOHA_DIR/xray.zip" "$SUOHA_DIR/argo.log"

  # 下载对应架构的程序
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

  # 解压并授权
  mkdir -p "$SUOHA_DIR/xray"
  unzip -q -d "$SUOHA_DIR/xray" "$SUOHA_DIR/xray.zip" || die "解压Xray失败"
  chmod +x "$SUOHA_DIR/cloudflared" "$SUOHA_DIR/xray/xray"
  rm -f "$SUOHA_DIR/xray.zip"

  # 生成随机配置
  uuid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "uuid-$(date +%s)")"
  urlpath="$(echo "$uuid" | awk -F- '{print $1}')"
  port=$((RANDOM % 10000 + 20000))  # 非root端口

  # 生成Xray配置（修复语法错误：确保EOF单独成行且无缩进）
  if [ "$protocol" = "1" ]; then
cat > "$SUOHA_DIR/xray/config.json" <<EOF
{
  "inbounds": [{
    "port": $port,
    "listen": "localhost",
    "protocol": "vmess",
    "settings": { "clients": [{ "id": "$uuid", "alterId": 0 }] },
    "streamSettings": { "network": "ws", "wsSettings": { "path": "$urlpath" } }
  }],
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
  elif [ "$protocol" = "2" ]; then
cat > "$SUOHA_DIR/xray/config.json" <<EOF
{
  "inbounds": [{
    "port": $port,
    "listen": "localhost",
    "protocol": "vless",
    "settings": { "decryption": "none", "clients": [{ "id": "$uuid" }] },
    "streamSettings": { "network": "ws", "wsSettings": { "path": "$urlpath" } }
  }],
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
    die "未知协议（请输入1或2）"
  fi

  # 启动服务（临时）
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
      "$SUOHA_DIR/xray/xray" run -config "$SUOHA_DIR/xray/config.json" > "$SUOHA_DIR/xray.log" 2>&1 &
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

  # 生成代理链接
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

# ---------- 安装为长期服务（无需 root）（含自动生成 config.json 的逻辑） ----------
install_service() {
  echo "开始安装为长期服务（非 root 模式）..."
  mkdir -p "$SUOHA_DIR" || die "无法创建目录 $SUOHA_DIR"

  # --- 自动生成 config.json（如果缺失） ---
  if [ ! -f "$SUOHA_DIR/xray/config.json" ]; then
    echo "未检测到现成的 xray/config.json，自动生成带 YouTube/OpenAI 分流的配置..."
    mkdir -p "$SUOHA_DIR/xray"
    uuid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "uuid-$(date +%s)")"
    urlpath="$(echo "$uuid" | awk -F- '{print $1}')"
    port=$((RANDOM % 10000 + 20000))
    if [ "$protocol" = "1" ]; then
cat > "$SUOHA_DIR/xray/config.json" <<EOF
{
  "inbounds": [{
    "port": $port,
    "listen": "localhost",
    "protocol": "vmess",
    "settings": { "clients": [{ "id": "$uuid", "alterId": 0 }] },
    "streamSettings": { "network": "ws", "wsSettings": { "path": "$urlpath" } }
  }],
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
          "youtube.com","googlevideo.com","ytimg.com","gstatic.com",
          "googleapis.com","ggpht.com","googleusercontent.com"
        ],
        "outboundTag": "proxy"
      },
      {
        "type": "field",
        "domain": [
          "openai.com","chat.openai.com","api.openai.com",
          "auth0.openai.com","cdn.openai.com","oaiusercontent.com"
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
  "inbounds": [{
    "port": $port,
    "listen": "localhost",
    "protocol": "vless",
    "settings": { "decryption": "none", "clients": [{ "id": "$uuid" }] },
    "streamSettings": { "network": "ws", "wsSettings": { "path": "$urlpath" } }
  }],
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
          "youtube.com","googlevideo.com","ytimg.com","gstatic.com",
          "googleapis.com","ggpht.com","googleusercontent.com"
        ],
        "outboundTag": "proxy"
      },
      {
        "type": "field",
        "domain": [
          "openai.com","chat.openai.com","api.openai.com",
          "auth0.openai.com","cdn.openai.com","oaiusercontent.com"
        ],
        "outboundTag": "proxy"
      }
    ]
  }
}
EOF
    fi
    echo "已生成： $SUOHA_DIR/xray/config.json（端口 $port，path $urlpath）"
  fi
  # --- 自动生成结束 ---

  # 确保 cloudflared 与 xray 二进制存在
  if [ ! -x "$SUOHA_DIR/cloudflared" ] || [ ! -x "$SUOHA_DIR/xray/xray" ]; then
    echo "缺少可执行文件，先下载二进制..."
    start_service_download_only
  fi

  # 提示并登录 cloudflared（会输出一个 URL，需要你在浏览器打开并完成授权）
  echo
  echo "---- Cloudflared 登录 ----"
  echo "接下来将运行： cloudflared tunnel login"
  echo "该命令会在终端输出一个授权 URL（或自动打开浏览器）。"
  echo "请在本地浏览器打开该 URL 并完成登录授权，然后返回此终端继续。"
  echo "如果你在远端 SSH，请复制终端输出的 URL 到本地浏览器打开。"
  echo

  # 运行 login 并捕获输出（会把输出写入登录日志）
  "$SUOHA_DIR/cloudflared" tunnel login --no-autoupdate --edge-ip-version "$ips" --protocol http2 2>&1 | tee "$SUOHA_DIR/cloudflared_login.log"
  echo
  echo "如果你已经在浏览器完成授权，请按回车继续..."
  read -r

  # 列出已有 tunnel
  "$SUOHA_DIR/cloudflared" tunnel list > "$SUOHA_DIR/argo_list.log" 2>&1
  echo -e "\n当前已有的 TUNNEL 列表："
  sed -n '1,200p' "$SUOHA_DIR/argo_list.log" || true
  echo

  # 询问绑定域名
  read -r -p "请输入要绑定的完整二级域名（例如 sub.example.com）： " domain
  if [ -z "$domain" ]; then
    echo "未输入域名，安装取消"; return 1
  fi
  if [ $(echo "$domain" | grep "\." | wc -l) -eq 0 ]; then
    echo "域名格式不正确"; return 1
  fi

  name="$(echo "$domain" | awk -F. '{print $1}')"
  # 创建或复用 tunnel
  if [ $("$SUOHA_DIR/cloudflared" tunnel list 2>/dev/null | awk '{print $2}' | grep -w "$name" | wc -l) -eq 0 ]; then
    echo "创建 Tunnel: $name"
    "$SUOHA_DIR/cloudflared" tunnel create "$name" > "$SUOHA_DIR/argo_create.log" 2>&1
    echo "Tunnel 创建完成。"
  else
    echo "Tunnel $name 已存在，尝试复用。"
  fi

  # 获取 tunnel UUID（凭据文件名）
  tunneluuid="$("$SUOHA_DIR/cloudflared" tunnel list 2>/dev/null | awk '{print $1" "$2}' | grep -w "$name" | awk '{print $1}')"
  if [ -z "$tunneluuid" ]; then
    tunneluuid="$(grep -oE '[0-9a-f-]{36}' "$SUOHA_DIR/argo_create.log" | head -n1 || true)"
  fi
  if [ -z "$tunneluuid" ]; then
    echo "无法确定 tunnel UUID，请检查 $SUOHA_DIR/argo_create.log 与 $SUOHA_DIR/argo_list.log"; return 1
  fi

  # 路由 DNS
  echo "将 Tunnel $name 绑定到域名 $domain ..."
  "$SUOHA_DIR/cloudflared" tunnel route dns "$name" "$domain" --overwrite-dns > "$SUOHA_DIR/argo_route.log" 2>&1 || true
  echo "绑定完成（如无错误）。"

  # 写入 config.yaml（cloudflared）
  credsfile="$HOME/.cloudflared/${tunneluuid}.json"
  cat > "$SUOHA_DIR/config.yaml" <<EOF
tunnel: $tunneluuid
credentials-file: $credsfile

ingress:
  - hostname: $domain
    service: http://localhost:$port
  - service: http_status:404
EOF

  echo "配置文件已写入： $SUOHA_DIR/config.yaml"
  echo "凭据文件（cloudflared）应位于： $credsfile"
  echo

  # 尝试使用 systemd --user 启动（优先）
  if command -v systemctl >/dev/null 2>&1 && systemctl --user >/dev/null 2>&1; then
    echo "尝试安装并启用 systemd --user 服务..."
    mkdir -p "$HOME/.config/systemd/user"
    cat > "$HOME/.config/systemd/user/cloudflared-suoha.service" <<EOF
[Unit]
Description=Cloudflared Tunnel (suoha)
After=network-online.target

[Service]
ExecStart=$SUOHA_DIR/cloudflared tunnel --config $SUOHA_DIR/config.yaml run $name
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=default.target
EOF

    cat > "$HOME/.config/systemd/user/xray-suoha.service" <<EOF
[Unit]
Description=Xray (suoha)
After=network-online.target

[Service]
ExecStart=$SUOHA_DIR/xray/xray run -config $SUOHA_DIR/xray/config.json
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user enable --now cloudflared-suoha.service xray-suoha.service 2>/dev/null || true

    echo "尝试启动 systemd --user 服务..."
    systemctl --user start cloudflared-suoha.service 2>/dev/null || true
    systemctl --user start xray-suoha.service 2>/dev/null || true

    # 检查状态
    sleep 1
    systemctl --user status cloudflared-suoha.service --no-pager || true
    systemctl --user status xray-suoha.service --no-pager || true

    echo "如果 systemd --user 已启用，上述服务应已启动并设置为随用户会话自动启动。"
    return 0
  else
    echo "systemd --user 不可用，退回到 nohup+crontab 启动方案。"
    # 生成 run.sh
    cat > "$SUOHA_DIR/run.sh" <<EOF
#!/bin/bash
# 启动 suoha cloudflared & xray（由 crontab @reboot 调用）
cd "$SUOHA_DIR"
# 启动 xray（确保不重复）
pkill -f "$SUOHA_DIR/xray/xray" >/dev/null 2>&1 || true
nohup "$SUOHA_DIR/xray/xray" run -config "$SUOHA_DIR/xray/config.json" > "$SUOHA_DIR/xray.log" 2>&1 &
sleep 1
# 启动 cloudflared
pkill -f "$SUOHA_DIR/cloudflared" >/dev/null 2>&1 || true
nohup "$SUOHA_DIR/cloudflared" tunnel --config "$SUOHA_DIR/config.yaml" run $name > "$SUOHA_DIR/argo.log" 2>&1 &
EOF
    chmod +x "$SUOHA_DIR/run.sh"
    # 添加 crontab @reboot（如果没有的话）
    ( crontab -l 2>/dev/null | grep -v -F "$SUOHA_DIR/run.sh" || true ; echo "@reboot $SUOHA_DIR/run.sh >/dev/null 2>&1" ) | crontab -
    echo "已生成 $SUOHA_DIR/run.sh 并添加到 crontab @reboot。"
    echo "你可以现在手动执行： $SUOHA_DIR/run.sh 来启动服务，或重启后自动启动。"
    return 0
  fi
}

# ---------- 辅助：只下载二进制（供 install_service 使用） ----------
start_service_download_only() {
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
  esac
  mkdir -p "$SUOHA_DIR/xray"
  unzip -q -d "$SUOHA_DIR/xray" "$SUOHA_DIR/xray.zip" || die "解压Xray失败"
  chmod +x "$SUOHA_DIR/cloudflared" "$SUOHA_DIR/xray/xray"
  rm -f "$SUOHA_DIR/xray.zip"
}

# 停止服务
stop_service() {
  kill_proc_safe "$SUOHA_DIR/cloudflared" "$IS_ALPINE"
  kill_proc_safe "$SUOHA_DIR/xray/xray" "$IS_ALPINE"
  echo "服务已停止"
}

# 查看状态
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

# 清理文件
cleanup() {
  stop_service
  rm -rf "$SUOHA_DIR"
  echo "已清理所有文件"
}

# ---------- 主菜单 ----------
echo "1. 启动服务（含YouTube和ChatGPT分流）"
echo "2. 安装服务 需要cloudflare域名 重启不会失效！"
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
    # 安装为长期服务（非 root）
    read -r -p "选择协议 (1.vmess 2.vless, 默认1): " protocol
    protocol=${protocol:-1}
    [ "$protocol" != "1" ] && [ "$protocol" != "2" ] && die "请输入1或2"

    read -r -p "IP版本 (4/6, 默认4): " ips
    ips=${ips:-4}
    [ "$ips" != "4" ] && [ "$ips" != "6" ] && die "请输入4或6"

    isp="$(curl -s -"${ips}" https://speed.cloudflare.com/meta 2>/dev/null | awk -F\" '{print $26"-"$18"-"$30}' | sed 's/ /_/g')"
    [ -z "$isp" ] && isp="unknown-$(date +%s)"

    # 若缺少二进制则下载
    start_service_download_only
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

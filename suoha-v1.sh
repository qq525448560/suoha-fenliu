#!/bin/bash
# suoha — 无 root 长期/临时节点安装脚本（菜单2会强制执行 cloudflared tunnel login 并显示 dash.cloudflare.com/argotunnel URL）
set -e

# ---------- 基础函数 ----------
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
    alpine) IS_ALPINE=1 ;;
    *) IS_ALPINE=0 ;;
  esac
}

kill_proc_safe() {
  pkill -9 -f "$1" >/dev/null 2>&1 || true
}

# ---------- 配置（可修改） ----------
PROXY_OUT_IP="172.233.171.224"
PROXY_OUT_PORT=16416
PROXY_OUT_ID="8c1b9bea-cb51-43bb-a65c-0af31bbbf145"

SUOHA_DIR="$HOME/.suoha"
mkdir -p "$SUOHA_DIR" || die "无法创建目录 $SUOHA_DIR"

# ---------- 初始化检查 ----------
detect_os
need_cmd curl
need_cmd unzip
need_cmd awk
need_cmd grep
need_cmd tr
need_cmd ps
need_cmd kill
need_cmd sed
# crontab 不是必须，但若存在可用
command -v crontab >/dev/null 2>&1 || true

# ---------- 启动（临时）服务 ----------
start_service() {
  rm -rf "$SUOHA_DIR/xray" "$SUOHA_DIR/cloudflared" "$SUOHA_DIR/xray.zip" "$SUOHA_DIR/argo.log"

  arch="$(uname -m)"
  case "$arch" in
    x86_64|x64|amd64)
      curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o "$SUOHA_DIR/xray.zip" || die "下载Xray失败"
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o "$SUOHA_DIR/cloudflared" || die "下载cloudflared失败"
      ;;
    i386|i686)
      curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-32.zip -o "$SUOHA_DIR/xray.zip" || die "下载Xray失败"
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386 -o "$SUOHA_DIR/cloudflared" || die "下载cloudflared失败"
      ;;
    armv8|arm64|aarch64)
      curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip -o "$SUOHA_DIR/xray.zip" || die "下载Xray失败"
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -o "$SUOHA_DIR/cloudflared" || die "下载cloudflared失败"
      ;;
    armv7l)
      curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm32-v7a.zip -o "$SUOHA_DIR/xray.zip" || die "下载Xray失败"
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm -o "$SUOHA_DIR/cloudflared" || die "下载cloudflared失败"
      ;;
    *)
      echo "不支持的架构: $(uname -m)"; exit 1
      ;;
  esac

  mkdir -p "$SUOHA_DIR/xray"
  unzip -q -d "$SUOHA_DIR/xray" "$SUOHA_DIR/xray.zip" || die "解压Xray失败"
  chmod +x "$SUOHA_DIR/cloudflared" "$SUOHA_DIR/xray/xray"
  rm -f "$SUOHA_DIR/xray.zip"

  # 随机参数
  uuid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "uuid-$(date +%s)")"
  urlpath="$(echo "$uuid" | awk -F- '{print $1}')"
  port=$((RANDOM % 10000 + 20000))

  # 生成 config.json（含分流）
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

  # 启动 xray & cloudflared 临时 tunnel（生成 trycloudflare 地址）
  nohup "$SUOHA_DIR/xray/xray" run -config "$SUOHA_DIR/xray/config.json" >"$SUOHA_DIR/xray.log" 2>&1 &
  nohup "$SUOHA_DIR/cloudflared" tunnel --url "http://localhost:$port" --no-autoupdate --edge-ip-version "$ips" --protocol http2 >"$SUOHA_DIR/argo.log" 2>&1 &
  sleep 1

  # 等待 trycloudflare 地址生成
  n=0
  while :; do
    n=$((n+1))
    clear
    echo "等待 Cloudflare Argo 生成 trycloudflare 地址（第 $n 秒）..."
    argo_url="$(grep -oE 'https://[a-zA-Z0-9.-]+trycloudflare\.com' "$SUOHA_DIR/argo.log" 2>/dev/null | tail -n1 || true)"
    if [ -n "$argo_url" ]; then
      break
    fi
    if [ $n -ge 30 ]; then
      echo "未检测到 trycloudflare 地址，重启 cloudflared 重试..."
      kill_proc_safe "$SUOHA_DIR/cloudflared"
      nohup "$SUOHA_DIR/cloudflared" tunnel --url "http://localhost:$port" --no-autoupdate --edge-ip-version "$ips" --protocol http2 >"$SUOHA_DIR/argo.log" 2>&1 &
      n=0
    fi
    sleep 1
  done

  argo_host="${argo_url#https://}"
  # 生成客户端链接并保存
  if [ "$protocol" = "1" ]; then
    {
      echo -e "VMess 链接（含 YouTube / ChatGPT 分流）\n"
      json_tls='{"add":"x.cf.090227.xyz","aid":"0","host":"'"$argo_host"'","id":"'"$uuid"'","net":"ws","path":"'"$urlpath"'","port":"2053","ps":"X-分流_TLS","tls":"tls","type":"none","v":"2"}'
      echo "vmess://$(b64enc "$json_tls")"
      echo -e "\nTLS 端口: 2053/2083/2087/2096/8443\n"
      json_nontls='{"add":"x.cf.090227.xyz","aid":"0","host":"'"$argo_host"'","id":"'"$uuid"'","net":"ws","path":"'"$urlpath"'","port":"2052","ps":"X-分流","tls":"","type":"none","v":"2"}'
      echo "vmess://$(b64enc "$json_nontls")"
      echo -e "\n非 TLS 端口: 2052/2082/2086/2095/8080/8880"
    } > "$SUOHA_DIR/v2ray.txt"
  else
    {
      echo -e "VLESS 链接（含 YouTube / ChatGPT 分流）\n"
      echo "vless://${uuid}@x.cf.090227.xyz:2053?encryption=none&security=tls&type=ws&host=${argo_host}&path=${urlpath}#X-分流_TLS"
      echo -e "\nTLS 端口: 2053/2083/2087/2096/8443\n"
      echo "vless://${uuid}@x.cf.090227.xyz:2052?encryption=none&security=none&type=ws&host=${argo_host}&path=${urlpath}#X-分流"
      echo -e "\n非 TLS 端口: 2052/2082/2086/2095/8080/8880"
    } > "$SUOHA_DIR/v2ray.txt"
  fi

  cat "$SUOHA_DIR/v2ray.txt"
  echo -e "\n保存于： $SUOHA_DIR/v2ray.txt"
  echo "若需长期运行请使用菜单 2 安装为服务并绑定你的 Cloudflare 域名。"
}

# ---------- 辅助：下载二进制（install 使用） ----------
start_service_download_only() {
  arch="$(uname -m)"
  case "$arch" in
    x86_64|x64|amd64)
      curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o "$SUOHA_DIR/xray.zip" || die "下载Xray失败"
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o "$SUOHA_DIR/cloudflared" || die "下载cloudflared失败"
      ;;
    i386|i686)
      curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-32.zip -o "$SUOHA_DIR/xray.zip" || die "下载Xray失败"
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386 -o "$SUOHA_DIR/cloudflared" || die "下载cloudflared失败"
      ;;
    armv8|arm64|aarch64)
      curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip -o "$SUOHA_DIR/xray.zip" || die "下载Xray失败"
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -o "$SUOHA_DIR/cloudflared" || die "下载cloudflared失败"
      ;;
    armv7l)
      curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm32-v7a.zip -o "$SUOHA_DIR/xray.zip" || die "下载Xray失败"
      curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm -o "$SUOHA_DIR/cloudflared" || die "下载cloudflared失败"
      ;;
    *)
      die "不支持的架构: $(uname -m)"
      ;;
  esac
  mkdir -p "$SUOHA_DIR/xray"
  unzip -q -d "$SUOHA_DIR/xray" "$SUOHA_DIR/xray.zip" || die "解压Xray失败"
  chmod +x "$SUOHA_DIR/cloudflared" "$SUOHA_DIR/xray/xray"
  rm -f "$SUOHA_DIR/xray.zip"
}

# ---------- 安装为长期服务（含自动生成 config.json） ----------
install_service() {
  echo "开始安装为长期服务（非 root）..."
  mkdir -p "$SUOHA_DIR"

  # 若缺少 config.json 则自动生成（含 YouTube / OpenAI 分流）
  if [ ! -f "$SUOHA_DIR/xray/config.json" ]; then
    echo "未检测到 xray/config.json，自动生成带分流的配置..."
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

  # 确保二进制存在
  if [ ! -x "$SUOHA_DIR/cloudflared" ] || [ ! -x "$SUOHA_DIR/xray/xray" ]; then
    echo "缺少可执行文件，正在下载..."
    start_service_download_only
  fi

  # 强制执行 cloudflared tunnel login，并把 argotunnel URL 抽取并显式输出
  echo
  echo "=== Cloudflared 登录（请在浏览器中打开下面的 URL 并完成授权） ==="
  echo "如果你在远程 SSH，请复制下方 URL 到本地浏览器打开。"
  echo

  # 运行 login 并记录输出
  LOGIN_LOG="$SUOHA_DIR/cloudflared_login.log"
  # 可能 cloudflared 会尝试自动打开浏览器；这里把输出写到文件并也实时打印
  "$SUOHA_DIR/cloudflared" tunnel login --no-autoupdate --edge-ip-version "$ips" --protocol http2 2>&1 | tee "$LOGIN_LOG" || true

  # 尝试从日志提取 argotunnel URL（多种可能的匹配）
  arg_url="$(grep -oE 'https://dash.cloudflare.com/argotunnel\\?[^ ]+' "$LOGIN_LOG" 2>/dev/null | head -n1 || true)"
  if [ -z "$arg_url" ]; then
    # 兼容少数 cloudflared 版本输出格式（callback 编码）
    arg_url="$(grep -oE 'https://dash.cloudflare.com/argotunnel[^ ]+' "$LOGIN_LOG" 2>/dev/null | head -n1 || true)"
  fi

  if [ -n "$arg_url" ]; then
    echo
    echo "请在浏览器打开并登录 Cloudflare（下面 URL）："
    echo
    echo "$arg_url"
    echo
    echo "在浏览器中授权成功后，回到此终端并按回车继续。"
    read -r
  else
    echo
    echo "脚本未从 cloudflared 输出中直接检测到 argotunnel URL。"
    echo "请检查登录日志： $LOGIN_LOG"
    echo "如果 cloudflared 已自动打开浏览器，请在浏览器完成授权。"
    echo "按回车继续（脚本将尝试列出已有 tunnel 并让你继续绑定域名）。"
    read -r
  fi

  # 列出 tunnel（供参考）
  "$SUOHA_DIR/cloudflared" tunnel list > "$SUOHA_DIR/argo_list.log" 2>&1 || true
  echo -e "\n当前已有的 TUNNEL（查看 $SUOHA_DIR/argo_list.log 了解详情）："
  sed -n '1,200p' "$SUOHA_DIR/argo_list.log" || true
  echo

  # 输入要绑定的域名
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
    "$SUOHA_DIR/cloudflared" tunnel create "$name" > "$SUOHA_DIR/argo_create.log" 2>&1 || true
    echo "Tunnel 创建完成（或已存在）。"
  else
    echo "Tunnel $name 已存在，尝试复用。"
  fi

  # 获取 tunnel UUID
  tunneluuid="$("$SUOHA_DIR/cloudflared" tunnel list 2>/dev/null | awk '{print $1" "$2}' | grep -w "$name" | awk '{print $1}')"
  if [ -z "$tunneluuid" ]; then
    tunneluuid="$(grep -oE '[0-9a-f-]{36}' "$SUOHA_DIR/argo_create.log" 2>/dev/null | head -n1 || true)"
  fi
  if [ -z "$tunneluuid" ]; then
    echo "无法确定 tunnel UUID，请检查日志： $SUOHA_DIR/argo_create.log 和 $SUOHA_DIR/argo_list.log"
    return 1
  fi

  # 绑定 DNS
  echo "将 Tunnel $name 绑定到域名 $domain ..."
  "$SUOHA_DIR/cloudflared" tunnel route dns "$name" "$domain" --overwrite-dns > "$SUOHA_DIR/argo_route.log" 2>&1 || true
  echo "绑定完成（如无错误）。"

  # 写入 config.yaml
  credsfile="$HOME/.cloudflared/${tunneluuid}.json"
  cat > "$SUOHA_DIR/config.yaml" <<EOF
tunnel: $tunneluuid
credentials-file: $credsfile

ingress:
  - hostname: $domain
    service: http://localhost:$port
  - service: http_status:404
EOF

  echo "已写入 $SUOHA_DIR/config.yaml"
  echo "凭据文件应位于： $credsfile"
  echo

  # 尝试 systemd --user 启动
  if command -v systemctl >/dev/null 2>&1 && systemctl --user >/dev/null 2>&1; then
    echo "尝试安装 systemd --user 服务..."
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
    systemctl --user start cloudflared-suoha.service 2>/dev/null || true
    systemctl --user start xray-suoha.service 2>/dev/null || true

    echo "systemd --user 服务已尝试启动（若你的系统支持）。"
    return 0
  else
    echo "systemd --user 不可用，生成 run.sh 并加入 crontab @reboot"
    cat > "$SUOHA_DIR/run.sh" <<EOF
#!/bin/bash
cd "$SUOHA_DIR"
pkill -f "$SUOHA_DIR/xray/xray" >/dev/null 2>&1 || true
nohup "$SUOHA_DIR/xray/xray" run -config "$SUOHA_DIR/xray/config.json" > "$SUOHA_DIR/xray.log" 2>&1 &
sleep 1
pkill -f "$SUOHA_DIR/cloudflared" >/dev/null 2>&1 || true
nohup "$SUOHA_DIR/cloudflared" tunnel --config "$SUOHA_DIR/config.yaml" run $name > "$SUOHA_DIR/argo.log" 2>&1 &
EOF
    chmod +x "$SUOHA_DIR/run.sh"
    ( crontab -l 2>/dev/null | grep -v -F "$SUOHA_DIR/run.sh" || true ; echo "@reboot $SUOHA_DIR/run.sh >/dev/null 2>&1" ) | crontab -
    echo "已添加 crontab @reboot。你也可以现在运行： $SUOHA_DIR/run.sh"
    return 0
  fi
}

# ---------- 停止/状态/清理 ----------
stop_service() {
  kill_proc_safe "$SUOHA_DIR/cloudflared"
  kill_proc_safe "$SUOHA_DIR/xray/xray"
  echo "服务已停止"
}

check_status() {
  [ $(ps -ef | grep -F "$SUOHA_DIR/cloudflared" | grep -v grep | wc -l) -gt 0 ] && echo "cloudflared: 运行中" || echo "cloudflared: 已停止"
  [ $(ps -ef | grep -F "$SUOHA_DIR/xray/xray" | grep -v grep | wc -l) -gt 0 ] && echo "xray: 运行中" || echo "xray: 已停止"
  [ -f "$SUOHA_DIR/v2ray.txt" ] && echo -e "\n当前链接:\n$(cat "$SUOHA_DIR/v2ray.txt")" || echo -e "\n未找到链接"
}

cleanup() {
  stop_service
  rm -rf "$SUOHA_DIR"
  echo "已清理所有文件"
}

# ---------- 主菜单 ----------
echo "1. 启动服务（含 YouTube/ChatGPT 分流；临时 trycloudflare 地址，重启会失效）"
echo "2. 安装服务（需要 Cloudflare 域名，重启不会失效；会执行 cloudflared tunnel login 并显示登录 URL）"
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
    read -r -p "IP 版本 (4/6, 默认4): " ips
    ips=${ips:-4}
    [ "$ips" != "4" ] && [ "$ips" != "6" ] && die "请输入4或6"
    stop_service || true
    start_service
    ;;
  2)
    read -r -p "选择协议 (1.vmess 2.vless, 默认1): " protocol
    protocol=${protocol:-1}
    [ "$protocol" != "1" ] && [ "$protocol" != "2" ] && die "请输入1或2"
    read -r -p "IP 版本 (4/6, 默认4): " ips
    ips=${ips:-4}
    [ "$ips" != "4" ] && [ "$ips" != "6" ] && die "请输入4或6"
    # 下载二进制并安装服务（若需会自动生成 config.json）
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
    [ "$confirm" = "y" ] && cleanup || echo "取消"
    ;;
  0)
    echo "退出"; exit 0
    ;;
  *)
    echo "无效选择"; exit 1
    ;;
esac

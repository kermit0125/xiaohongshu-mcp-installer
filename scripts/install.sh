#!/usr/bin/env bash
# ============================================================
# xiaohongshu-mcp 自动安装脚本（幂等）v2
# 仓库: https://github.com/xpzouying/xiaohongshu-mcp
# 用法:
#   bash install.sh                   # 标准安装（幂等）
#   bash install.sh --register        # 安装后自动注册 LobeHub 自定义 MCP 插件（需 lh CLI）
#   bash install.sh --daemon          # macOS 下额外配置 launchd 自启
#   bash install.sh --force           # 强制重新下载二进制
#   bash install.sh --no-login        # 跳过登录（已有 cookies 时）
#   bash install.sh --check           # 只做健康检查
# 环境变量: XHS_INSTALL_DIR / XHS_MCP_PORT 可覆盖默认值
# ============================================================
set -euo pipefail

REPO="xpzouying/xiaohongshu-mcp"
INSTALL_DIR="${XHS_INSTALL_DIR:-$HOME/xiaohongshu-mcp}"
MCP_PORT="${XHS_MCP_PORT:-18060}"
MCP_URL="http://localhost:${MCP_PORT}/mcp"
PLUGIN_ID="xiaohongshu-mcp"
FORCE=0; NO_LOGIN=0; CHECK_ONLY=0; SETUP_DAEMON=0; REGISTER=0

for arg in "$@"; do
  case "$arg" in
    --force)    FORCE=1 ;;
    --no-login) NO_LOGIN=1 ;;
    --check)    CHECK_ONLY=1 ;;
    --daemon)   SETUP_DAEMON=1 ;;
    --register) REGISTER=1 ;;
    *) echo "未知参数: $arg"; exit 2 ;;
  esac
done

log()  { printf '\033[1;32m[xhs]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[xhs]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[xhs]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 1. 平台探测 ----------
detect_platform() {
  local os arch suffix
  case "$(uname -s)" in
    Darwin)              os="darwin" ;;
    Linux)               os="linux" ;;
    MINGW*|MSYS*|CYGWIN*) os="windows" ;;
    *) die "不支持的平台: $(uname -s)，请手动安装" ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) arch="arm64" ;;
    x86_64|amd64)  arch="amd64" ;;
    *) die "不支持的架构: $(uname -m)" ;;
  esac
  PLATFORM="${os}-${arch}"
  SUFFIX=""; [ "$os" = "windows" ] && SUFFIX=".exe"
  log "平台: ${PLATFORM}"
}

# ---------- 2. 健康检查（MCP initialize 握手） ----------
mcp_alive() {
  curl -fsS -X POST "$MCP_URL" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"initialize","params":{},"id":1}' \
    >/dev/null 2>&1
}

# ---------- 3. 下载二进制（幂等） ----------
download() {
  mkdir -p "$INSTALL_DIR"
  local tmp; tmp=$(mktemp)
  trap 'rm -f "$tmp"' RETURN
  log "获取最新版本信息…"
  curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" -o "$tmp"
  local tag
  tag=$(python3 -c "import sys,json;print(json.load(open('$tmp'))['tag_name'])")
  log "最新版本: ${tag}"

  local role asset_name target
  for role in mcp login; do
    asset_name=$(python3 -c "
import json
d = json.load(open('$tmp'))
platform = '${PLATFORM}'
role = '${role}'
for a in d.get('assets', []):
    if platform in a['name'] and role in a['name']:
        print(a['name']); break
")
    [ -n "$asset_name" ] || die "圠 ${tag} 中未找到 ${role} (${PLATFORM}) 资产，请检查 Releases 命名"
    target="$INSTALL_DIR/$asset_name"
    if [ -f "$target" ] && [ "$FORCE" -eq 0 ]; then
      log "已存在（跳过）: $asset_name"
    else
      log "下载: $asset_name"
      curl -fL --progress-bar -o "$target" \
        "https://github.com/${REPO}/releases/download/${tag}/${asset_name}"
      chmod +x "$target"
    fi
    if [ "$role" = "mcp" ]; then MCP_BIN="$asset_name"; else LOGIN_BIN="$asset_name"; fi
  done
  log "二进制就绪: $INSTALL_DIR"
}

# ---------- 4. 扫码登录（唯一人工环节） ----------
login() {
  if [ -f "$INSTALL_DIR/cookies.json" ]; then
    log "检测到 cookies.json（已登录）"
    return 0
  fi
  if [ "$NO_LOGIN" -eq 1 ]; then
    warn "--no-login 已指定，跳过登录"
    return 0
  fi
  log "启动登录工具，请在自动弹出的浏览器窗口中用小红书 App 扫码…"
  warn "二维码有效期约 4 分钟；首次运行会自动下载内置浏览器（约 150MB），请耐心等待"
  "$INSTALL_DIR/$LOGIN_BIN"
  [ -f "$INSTALL_DIR/cookies.json" ] || die "登录失败：未生成 cookies.json，请重新运行安装"
  log "登录成功 ✅"
}

# ---------- 5. 启动服务（后台 + 轮询验证） ----------
start_service() {
  if mcp_alive; then
    log "MCP 服务已在运行: $MCP_URL"
    return 0
  fi
  log "启动 MCP 服务（后台）…"
  nohup "$INSTALL_DIR/$MCP_BIN" >> "$INSTALL_DIR/server.log" 2>&1 &
  echo $! > "$INSTALL_DIR/server.pid"
  local i
  for i in $(seq 1 30); do
    mcp_alive && { log "服务启动成功 ✅ (pid $(cat "$INSTALL_DIR/server.pid"))"; return 0; }
    sleep 1
  done
  die "服务启动失败，请查看 $INSTALL_DIR/server.log"
}

# ---------- 6. macOS launchd 自启（可选） ----------
setup_daemon() {
  [ "$(uname -s)" = "Darwin" ] || { warn "--daemon 仅支持 macOS，跳过"; return 0; }
  local plist="$HOME/Library/LaunchAgents/com.xiaohongshu.mcp.plist"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.xiaohongshu.mcp</string>
  <key>ProgramArguments</key>
  <array><string>${INSTALL_DIR}/${MCP_BIN}</string></array>
  <key>WorkingDirectory</key><string>${INSTALL_DIR}</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${INSTALL_DIR}/server.log</string>
  <key>StandardErrorPath</key><string>${INSTALL_DIR}/server-error.log</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
  log "launchd 自启已配置 ✅"
}

# ---------- 7. 注册 LobeHub 自定义插件（需 lh CLI，幂等） ----------
register_plugin() {
  if ! command -v lh >/dev/null 2>&1; then
    warn "未找到 lh CLI，跳过插件注册"
    echo "请在 LobeHub UI 手动添加：设置 → MCP 插件 → 添加 MCP 服务 → ${MCP_URL}"
    return 0
  fi
  if lh plugin list --json 2>/dev/null | python3 -c "
import sys, json
try:
    plugins = json.load(sys.stdin)
except Exception:
    plugins = []
print(any(p.get('identifier') == '${PLUGIN_ID}' for p in plugins))
" | grep -q True; then
    log "插件已注册（跳过）: ${PLUGIN_ID}"
    return 0
  fi
  log "注册 LobeHub 自定义插件: ${PLUGIN_ID}"
  lh plugin create --identifier "${PLUGIN_ID}" --type customPlugin \
    --manifest "{\"name\":\"${PLUGIN_ID}\",\"type\":\"mcp\",\"server\":{\"url\":\"${MCP_URL}\"},\"identifier\":\"${PLUGIN_ID}\",\"description\":\"小红书 MCP 本地服务（自动安装）\"}"
  log "插件注册成功 ✅"
}

# ---------- main ----------
main() {
  detect_platform
  if [ "$CHECK_ONLY" -eq 1 ]; then
    if mcp_alive; then log "健康检查通过: $MCP_URL"; exit 0
    else die "健康检查失败: $MCP_URL 无响应"; fi
  fi
  download
  login
  start_service
  [ "$SETUP_DAEMON" -eq 1 ] && setup_daemon
  [ "$REGISTER" -eq 1 ] && register_plugin
  log "安装完成 🎉 端点: $MCP_URL"
  echo "可用工具验证：curl -X POST ${MCP_URL} -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"params\":{},\"id\":1}'"
}
main "$@"

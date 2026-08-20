---
name: xiaohongshu-mcp-installer
description: 在本地设备上自动安装并启动 xiaohongshu-mcp（小红书 MCP 服务）：平台探测、GitHub 下载二进制、扫码登录、后台启动、连通性验证，并通过 lh CLI 注册到 LobeHub 自定义插件。适用于首次初始化、重新部署、MCP 连接修复。分享给他人时，对方只需扫码一次即可使用。
---

# xiaohongshu-mcp 安装器（Installer Skill）

## 触发条件

- 用户说"初始化 / 安装 / 部署小红书 MCP"
- 小红书插件显示"未连接"，需要排查或重装
- 更换设备后需要重新搭建
- 素材采集 Agent 报"MCP 服务不可用"

## 执行流程

### Step 0 · Skill 自举（分享场景必读）

新环境里 Agent 可能还没有本 skill。先检查再安装：

1. `lh skill list --json` 检查是否已安装 `xiaohongshu-mcp-installer`
2. 未安装 → `lh skill install <仓库地址>`（如 `https://github.com/<owner>/xiaohongshu-mcp-installer`）
3. 安装完成后重新激活本 skill 继续执行

### Step 1 · 幂等检查（先做，别急着装）

1. 用 `runCommand` 检查是否已就绪：
   - 服务存活：`bash scripts/install.sh --check`（脚本内置 MCP initialize 握手验证）
   - 二进制：`ls ~/xiaohongshu-mcp/`
   - 登录态：`ls ~/xiaohongshu-mcp/cookies.json`
   - LobeHub 插件：`lh plugin list --json` 中查找 xiaohongshu-mcp
2. 全部就绪 → 直接汇报"已安装"，结束。部分就绪 → 只补缺失部分（脚本本身幂等）。

### Step 2 · 平台探测与下载

用 `execScript` 运行 `bash scripts/install.sh`（不带参数，幂等）。脚本自动：
- 探测 OS/架构，匹配 GitHub Releases 资产名（darwin-arm64 / darwin-amd64 / linux-amd64 / windows-amd64）
- 下载 mcp 主程序 + login 登录工具到 `~/xiaohongshu-mcp/`
- 已存在则跳过；`--force` 强制重下

### Step 3 · 扫码登录（唯一人工环节）

脚本会启动登录工具并弹出浏览器二维码。
**此时必须暂停并明确告知用户**：

> "请用手机小红书 App 扫码登录（二维码 4 分钟有效；首次运行会自动下载内置浏览器约 150MB，请耐心等待）"

- 登录成功 → 自动生成 `cookies.json`
- 失败/超时 → 重跑登录工具，或让用户手动执行 `~/xiaohongshu-mcp/xiaohongshu-login-<platform>`

⚠️ Cookie 是账号凭证，仅本机保存，不可分享、不可上传。

### Step 4 · 启动服务并验证

脚本后台启动服务并轮询验证 `/mcp` initialize 握手（脚本已内置，也可手动执行 `bash scripts/install.sh --check`）。

### Step 5 · 注册 LobeHub 插件（已实测可全自动）

运行 `bash scripts/install.sh --register`，脚本会自动：
1. 检查 `lh` CLI 是否存在；不存在 → 引导 UI（设置 → MCP 插件 → 添加 MCP 服务）
2. `lh plugin list --json` 查重，已注册则跳过
3. 执行注册（命令示例，含 manifest JSON）：
   ```bash
   lh plugin create --identifier xiaohongshu-mcp --type customPlugin --manifest '{...}'
   ```
4. 验证：`lh plugin list --json` 中出现 xiaohongshu-mcp

若插件已存在，检查它是否已启用（插件默认启用）。

### Step 6 · 汇报

输出：安装目录、MCP 端点、登录状态、插件注册状态、可用工具数（预期 18 个）。

## 常用子命令

| 场景 | 命令 |
|---|---|
| 完整安装 + 注册插件 | `bash scripts/install.sh --register` |
| macOS 开机自启（叠加） | `bash scripts/install.sh --register --daemon` |
| 只做健康检查 | `bash scripts/install.sh --check` |
| 强制重装二进制 | `bash scripts/install.sh --force` |
| 跳过登录（已有 cookie） | `bash scripts/install.sh --no-login` |

## 边界与注意事项

1. **登录不可全自动**：扫码是小红书账号安全机制，无法绕过；新设备/新账号必须人工扫一次���(()？
2. **登录态互斥**：同一账号网页端与 MCP 互踢，提示用户用手机 App 查看账号
3. **平台**：POSIX 脚本支持 macOS/Linux；Windows 建议 Git Bash/WSL，或引导手动安装（双击 exe）
4. **风控**：仅采集分析用途；单账号每日发布 ≤50；不做批量/引流
5. **错误排查**：403 → cookie 过期需重登；端口占用 → 设置 `XHS_MCP_PORT` 换端口；服务起不来 → 查看 `~/xiaohongshu-mcp/server.log`
6. **分享合规**：Cookie 是账号凭证，禁止共享；朋友必须用自己的账号扫码

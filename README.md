# Hermes Agent Portable Builder

此目录是本机 Portable 构建系统，不是官方 Git 仓库的一部分；官方源码只存放在 `upstream\` 子目录中。

本构建器将 [Hermes Agent](https://github.com/NousResearch/hermes-agent) 打包成免安装、可移动的 Windows x64 便携版：内嵌 Python + venv 依赖、Node.js、PortableGit、Electron 桌面端，用户数据通过 `HERMES_HOME` 等重定向到包内 `data\hermes-home\`，整包可复制、移动。

## 目录职责

```
Hermes-Agent-Portable-Builder\
├── README.md                        # 本说明文档（构建器用法）
├── builder\                         # 本地构建器实现；只在构建机使用
│   ├── source\                      # 构建脚本（入口 Hermes.ps1）、启动器/更新器 C# 源码、README 模板、入口脚本
│   ├── scripts\                     # 随包发布的维护脚本（Update-Portable.ps1 / Repair-Portable.ps1 / Verify-Portable.ps1），与成品 scripts\ byte-identical
│   ├── assets\                      # 离线缓存（7zip、git、node、uv、python、npm-cache、electron-cache、electron-builder-cache），缺失时联网下载并回填
│   ├── data\                        # 随包预置内容，构建时复制进成品 data\（hermes-home\memories、hermes-home\skills 等）
│   └── logs\                        # 构建日志
├── upstream\                        # 只读镜像：NousResearch 官方 Hermes 源码；可同步/重置到 origin/main
├── stage\                           # 组装后的未压缩 Portable 目录（Hermes-Agent-Portable\）
└── dist\                            # 最终 ZIP（Hermes-Agent-Portable-<版本>-win-x64-<时间戳>.zip）
```

## 构建机要求

当前只支持 Windows 10/11 x64。构建机需要：

| 软件 | 版本要求 | 是否必须预装 | 说明 |
|---|---|---:|---|
| Windows PowerShell | 5.1（Windows 自带） | 是 | 构建入口及维护脚本运行环境 |
| Git for Windows | 当前固定 2.55.0.3（`v2.55.0.windows.3`，构建脚本硬编码） | 否 | 构建器不读取系统；从 `builder\assets\git\PortableGit\`（解压后的目录缓存）取进成品，缓存缺失才下载、解压并回填 |
| Node.js + npm | 上游选择器 22；当前缓存 v22.23.2（npm 11.19.0） | 是（编译用） | 编译 Desktop、TUI 和运行 electron-builder 需要构建机上的 npm；打包进成品的 Node 运行时不读取系统，从 `builder\assets\node\node-v22.23.2-win-x64\`（解压后的目录缓存）取，缺失才从 nodejs.org 下载、解压并回填 |
| uv | 构建器用固定 0.12.3 | 否 | 构建器不读取系统；从 `builder\assets\uv\uv-x86_64-pc-windows-msvc\`（解压后的目录缓存）取，缺失才下载、解压并回填 |
| Python | 当前上游选择器为 3.11；patch 版本不锁定 | 否 | 构建器不读取系统；从 `builder\assets\python\` 的解压目录取，缺失才由 uv 安装（下载后回填 assets 缓存） |
| .NET Framework C# 编译器 | v4.0（Windows 10/11 自带） | 是（系统组件） | 使用 `Framework64\v4.0.30319\csc.exe` 编译 `Hermes.exe` 和 `Update.exe` |
| 7za.exe（7-Zip 命令行版） | 随仓库内置 `builder\assets\7zip\7za.exe`（当前 26.02） | 否 | 通常随仓库自带；缺失时自动从 7-Zip 官网下载 extra 包恢复（下载后回填 assets 缓存） |

版本规则：Git 固定 2.55.0.3（构建脚本硬编码，升级需改 `$gitTag`/`$gitVer`）；Node 跟随上游选择器主版本 22，缓存里的具体 patch 版本随上游 `NodeVersion` 更新而变；uv 固定 0.12.3；Python 跟随上游选择器 3.11。上游以后修改 `PythonVersion`、`NodeVersion` 或 `package.json` 的 `engines.npm` 时，构建器会读取新要求并自动适配（包内 npm 不足时自动升级；npm 升级命令会清掉官方捆绑的 corepack，因此脚本在升级前读取官方捆绑的 corepack 版本、升级后按该版本重装，版本始终跟随 Node zip，无硬编码）。用户端更新脚本（`Update-Portable.ps1 -Stage SyncDesktop`）同样会在 TUI 重建前检查并升级包内 npm（同样先读版本后重装 corepack），因此官方提升 npm 要求不会卡住老部署的更新。`Verify-Portable.ps1` 对成品 Node 的 corepack 本体与 shim 设有存在性门禁，构建后自动检查，缺失即构建失败。

## 构建

只组装 Portable 目录、跳过 ZIP 打包（压缩 32,000+ 个文件约需数分钟）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  D:\Hermes-Agent-Portable-Builder\builder\source\Hermes.ps1 `
  -SkipArchive
```

输出：`D:\Hermes-Agent-Portable-Builder\stage\Hermes-Agent-Portable`

完整构建（产出 `dist\` 下的 ZIP）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  D:\Hermes-Agent-Portable-Builder\builder\source\Hermes.ps1
```

输出：`D:\Hermes-Agent-Portable-Builder\dist\Hermes-Agent-Portable-<版本>-win-x64-<时间戳>.zip`

构建始终是完整流程，没有跳过 Desktop 重建的开关（曾有的 `-SkipDesktopBuild` 已于 2026-08-07 移除，因为它会让 Python 解析走不同路径、掩盖构建脚本缺陷；以后排查问题时只有一条构建路径可循）。

构建流程（约 10-30 分钟，视缓存与网络）：

1. 校验 Windows x64；校验/克隆官方源码到 `upstream\`（缺失或失败自动克隆，3 次重试）
2. 清空并重建 `stage\Hermes-Agent-Portable`
3. 解析托管组件（own assets 缓存优先 → 缺失下载并回填缓存）：uv 固定 0.12.3 → 官方选择器 Python（当前 3.11）→ 官方选择器 Node（主版本 22）→ PortableGit 固定 2.55.0.3
4. 创建可重定位 venv：`uv sync --extra all --locked --no-install-project --link-mode copy`（wheel 走 uv 构建机用户级缓存，离线优先、缺失才下载；不生成含构建绝对路径的 editable metadata）
5. 按官方 `engines.npm` 要求升级包内 npm（不足时自动升级，升级后按官方捆绑版本重装 corepack）
6. 对官方 Desktop 源码打便携补丁（`Update-Portable.ps1 -Stage Patch`）→ npm workspace 安装 + typecheck + build + electron-builder `--dir` → 立即 `-Stage PatchRemove` 还原（源码与官方逐字节一致）
7. 网页端 workspace 安装 + `npm run build`（vite 输出到 `hermes_cli\web_dist\`），最后写入 `data\hermes-home\web-ui-build-stamp.json`（内容哈希）
8. 编译 `Hermes.exe`（winexe + 官方图标）与 `Update.exe`（csc）→ 部署入口脚本（hermes-cli/tui/dashboard .cmd）→ 注入 README 版本号（dsh/commit/node/git/uv）
9. 组装内嵌 git 配置（longpaths + autocrlf false + eol lf）→ reset/clean → 干净性检查（`status --porcelain` 与 `stash list` 必须为空）
10. 契约门禁：`Test-PortablePythonContract`（PortablePythonBootstrap / ExternalOverlayPackaged / RuntimeToolsUnique / BuildOnlyFilesPackaged / EmbeddedCheckoutIsOfficialOnly）+ `Test-PortableNoEditableInstall`（拒绝 `__editable__*`/`.egg-link`/`.pth` 绝对路径）+ `Verify-Portable.ps1`（McpImports: mcp-ok、WebDist 等）
11. 浅克隆内嵌 `.git`（`Convert-PackagedGitToShallow`：离线 `fetch --depth 1` + 清 origin 分支 refs/tags + `gc --prune=now`，完整历史 737MB → 深度 1 约 69MB；官方 `hermes update` 支持浅仓库更新（端到端已验证 2026-08-23：真实网络 `--check` 的 fetch 带 `--depth 1` 保持浅边界；本地 fixture 触发完整 update，`merge --ff-only`（update_cmd.py:6212-6213）快进新 commit 后 shallow 边界文件不变、.git 69M 不膨胀、status 干净、安装健康；fetch 的 `--depth 1` 依据 update_cmd.py:3196-3205/3225/3237））→ 打包 checkout `git rm --cached` + `reset --hard`（行尾 LF 规范化）→ 写 Desktop/Web 构建 stamp（增量判断依据）。注意：`Hermes.ps1` 必须保持 **UTF-8 with BOM** 编码——PowerShell 5.1 对无 BOM 文件按 GBK 解码，中文注释的 UTF-8 字节会吞掉换行、把后续代码行并入 `#` 注释静默失效（2026-08-23 三次构建失败教训：`$localRepo` 行被吞导致 `git fetch` 报 `'main' does not appear to be a git repository`）；从 D 盘原版（无 BOM）复制回脚本后需重新加 BOM
12. 7za 归档 → `dist\` 产出 ZIP（可选 `-SkipArchive` 跳过）

## 同步 upstream

构建前建议先同步（upstream 是只读镜像，默认分支为 `main`，可随时重置）：

```powershell
git -C D:\Hermes-Agent-Portable-Builder\upstream fetch --prune origin
git -C D:\Hermes-Agent-Portable-Builder\upstream reset --hard origin/main
```

这不会影响同级的 `stage\` 目录。

## 便携包说明

产物结构：

```
Hermes-Agent-Portable\
├── Hermes.exe          # 启动器（winexe）：设 HERMES_HOME → 启后端/桌面 → 托盘驻留；首启原子创建最小配置
├── Update.exe          # 原地更新器：官方 hermes update + 依赖修复 + 桌面同步，数据不动（见"升级策略"）
├── app\                # Electron 桌面端（编译产物 app.asar*，官方源码不内嵌补丁）
├── runtime\            # uv / Python / venv（可重定位，link-mode copy）
├── data\hermes-home\   # HERMES_HOME 用户数据（配置/记忆/技能/内嵌官方源码；内嵌 git 为 depth 1 浅仓库，`hermes update` 增量更新）
├── scripts\            # Update-Portable.ps1 / Repair-Portable.ps1 / Verify-Portable.ps1（与 builder\scripts\ byte-identical）
└── README.txt          # 给最终用户的说明
```

- 入口点（`runtime\bin\`，全部由 `builder\source\` 生成并按 byte-identical 部署）：
  - `hermes-cli.cmd`：通用 CLI（清除桌面 App 泄漏的 `HERMES_WEB_DIST`，使用随包预构建网页版前端）
  - `hermes-tui.cmd`：TUI 入口（`--tui`）
  - `hermes-dashboard.cmd`：网页端入口，解析 `--port N`/`--port=N`（默认 9119；`--port 0` 自动分配；端口已有服务则直接打开浏览器）
- 数据随包走：`data\hermes-home\` 内所有用户数据跟随目录移动；覆盖升级不要先删旧 `data\`
- 用户配置保护：发行包不含 `data\hermes-home\config.yaml`；首启仅在文件不存在时原子创建最小配置 `display.language: zh`，已存在则完全不读写（见下节）

## 推理等级与 DeepSeek 的对应

Hermes 的"推理强度"（模型选项）共 7 档（内部阶梯 `EFFORT_LADDER`：`minimal/low/medium/high/xhigh/max/ultra`，桌面端中文 UI 显示为 最小/低/中/高/极高/最高/超高）。DeepSeek 官方 API 只有 low / high / max 三档（官方文档 [Thinking Mode](https://api-docs.deepseek.com/guides/thinking_mode/)），`medium`/`xhigh` 作为请求值会被官方静默映射成 high。Hermes 各档在 DeepSeek 上的实际生效值如下：

| Hermes 中文 | 内部值 | DeepSeek 实际生效 | 说明 |
|---|---|---|---|
| 最小 | `minimal` | `low` | DeepSeek 没有 `minimal` → 归到最低档 `low` |
| 低 | `low` | `low` | 一一对应 |
| 中 | `medium` | `high` | DeepSeek 没有 `medium`，官方把它映射成 `high` |
| 高 | `high` | `high` | 一一对应 |
| 极高 | `xhigh` | `high` | 官方把 `xhigh` 映射成 `high`（Hermes 源码 `DEEPSEEK_V4_OVERRIDES` 声明为 `max`，与官方文档不一致，以官方为准） |
| 最高 | `max` | `max` | 一一对应 |
| 超高 | `ultra` | `max` | DeepSeek 没有 `ultra` → 归到最高档 `max` |
| 关闭 | `none`/off | 关闭思考 | 发送 `thinking.type=disabled`，不发 `reasoning_effort` |

要点：

- DeepSeek 官方档位只有 low / high / max；默认 effort 为 high（不设置时服务器默认）
- 官方映射表（`deepseek-v4-flash`/`deepseek-v4-pro` 相同）：`low→low`、`medium→high`、`high→high`、`xhigh→high`、`max→max`——即 Hermes 的"中/高/极高"三档在 DeepSeek 上实际都是 `high`
- 归并策略是"只降不升"：Hermes 不支持的档位取最近更弱的支持等级，绝不静默升档
- 对照 DeepSeek Harness（dsh）：dsh 对 `deepseek-v4-flash` 只声明 `off/low/high/max`，`medium` 会被直接拒绝（`UNSUPPORTED_REASONING_EFFORT`）；DeepSeek 官方则接受 `medium` 但映射成 `high`


## 用户配置保护

| | |
|---|---|
| 问题 | 构建机上的配置（语言、密钥、MCP 等）绝不能混进发行包，否则会覆盖或污染用户自己的设置 |
| 改前 | 官方安装没有"保护"概念：配置文件缺失时直接用内置 `DEFAULT_CONFIG`，界面语言跟随官方默认 |
| 改后 | 构建确保发行包不含 `data\hermes-home\config.yaml`：正常流程中该文件从不出现（成品由未启动的官方源码组装，`config.yaml` 只会在用户首次启动时生成）；构建脚本以 fail-closed 守卫兜底（组装中段有意外残留则先删、删不掉即失败，最终由 Python 契约门禁复核缺席，报告 `UserConfigPackaged=false`）；首次启动时启动器仅在文件不存在的情况下，以原子 `CreateNew`/`wx` 方式创建一份最小配置 |
| 效果 | 全新用户自动获得中文界面；配置已存在的用户完全不读写、不合并、不替换，覆盖升级不丢任何设置 |

因此把新 ZIP 解压覆盖到已有 Portable 时，不会用发布包中的默认配置覆盖以下用户设置：

- MCP 服务器；
- 自定义 Provider、模型和 API 端点；
- 工具、终端、语言及其他偏好

`.env`、`auth.json`、`state.db` 等用户状态也不应进入发布 ZIP。覆盖升级时不要先删除旧的 `data\` 目录；ZIP 没有同名用户文件时，原数据会继续保留。

## 构建对官方源码的修改

构建器会用 `builder\scripts\Update-Portable.ps1 -Stage Patch` 对 `upstream\` 的官方 Desktop 源码临时打补丁：`npm run build`（electron-builder）编译完成后立即用 `-Stage PatchRemove` 还原，源码始终与官方逐字节一致，改动只烙在编译产物（`app\resources\app.asar*`）里。补丁全部是标记包围（`HERMES_PORTABLE_*_BEGIN/END`）、可重复应用、可完整撤销的；撤销后 `git status --porcelain` 必须为空。

### 修改清单（6 项）

#### 1. 便携路径重定向

| | |
|---|---|
| 文件 | `apps/desktop/electron/main.ts`（主进程启动处，路径常量初始化之前） |
| 改前 | 官方没有"便携"概念，配置、用户数据、日志全部写到系统目录（`%APPDATA%` 等） |
| 改后 | 检测到 `Hermes.exe` 旁的 `portable.marker` 文件后，把 `HERMES_HOME`、`HERMES_DESKTOP_USER_DATA_DIR`、PATH（含包内 Git/Node/捆绑 Python）全部重定向到包内 `data\` 与 `runtime\` |
| 效果 | 所有状态写入包内目录；整个目录移到别的机器/路径，行为不变，不污染系统 |

#### 2. 后端 Python 替换

| | |
|---|---|
| 文件 | `apps/desktop/electron/main.ts`（`createPythonBackend` 和 `createActiveBackend` 两处） |
| 改前 | `command` 用 venv 启动器（`venv\Scripts\python.exe`）启动后端 |
| 改后 | 若设置了 `HERMES_DESKTOP_PYTHON`，优先用捆绑的 `runtime\python\<版本>\python.exe` 直接启动 |
| 效果 | venv 启动器内嵌构建机绝对路径，不可迁移；捆绑运行时才是可重定位的，保证换机器后后端照常启动 |

#### 3. 界面默认缩放 100%

| | |
|---|---|
| 文件 | `apps/desktop/electron/zoom.ts` |
| 改前 | `DEFAULT_ZOOM_LEVEL = Math.log(0.9) / Math.log(ZOOM_FACTOR_BASE)`（默认 90%） |
| 改后 | `DEFAULT_ZOOM_LEVEL = Math.log(1.0) / Math.log(ZOOM_FACTOR_BASE)`（默认 100%） |
| 效果 | 全新用户第一次打开界面就是 100%；用户之后手动调的缩放仍会被记住并覆盖默认值 |

#### 4. 缩放测试配套

| | |
|---|---|
| 文件 | `apps/desktop/electron/zoom.test.ts` |
| 改前 | 断言 `zoomLevelToPercent(DEFAULT_ZOOM_LEVEL) === 90` |
| 改后 | 断言同步改为 `100` |
| 效果 | 第 3 项改了默认值后，测试文件若不跟着改，构建窗口期内跑 `npm test` 必挂；改后测试保持通过 |

#### 5. 缩放防重置（已退役 2026-08-26）

> 本补丁已移除：在打包应用上实测（Electron 40.10.2 / Chromium 144），上游自带的 `installZoomReassertOnNavigation`（挂在 `did-finish-load` 上，约 675ms）已恢复用户保存的缩放，干净 userData 下 20 秒观察零重置。旧补丁的 250ms 定时器在 `did-finish-load` 之前就触发，效果总被随后的页面加载覆盖，是失效的防御（若未来确需防御性延迟恢复，正确值应在 `did-finish-load` 之后，如 1000ms）。保留历史说明如下：

| | |
|---|---|
| 文件 | `apps/desktop/electron/main.ts` |
| 改前（已移除） | 官方只在导航/窗口事件时恢复缩放：`installZoomReassertOnWindowEvents(win, reassertZoom)` + `installZoomReassertOnNavigation(win.webContents, reassertZoom)`（后者挂在 `did-finish-load`/`did-navigate-in-page` 上） |
| 改后（已移除） | 曾追加延迟 250ms 重读保存值、再应用一次：`setTimeout(() => restorePersistedZoomLevel(win), 250)` |
| 效果 | 上游 `did-finish-load` reassert 已覆盖首次加载恢复（#48658/#38854/#79863），无需额外延迟恢复 |

#### 6. 语言种子（兜底）

| | |
|---|---|
| 文件 | `apps/desktop/electron/main.ts`（便携重定向块内） |
| 改前 | 无（官方不管语言默认值，由启动器/配置决定） |
| 改后 | `config.yaml` 不存在时写入 `display.language: zh` |
| 效果 | 用户绕过启动器、直接双击 `app\Hermes.exe` 时，仍能获得中文默认；配置已存在则不触碰 |


#### 7. 默认透明度关闭

| | |
|---|---|
| 文件 | `apps/shared/src/translucency.ts`（`defaultTranslucencyValues`） |
| 改前 | 官方按平台默认：macos `light: { intensity: 66, ... }` / `dark: { intensity: 22, ... }`，windows `light: { intensity: 20, ... }` / `dark: { intensity: 5, ... }`——浅色主题整窗淡到约 70% 原生透明度，文字/界面对比度明显下降 |
| 改后 | 两套平台（macos + windows）默认全部 `intensity: 0`（补丁标记包围 `HERMES_PORTABLE_TRANSLUCENCY_BEGIN/END`）——默认不透明，用户需要可在桌面设置里自行开启 |
| 效果 | 浅色主题默认清晰可读；抗漂移：按结构匹配任意官方数字、一律改成 0，原值捕获进补丁标记（"was light N / dark M, windows light N / dark M"），`PatchRemove` 精确还原捕获的原值（官方改成什么就还原什么，逐字节一致） |
| 注意 | `apps/shared` 不在桌面内容哈希范围内（官方 `_compute_desktop_content_hash` 只走 `apps/desktop`），因此该补丁通过完整构建进入产物；部署侧 SyncDesktop 仅当 `apps/desktop` 变化时才强制重建桌面 |
### 首次启动播种（启动器，非源码补丁）

| | |
|---|---|
| 文件 | `builder\source\Hermes.cs`，编译为根目录 `Hermes.exe`。注意：这不是源码补丁，而是启动器自带的逻辑 |
| 改前 | 官方启动器不写配置文件：全新安装直接使用内置 `DEFAULT_CONFIG` |
| 改后 | 发行包不含 `config.yaml`（见"用户配置保护"：构建中段有意外残留则先删、删不掉即失败——删除型 fail-closed 守卫；最终契约门禁再复核缺席），首启时 `EnsureFirstRunConfig()` 仅在文件不存在时原子创建最小配置：`display.language: zh` |
| 效果 | 全新用户默认中文界面；配置一旦存在，启动器从此不再读写它，用户设置永不被打扰 |

### 设计契约

- 补丁必须标记包围、可重复应用、可完整撤销；撤销后源码与官方逐字节一致（`git status --porcelain` 为空）
- 随包发布的 `scripts\*.ps1`（含补丁脚本）与 `builder\` 源码 byte-identical；改动后需重新构建同步全部副本，不得只改部署侧
- 上述修改只存在于构建窗口期；发布 ZIP 内嵌的官方源码保持官方原样
- 更新流程同样不留补丁：`Update-Portable.ps1 -Stage SyncDesktop` 在桌面同步（原子交换）完成后自动执行 `-Stage PatchRemove` 自清理；`Update.exe` 在官方 `hermes update` 前另有 `-Remove` + `git clean -fd` 兜底，并在官方 `hermes update` 前与 `-UpdatePython` 前各执行一次 `StopPortableProcesses`（按安装根路径停 Hermes/python，释放 cryptography DLL 锁与 venv 目录锁，2026-08-15 修复）。因此无论构建还是更新路径，内嵌源码都以干净状态收尾，绕过 Update.exe 直接运行官方 `hermes update` 也不会触发 "Restore local changes now? [Y/n]" stash 提示
- 增量构建（2026-08-14）：SyncDesktop 对 Desktop/TUI/Web 分别增量判断——Desktop 用 `data\hermes-home\desktop-build-stamp.json`（构建时在行尾规范化之后写入的 `apps/desktop` + 根 package.json/lockfile 内容哈希，判断在补丁之前、以无补丁源码对比，构建机与部署后的便携版上运行的算法一致；stamp 若在规范化前写入会因 CRLF/LF 字节差导致哈希错位、增量永远失效）；TUI/Web 直接调用官方 `_tui_need_rebuild` / `_web_ui_build_needed`。某部分源码没动就跳过其重建（Desktop 跳过时含补丁往返与 app 交换），全部没动则整个 SyncDesktop 几乎零成本，更新明显加快

## 依赖缓存维护

上游升级 Python 依赖（`uv.lock`/`pyproject.toml`）或 npm 依赖（`package-lock.json`）后，构建会在各自缓存缺失时联网补齐并回填；也可以主动预下载和清理：

- npm 缓存：`builder\assets\npm-cache`（`npm_config_cache`），`--prefer-offline` 全命中
- uv 包缓存：构建机用户级 `%LOCALAPPDATA%\uv\cache`。预下载单个包用构建器自带 uv：`uv.exe pip install --python <assets\python\cpython-3.11.*\python.exe> --target <临时目录> <包>==<版本>`（用捆绑 Python 保证 wheel 口味与构建一致，下载即回填缓存）
- 清理旧版本：删 `uv\cache\wheels-v6\pypi\<包>\` 下旧版本条目及 `archive-v0\` 对应解压目录；`simple-v24\` 是 PyPI 索引元数据缓存（解析时自动生成），保留无害
- 构建用 `uv sync --locked`，不做版本解析，`--locked` 下按 lockfile 的 URL/hash 取包，因此锁定版本（cffi 2.0.0、pycparser 3.0 等）是否在缓存中决定是否需要联网

## MCP 回归门禁

`Verify-Portable.ps1` 必须输出：

```text
McpImports: mcp-ok
```

`Verify-Portable.ps1` 的库存检查还包含 `WebDist` 项（`hermes_cli\web_dist\index.html` 必须存在，否则独立网页端不可用）

构建脚本内联的 Python 契约门禁（`Test-PortablePythonContract` 函数，2026-08-10 起内置于 `Hermes.ps1`）必须输出：

```text
PortablePythonBootstrap: true
ExternalOverlayPackaged: false
RuntimeToolsUnique: true
BuildOnlyFilesPackaged: false
EmbeddedCheckoutIsOfficialOnly: true
```

非 relocatable 元数据门禁（`Test-PortableNoEditableInstall`，同样已内联）拒绝 `__editable__*` / `*.egg-link` 与 `.pth` 中的构建根绝对路径。

## 冒烟测试

解压到临时目录后按发布验证清单执行（完整细节见技能 `hermes-agent-portable-builder`）：

1. `scripts\Verify-Portable.ps1` 输出含 `McpImports: mcp-ok` 与 `WebDist` 项
2. 契约门禁输出：`PortablePythonBootstrap: true`、`ExternalOverlayPackaged: false`、`RuntimeToolsUnique: true`、`BuildOnlyFilesPackaged: false`、`EmbeddedCheckoutIsOfficialOnly: true`
3. 运行 `Hermes.exe`，首启后 `data\hermes-home\config.yaml` 生成且仅含 `display.language: zh`；再次启动不覆盖已有配置
4. `runtime\bin\hermes-cli.cmd --version` 等入口正常；`hermes-dashboard.cmd` 启动后 `http://127.0.0.1:9119` 可达（默认端口）
5. 内嵌官方源码与 upstream 逐字节一致（无补丁残留）；`data\hermes-home` 内嵌 checkout `git status` 干净
6. 发行 ZIP 内不含 `data\hermes-home\config.yaml`；`7za t` 完整性 OK；`data\` 只含预置内容
7. Update.exe 为窗口版：运行 `Update.exe --check`，窗口出现（标题 "Hermes Portable Update"）且自动执行一次检查（`.git\FETCH_HEAD` mtime 更新）；4 秒后进程仍存活（窗口构建无崩溃），随后关闭——残留 `.hermes-update-in-progress` 标记带 PID 校验，下次运行自动忽略
8. 无头端到端更新链（在便携包副本上做，别动正式包）：复制 `data\hermes-home\hermes-agent` 到临时目录 → 删除 `venv` → 用 `data\hermes-home\bin\uv.exe pip install --python <venv python> -e .` 重建 → 退出码 0 且 `hermes-cli.cmd --version` 正常

## 升级策略

Hermes 是活跃开发项目、迭代频繁。升级分两种情况：

① 原地更新（推荐，不需重建）

- 双击包根目录的 `Update.exe`：打开更新窗口（当前版本/最新版本 + 实时日志 + "检查更新"/"立即更新"按钮）。"检查更新"调用官方 `hermes update --check`（只 fetch 不安装）；"立即更新"先做 github.com 网络预检（包内 node 探测，6 秒超时，网络不通秒级报原因且不做任何改动），再官方 `hermes update`（git 拉取 + 依赖安装）+ 便携环境修复 + 桌面同步（`Update-Portable.ps1 -Stage SyncDesktop`），步骤输出实时流式显示在窗口日志框，失败自动分类（网络/DNS/权限）。`--check` 参数（托盘/命令行入口）打开窗口并自动执行一次检查
- 只更新源码/依赖/桌面端，用户数据 `data\hermes-home\` 原样保留；官方更新前自动停止本包进程（释放 cryptography DLL 锁与 venv 目录锁）并清理补丁
- Desktop/TUI/Web 按 stamp 增量判断，源码没动就跳过对应重建
- 失败在窗口内显示；诊断日志：`data\hermes-home\logs\Update.exe-diagnostic.log`（每次运行追加，含各步骤退出码与输出）
- 注意：此方式不换 Python/Node 运行时版本，也不更新启动器/图标/入口脚本

② 重新构建（当更新超出 Hermes 本身时）

当新版 Hermes 提升 Python/Node 选择器、或需要换启动器/图标/入口脚本/README 时：同步 upstream → 重新构建 → 产出新 zip（`dist\` 按时间戳区分，旧归档可自行清理）。

## 相关

- 便携版运行机制细节、坑点清单见技能：`hermes-agent-portable-builder`（`builder\data\hermes-home\skills\software-development\hermes-agent-portable-builder`）

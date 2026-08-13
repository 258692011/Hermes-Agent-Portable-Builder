# Hermes Agent Portable Builder

此目录是本机 Portable 构建系统，**不是**官方 Git 仓库的一部分；官方源码只存放在 `upstream\` 子目录中

目录职责：

- `upstream\`：只保存 NousResearch 官方 Hermes 源码，可直接同步或重置到 `origin/main`
- `builder\`：本地构建器实现，包括 scripts、templates 和 assets；只在构建机使用
- `builder\data\`：Builder 管理的成品 data 种子源码（`hermes-home\memories\`、`hermes-home\skills\` 等）；目录结构镜像成品中的 `data\`
- `stage\`：组装后的未压缩 Portable 目录
- `dist\`：可选的最终 ZIP

### 构建机要求

当前只支持 **Windows 10/11 x64**。构建机需要：

| 软件 | 版本要求 | 是否必须预装 | 说明 |
|---|---|---:|---|
| Windows PowerShell | 5.1（Windows 自带） | 是 | 构建入口及维护脚本运行环境 |
| Git for Windows | 当前固定 **2.55.0.3**（`v2.55.0.windows.3`，构建脚本硬编码） | 否 | 构建器**不读取系统**；从 `builder\assets\git\` 缓存取 PortableGit 进成品，缓存缺失才下载（下载后回填 assets 缓存） |
| Node.js + npm | 上游选择器 **22**；当前缓存 **v22.23.2**（npm 11.19.0） | 是（编译用） | 编译 Desktop、TUI 和运行 electron-builder 需要构建机上的 npm；打包进成品的 Node 运行时**不读取系统**，从 `builder\assets\node\` 缓存取，缺失才从 nodejs.org 下载（下载后回填 assets 缓存） |
| uv | 构建器用固定 **0.12.3** | 否 | 构建器**不读取系统**；从 `builder\assets\uv\` 缓存取，缺失才下载（下载后回填 assets 缓存） |
| Python | 当前上游选择器为 **3.11**；patch 版本不锁定 | 否 | 构建器**不读取系统**；从 `builder\assets\python\` 的解压目录取，缺失才由 uv 安装（下载后回填 assets 缓存） |
| .NET Framework C# 编译器 | v4.0（Windows 10/11 自带） | 是（系统组件） | 使用 `Framework64\v4.0.30319\csc.exe` 编译 `Hermes.exe` 和 `Update.exe` |
| 7za.exe（7-Zip 命令行版） | 随仓库内置 `builder\assets\7zip\7za.exe`（当前 26.02） | 否 | 通常随仓库自带；缺失时自动从 7-Zip 官网下载 extra 包恢复（下载后回填 assets 缓存） |

版本规则：Git 固定 2.55.0.3（构建脚本硬编码，升级需改 `$gitTag`/`$gitVer`）；Node 跟随上游选择器主版本 22，
缓存里的具体 patch 版本随上游 `NodeVersion` 更新而变；uv 固定 0.12.3；Python 跟随上游选择器 3.11。上游以后修改 `PythonVersion`、`NodeVersion` 或
`package.json` 的 `engines.npm` 时，构建器会读取新要求并自动适配（包内 npm 不足时自动升级），
此表也应随发布流程同步更新。用户端更新脚本（`Update-Portable.ps1 -Stage SyncDesktop`）同样会在 TUI 重建前
检查并升级包内 npm，因此官方提升 npm 要求不会卡住老部署的更新

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  D:\Hermes-Agent-Portable-Builder\builder\templates\Build-Hermes-Portable.ps1 `
  -SkipArchive
```

输出：

```text
D:\Hermes-Agent-Portable-Builder\stage\Hermes-Agent-Desktop-Portable
```

`-SkipArchive` 表示只组装 Portable 目录、跳过 ZIP 打包（压缩 32,000+ 个文件约需数分钟）构建
逻辑与完整构建完全一致，只是不产出压缩包；想要 `dist\` 下的 ZIP 时不加任何开关直接运行即可

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  D:\Hermes-Agent-Portable-Builder\builder\templates\Build-Hermes-Portable.ps1
```

输出：

```text
D:\Hermes-Agent-Portable-Builder\dist\Hermes-Agent-Desktop-Portable-<版本>-win-x64-<时间戳>.zip
```

构建始终是完整流程，没有跳过 Desktop 重建的开关（曾有的 `-SkipDesktopBuild` 已于 2026-08-07 移除，
因为它会让 Python 解析走不同路径、掩盖构建脚本缺陷；以后排查问题时只有一条构建路径可循）

首次构建会直接在 `stage\Hermes-Agent-Desktop-Portable` 中组装出：uv、官方指定版本的
Python、venv 与锁定依赖、官方指定主版本的 Node.js、PortableGit。其中 uv 二进制、Python
运行时、Node.js、PortableGit 全部来自 `builder\assets\` 离线缓存（缓存缺失时才下载并回填
缓存）；Python 依赖的 wheel 则走 uv 的构建机用户级缓存（Windows 默认
`%LOCALAPPDATA%\uv\cache`，构建脚本不设 `UV_CACHE_DIR`），同样离线优先、缺失才下载。
它是"从零组装"，不需要 seed（即
不拿任何旧 Portable 当底料来增量改造），也不会创建 `.old-release-extract` 之类的旧版本暂存目录

npm 依赖与 Electron 二进制同样离线优先：构建脚本把 `npm_config_cache`、`ELECTRON_CACHE`、
`ELECTRON_BUILDER_CACHE` 指向 `builder\assets\npm-cache`、`electron-cache`、`electron-builder-cache`，
各 workspace 安装带 `--prefer-offline`——首次在线构建回填缓存，之后的构建（含 electron 下载）
完全离线，与 Git/Node 同一契约（uv 二进制同样在 assets，其 Python 包缓存见上文说明）

当前构建目标明确为 **Windows x64**；ARM64/x86 会在入口被拒绝，避免把不同架构的 Python、
Node、Git 和 Electron 混装。缺少 uv 时用固定的 0.12.3；Python 依赖使用
`uv.lock`、`--no-install-project` 和 copy 模式，不生成含构建绝对路径的 editable metadata

构建器不读取 `HERMES_PORTABLE_RUNTIME_SEED`（"种子"环境变量，指向一个旧 Portable 供复用），也不读取
同级旧 Portable，**运行时组件完全不读取系统**（系统里有没有 Git/uv/Node/Python 都不影响构建，产物只
来自 assets 缓存）。Python 和 venv 都写入新成品自己的运行时目录，venv 始终重新生成，因此最终包不会
依赖构建机上的系统路径，也不会继承旧版本里的任何残留状态

构建脚本会临时修改官方 Desktop 源码，构建结束后立即移除补丁，修改内容详见下文
「构建对官方源码的修改」章节。构建项目的完整覆盖层只保留在
构建机的 `builder\`，不会复制到成品或内嵌官方 Git 源码。Builder 管理的成品 data 种子源码位于
`builder\data\`（`hermes-home\memories\`、`hermes-home\skills\` 等），整个目录树按原结构复制到成品对应的 `data\`

技能目录中的 `SKILL.md` 与 `references\` 会按原结构复制（自 2026-08-12 起不再强制要求技能存在或精简，`hermes-portable-builder` 技能门禁已移除）。Portable 运行维护脚本
只保留一份在成品根 `scripts\`（`Update-Portable.ps1` + `Repair-Portable.ps1` + `Verify-Portable.ps1`）；
构建脚本、测试、模板和 7-Zip 只属于构建项目，不进入成品。这样既能加载技能，又不会复制重复工具或构建源码

## 用户配置保护

| | |
|---|---|
| 问题 | 构建机上的配置（语言、密钥、MCP 等）绝不能混进发行包，否则会覆盖或污染用户自己的设置 |
| 改前 | 官方安装没有"保护"概念：配置文件缺失时直接用内置 `DEFAULT_CONFIG`，界面语言跟随官方默认 |
| 改后 | 构建时**强制删除** `data\hermes-home\config.yaml`（若残留则构建直接失败）；首次启动时启动器仅在文件**不存在**的情况下，以原子 `CreateNew`/`wx` 方式创建一份最小配置 |
| 效果 | 全新用户自动获得中文界面；配置已存在的用户**完全不读写、不合并、不替换**，覆盖升级不丢任何设置 |

首启创建的最小配置：

```yaml
display:
  language: zh
```

因此把新 ZIP 解压覆盖到已有 Portable 时，不会用发布包中的默认配置覆盖以下用户设置：

- MCP 服务器；
- 自定义 Provider、模型和 API 端点；
- 工具、终端、语言及其他偏好

`.env`、`auth.json`、`state.db` 等用户状态也不应进入发布 ZIP。覆盖升级时不要先删除旧的
`data\` 目录；ZIP 没有同名用户文件时，原数据会继续保留

## 构建对官方源码的修改

构建器会用 `builder\scripts\Update-Portable.ps1 -Stage Patch` 对 `upstream\` 的官方 Desktop
源码**临时**打补丁：`npm run build`（electron-builder）编译完成后立即用 `-Stage PatchRemove` 还原，
源码始终与官方逐字节一致，改动只烙在编译产物（`app\resources\app.asar*`）里。补丁全部是
标记包围（`HERMES_PORTABLE_*_BEGIN/END`）、可重复应用、可完整撤销的；撤销后
`git status --porcelain` 必须为空

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

#### 5. 缩放防重置

| | |
|---|---|
| 文件 | `apps/desktop/electron/main.ts` |
| 改前 | 页面加载完成时应用一次用户保存的缩放：`did-finish-load → restorePersistedZoomLevel(win)` |
| 改后 | 加载完成后先应用一次，再延迟 250ms 重读保存值、再应用一次 |
| 效果 | Chromium 内核在打包应用首次加载后可能把缩放悄悄重置回 100%，导致用户设置丢失；第二次应用（250ms 后）确保用户看到的还是自己保存的缩放 |

#### 6. 语言种子（兜底）

| | |
|---|---|
| 文件 | `apps/desktop/electron/main.ts`（便携重定向块内） |
| 改前 | 无（官方不管语言默认值，由启动器/配置决定） |
| 改后 | `config.yaml` 不存在时写入 `display.language: zh` |
| 效果 | 用户绕过启动器、直接双击 `app\Hermes.exe` 时，仍能获得中文默认；配置已存在则不触碰 |

### 首次启动播种（启动器，非源码补丁）

| | |
|---|---|
| 文件 | `builder\templates\Hermes-Desktop.cs`，编译为根目录 `Hermes.exe`。注意：这不是源码补丁，而是启动器自带的逻辑 |
| 改前 | 官方启动器不写配置文件：全新安装直接使用内置 `DEFAULT_CONFIG` |
| 改后 | 构建时故意删掉 `config.yaml`（见"用户配置保护"），首启时 `EnsureFirstRunConfig()` 仅在文件**不存在**时原子创建最小配置：`display.language: zh` |
| 效果 | 全新用户默认中文界面；配置一旦存在，启动器从此不再读写它，用户设置永不被打扰 |

### 入口点与网页端（启动器模板与构建步骤，非源码补丁）

`runtime\bin\` 下有三个入口点，全部由 `builder\templates\` 生成并按 byte-identical 部署：

| 入口 | 用途 |
|---|---|
| `hermes-cli.cmd` | 通用 CLI。会清除桌面 App 泄漏的 `HERMES_WEB_DIST` 环境变量，确保独立运行的 `hermes dashboard` 使用随包预构建的 `hermes_cli\web_dist\` 网页版前端，而不是需要桌面 IPC 桥的 Electron 桌面包（后者在浏览器里会报 "Desktop IPC bridge is unavailable"） |
| `hermes-tui.cmd` | TUI 入口（`--tui`） |
| `hermes-dashboard.cmd` | 网页端入口：解析 `--port N` 与 `--port=N` 两种写法（默认 9119；编辑文件顶部 `PORT` 行可固定端口；`--port 0` 自动分配）。若目标端口已有服务在监听则直接打开浏览器，否则启动服务并自动打开浏览器。注意 `shift` 会覆盖 `%0`（脚本路径），必须先 `set "BIN=%~dp0"` 再解析参数 |

构建脚本预构建网页版前端并写入构建 stamp：

- `npm install --workspace web --include=dev` + `web\` 内 `npm run build`（vite 输出到 `hermes_cli\web_dist\`）；
- 用 staged venv 调用官方 `_write_web_ui_build_stamp` 写入 `data\hermes-home\web-ui-build-stamp.json`（web 源码内容哈希）；**必须是最后一步** —— stage 的 `git rm --cached` + `reset --hard`（行尾 LF 规范化，真正的重写发生在这一步；之前的 `reset --hard` 会被 git stat cache 跳过）会把跟踪文件从 CRLF 改写为 LF，改变哈希覆盖的字节；提前写 stamp 会导致用户首次启动时哈希不匹配而触发重建；
- 效果：用户首次运行 `hermes dashboard` 时内容哈希一致，跳过运行时 `npm install` 与重建，离线秒开（与 TUI bundle 同一契约）。stage 的 `git clean -fdx` 排除 `hermes_cli\web_dist\`，更新脚本（`Update-Portable.ps1 -Stage SyncDesktop`）同样重建 bundle 并重写 stamp

### 设计契约

- 补丁必须标记包围、可重复应用、可完整撤销；撤销后源码与官方逐字节一致（`git status --porcelain` 为空）
- 随包发布的 `scripts\*.ps1`（含补丁脚本）与 `builder\` 源码 byte-identical；改动后需重新构建
  同步全部副本，不得只改部署侧
- 上述修改只存在于构建窗口期；发布 ZIP 内嵌的官方源码保持官方原样
- 更新流程同样不留补丁：`Update-Portable.ps1 -Stage SyncDesktop` 在桌面同步（原子交换）完成后自动执行
  `-Stage PatchRemove` 自清理；`Update.exe` 在官方 `hermes update` 前另有
  `-Remove` + `git clean -fd` 兜底。因此无论构建还是更新路径，内嵌源码都以干净状态收尾，
  绕过 Update.exe 直接运行官方 `hermes update` 也不会触发 "Restore local changes now? [Y/n]" stash 提示

## 同步官方

```powershell
git -C D:\Hermes-Agent-Portable-Builder\upstream fetch --prune origin
git -C D:\Hermes-Agent-Portable-Builder\upstream reset --hard origin/main
```

这不会影响同级的 `stage\` 目录

## 依赖缓存维护

上游升级 Python 依赖（`uv.lock`/`pyproject.toml`）或 npm 依赖（`package-lock.json`）后，
构建会在各自缓存缺失时联网补齐并回填；也可以主动预下载和清理：

- npm 缓存：`builder\assets\npm-cache`（`npm_config_cache`），`--prefer-offline` 全命中
- uv 包缓存：构建机用户级 `%LOCALAPPDATA%\uv\cache`。预下载单个包用构建器自带 uv：
  `uv.exe pip install --python <assets\python\cpython-3.11.*\python.exe> --target <临时目录> <包>==<版本>`
  （用捆绑 Python 保证 wheel 口味与构建一致，下载即回填缓存）
- 清理旧版本：删 `uv\cache\wheels-v6\pypi\<包>\` 下旧版本条目及 `archive-v0\` 对应解压目录；
  `simple-v24\` 是 PyPI 索引元数据缓存（解析时自动生成），保留无害
- 构建用 `uv sync --locked`，不做版本解析，`--locked` 下按 lockfile 的 URL/hash 取包，
  因此锁定版本（cffi 2.0.0、pycparser 3.0 等）是否在缓存中决定是否需要联网

## MCP 回归门禁

`Verify-Portable.ps1` 必须输出：

```text
McpImports: mcp-ok
```

`Verify-Portable.ps1` 的库存检查还包含 `WebDist` 项（`hermes_cli\web_dist\index.html` 必须存在，否则独立网页端不可用）

构建脚本内联的 Python 契约门禁（`Test-PortablePythonContract` 函数，2026-08-10 起内置于 `Build-Hermes-Portable.ps1`）必须输出：

```text
PortablePythonBootstrap: true
ExternalOverlayPackaged: false
RuntimeToolsUnique: true
BuildOnlyFilesPackaged: false
EmbeddedCheckoutIsOfficialOnly: true
```

非 relocatable 元数据门禁（`Test-PortableNoEditableInstall`，同样已内联）拒绝
`__editable__*` / `*.egg-link` 与 `.pth` 中的构建根绝对路径

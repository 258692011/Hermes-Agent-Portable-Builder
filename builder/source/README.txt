Hermes Agent Desktop Portable (Windows x64)
============================================

Upstream: https://github.com/NousResearch/hermes-agent
Hermes Agent: {{HERMES_VERSION}}
Source commit: {{SOURCE_COMMIT}}
Desktop: Electron {{ELECTRON_VERSION}}
Bundled runtime: Python {{PYTHON_VERSION}}, Node.js {{NODE_VERSION}}, Git for Windows {{GIT_VERSION}}, uv {{UV_VERSION}}

使用
----
1. 完整解压 ZIP，不要直接在压缩软件中运行。
2. 双击 Hermes.exe
3. 首次运行时，请按提示配置模型和 API；用户数据将写入 data 目录。
4. （可选）网页端：双击 runtime\bin\hermes-dashboard.cmd（或运行 hermes dashboard），
   浏览器自动打开 http://127.0.0.1:9119

便携范围
--------
- 已内置 Hermes Agent、Python、Node/npm/npx、PortableGit/Git Bash、uv 和
  Electron Desktop。
- HERMES_HOME 固定在 data\hermes-home
- Electron userData 固定在 data\electron-user-data
- 迁移到另一台 Windows x64 电脑时复制整个目录即可。
- OAuth 提供商可能因设备令牌或系统凭据变化要求重新登录。
- Docker、WSL、GPU 驱动、桌面控制权限等系统级组件仍由目标 Windows 提供。

更新
----
先退出 Hermes，再运行 Update.exe。它直接调用官方 hermes update，更新源为
NousResearch/hermes-agent。Portable 维护脚本（scripts\ 下的修复/补丁/同步/验证脚本）独立保存于
官方 Git checkout 之外，因此官方更新不会删除启动器、修复脚本或 MCP/pywin32 bootstrap。更新器会重新
读取官方 scripts\install.ps1 中的 PythonVersion，按该版本选择器更新内置 Python。更新成功后
弹出对话框询问是否立即重启 Hermes（是：重启并关闭更新器；否：保持更新器窗口打开）；只有自动启动失败或更新出错时才会提示。
更新前建议备份整个 data 目录。
更新失败时，Update.exe 会弹出对话框说明失败原因（如网络无法连接 GitHub），
并写入诊断日志：data\hermes-home\logs\Update.exe-diagnostic.log

数据备份
--------
最重要的目录：data\hermes-home 和 data\electron-user-data

故障排查
--------
日志：data\hermes-home\logs\desktop.log

网页端：runtime\bin\hermes-dashboard.cmd 即可启动并自动打开浏览器访问
http://127.0.0.1:9119（默认仅本机访问）；也可用 hermes-cli.cmd dashboard
自定义端口：hermes-dashboard.cmd --port 9120（也支持 --port=0 自动分配），或编辑该文件顶部的 PORT 行固定端口。

CLI：runtime\bin\hermes-cli.cmd
TUI：runtime\bin\hermes-tui.cmd
检查：scripts\Verify-Portable.ps1
环境修复（Python/venv 损坏时）：scripts\Repair-Portable.ps1

说明
----
本包基于 MIT 许可的官方上游源码构建，是 ZIP 目录式 Portable 构建，不是 Nous Research
官方发布的 Portable 附件。源码与许可证保留在 data\hermes-home\hermes-agent

---
name: chrome-cdp
description: Interact with local Chrome browser session (only on explicit user approval after being asked to inspect, debug, or interact with a page open in Chrome)
---

# Chrome CDP

Lightweight Chrome DevTools Protocol CLI. Connects directly via WebSocket — no Puppeteer, works with 100+ tabs, instant connection.

## 核心原理(`chrome://inspect` 不是必须的)

CDP 连接**不依赖** `chrome://inspect/#remote-debugging` 页面——那个开关只是浏览器的**可视化查看入口**,不是调试开关。真正开启调试的是浏览器进程启动参数 **`--remote-debugging-port=<PORT>`**,它让浏览器开一个 WebSocket 调试端口,`cdp.mjs` 直接连端口即可,全程无需打开 `chrome://inspect`。实测 360 / Edge / Chrome 三种浏览器,不开该页面都能连。

## Prerequisites

- Chrome (or Chromium, Brave, Edge, Vivaldi, 360 极速) with remote debugging enabled via `--remote-debugging-port` launch flag (NOT the `chrome://inspect` page)
- 360 极速浏览器 X (360ChromeX) 也支持 CDP,但行为不同,见下方「360 极速浏览器」一节
- 新版 Chrome / Edge **强制要求独立 user-data-dir** 才能命令行调试,见下方「Chrome / Edge 新版」一节
- Node.js 22+ (uses built-in WebSocket)
- If your browser's `DevToolsActivePort` is in a non-standard location, set `CDP_PORT_FILE` to its full path

## 360 极速浏览器 X 注意事项

360ChromeX 也是 Chromium 内核,CDP 协议完全一样:`list`/`eval`/`shot`/`click` 等命令均可用。但有两个关键差异:

1. **图标显示在 Windows 的 user-data 多一层目录**。标准 Chrome/Brave/Edge 是 `%LOCALAPPDATA%/<Name>/User Data`,360 是 `%LOCALAPPDATA%/360ChromeX/Chrome/User Data`(中间多 `Chrome/`)。本技能 `cdp.mjs` 已把 `360ChromeX/Chrome` 加进了 Windows 候选路径(见 `getWsUrl()` 里的列表)。

2. **360 即使开了调试端口也不写 `DevToolsActivePort` 文件**(标准 Chrome/Edge 用 `--remote-debugging-port` 启动后会写)。所以即使 CDP 脚本认得 360 路径,也会因为找不到该文件而报错 `No DevToolsActivePort found`。**必须手动用 `CDP_PORT_FILE` 指定**:先 `curl http://127.0.0.1:<PORT>/json/version` 拿到 `webSocketDebuggerUrl`(含浏览器 UUID 路径),再自己造一个两行文件(端口 + WS 路径)给脚本:

```bash
# 第一步:启动 360 带调试端口(会打印 DevTools listening on ws://127.0.0.1:9222/...)
"/c/Users/<USER>/AppData/Local/360ChromeX/Chrome/Application/360ChromeX.exe" --remote-debugging-port=9222 --restore-last-session
# 第二步:从 json/version 拿浏览器 WS 路径
curl -s http://127.0.0.1:9222/json/version   # 找 webSocketDebuggerUrl 里的 /devtools/browser/<uuid>
# 第三步:造两行端口文件(PORT + WS 路径),并用 CDP_PORT_FILE 运行
printf "9222\n/devtools/browser/<uuid>\n" > "$LOCALAPPDATA/Temp/360-cdp-port.tmp"
CDP_PORT_FILE="$LOCALAPPDATA/Temp/360-cdp-port.tmp" node scripts/cdp.mjs list
```

> 坑:`chrome://inspect` 页面打开只是查看已开启调试目标的**入口,不是开启调试**。真正开启必须让浏览器进程带 `--remote-debugging-port` 参数启动。360 命令行用默认 profile 开调试不会像新版 Edge 那样因为"要非默认 user-data-dir"而拒绝。

## Chrome / Edge 新版:强制独立 user-data-dir

2024 年后的新版 **Google Chrome 与微软 Edge**(实测 151/152 版)直接用**默认 User Data 目录** + `--remote-debugging-port` 启动会报错并**拒绝开启调试端口**:

```
DevTools remote debugging requires a non-default data directory. Specify this using --user-data-dir.
```

(仅指命令行调试;`user-data-dir` 需为一个**独立的、非默认**的目录。)

**绕行方案**——用一个独立的临时 user-data-dir 启动,注意:**先彻底退出所有该浏览器的进程**,否则 Chrome/Edge 的"单实例"机制会让带参数的新启动被忽略(调试参数只在首启生效),然后:

```bash
# 退出所有 Chrome (Edge 同理):taskkill -F -IM chrome.exe
# 用独立 user-data-dir + 调试端口 + 测试页启动
"/c/Program Files/Google/Chrome/Application/chrome.exe" \
  --remote-debugging-port=9224 \
  --user-data-dir="C:\\Users\\Administrator\\AppData\\Local\\Temp\\chrome-cdp-test" \
  --no-first-run --no-default-browser-check "https://www.baidu.com/"
```

> 这个独立 profile 是全新干净目录,不涉登录、不影响你日常浏览器数据。启动后 `curl http://127.0.0.1:<PORT>/json/version`,再按上文 360 一节的 `CDP_PORT_FILE` 方式连 `cdp.mjs`。实测新版 Chrome/Edge 在独立目录下也不写 `DevToolsActivePort` 文件,和 360 一致,需手动用 `CDP_PORT_FILE`。

**三浏览器差异速查(实测)**

| 浏览器 | 默认 user-data-dir 可调试? | 写 `DevToolsActivePort`? | 用法 |
|--------|:---:|:---:|------|
| 360 极速 X | ✅ 允许 | ❌ 不写 | 可直接连,`CDP_PORT_FILE` 指定 |
| 微软 Edge 151+ | ❌ 必须独立目录 | ❌ 不写 | `--user-data-dir` + `CDP_PORT_FILE` |
| 谷歌 Chrome 151+ | ❌ 必须独立目录 | ❌ 不写 | `--user-data-dir` + `CDP_PORT_FILE` |

## Commands

All commands use `scripts/cdp.mjs`. The `<target>` is a **unique** targetId prefix from `list`; copy the full prefix shown in the `list` output (for example `6BE827FA`). The CLI rejects ambiguous prefixes.

### List open pages

```bash
scripts/cdp.mjs list
```

### Take a screenshot

```bash
scripts/cdp.mjs shot <target> [file]    # default: screenshot-<target>.png in runtime dir
```

Captures the **viewport only**. Scroll first with `eval` if you need content below the fold. Output includes the page's DPR and coordinate conversion hint (see **Coordinates** below).

### Accessibility tree snapshot

```bash
scripts/cdp.mjs snap <target>
```

### Evaluate JavaScript

```bash
scripts/cdp.mjs eval <target> <expr>
```

> **Watch out:** avoid index-based selection (`querySelectorAll(...)[i]`) across multiple `eval` calls when the DOM can change between them (e.g. after clicking Ignore, card indices shift). Collect all data in one `eval` or use stable selectors.

### Other commands

```bash
scripts/cdp.mjs html    <target> [selector]   # full page or element HTML
scripts/cdp.mjs nav     <target> <url>         # navigate and wait for load
scripts/cdp.mjs net     <target>               # resource timing entries
scripts/cdp.mjs click   <target> <selector>    # click element by CSS selector
scripts/cdp.mjs clickxy <target> <x> <y>       # click at CSS pixel coords
scripts/cdp.mjs type    <target> <text>         # Input.insertText at current focus; works in cross-origin iframes unlike eval
scripts/cdp.mjs loadall <target> <selector> [ms]  # click "load more" until gone (default 1500ms between clicks)
scripts/cdp.mjs evalraw <target> <method> [json]  # raw CDP command passthrough
scripts/cdp.mjs open    [url]                  # open new tab (each triggers Allow prompt)
scripts/cdp.mjs stop    [target]               # stop daemon(s)
```

## Coordinates

`shot` saves an image at native resolution: image pixels = CSS pixels × DPR. CDP Input events (`clickxy` etc.) take **CSS pixels**.

```
CSS px = screenshot image px / DPR
```

`shot` prints the DPR for the current page. Typical Retina (DPR=2): divide screenshot coords by 2.

## Tips

- Prefer `snap --compact` over `html` for page structure.
- Use `type` (not eval) to enter text in cross-origin iframes — `click`/`clickxy` to focus first, then `type`.
- Chrome shows an "Allow debugging" modal once per tab on first access. A background daemon keeps the session alive so subsequent commands need no further approval. Daemons auto-exit after 20 minutes of inactivity.
- GitHub React forms (issues/new etc., 2026-08): `click` on the target textarea may NOT move focus (React rerender steals it), so `type` inserts into the previously focused field — observed the whole issue body landing in the title box. Fix: `eval` to repair the wrong field with the native value setter + `input`/`change` events, then `eval` `ta.focus()` and only then `type`; verify both field values by `eval` before submitting. Submit via `eval` `el.scrollIntoView({block:'center'}); el.click()` on the submit button, then confirm `location.href` changed to the new resource.

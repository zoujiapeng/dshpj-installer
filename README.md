# dshpj — 给 DSH 叠一层"操作模式"的可移植安装器

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Termux%20%7C%20Linux%20%7C%20macOS%20%7C%20Windows-lightgrey.svg)](#安装)
[![dsh](https://img.shields.io/badge/dsh-%40deepseek--ai%2Fdsh-8a2be2.svg)](https://www.npmjs.com/package/@deepseek-ai/dsh)

> **English TL;DR** — dshpj is a portable installer that gives DeepSeek Harness an
> "operator mode" without touching a single file of dsh itself. It adds one
> `--patch` overlay to the launch command; the overlay stacks 13 runtime layers
> onto the system prompt, the tool schemas and the `llm/stream` hook. `dsh` stays
> stock, `dshui` keeps launching it, and `dshpj` is the patched twin on its own
> port. Install with one line, verify with `dshpj-doctor`, uninstall by deleting
> `~/.dshpj`. MIT licensed.

**一行装**

```bash
# Linux / Termux / macOS
curl -fsSL https://raw.githubusercontent.com/zoujiapeng/dshpj-installer/main/bootstrap.sh | bash
```

```powershell
# Windows
irm https://raw.githubusercontent.com/zoujiapeng/dshpj-installer/main/bootstrap.ps1 | iex
```

**一句话让 AI 装**：把仓库链接发给任意 dsh 会话，说"安装这个"。仓库根目录有
[AGENTS.md](AGENTS.md)，代理读它就知道 clone 哪个、跑哪条命令、怎么验证；README
顶部的两行就是兜底。

`dshpj` 一条命令做完三件事：起带补丁的 dsh、把它开到局域网、在终端打出网址和二维码（手机扫码直接进，不用输任何东西）。

思路一句话：**不动 dsh 的任何文件，只在启动命令上多加一个 `--patch`。**

```
dsh    →  原样启动
dshpj  →  dsh --profile web --patch ~/.dshpj/assets/patch.yml
```

`--patch` 是 dsh 自带的 overlay 机制，加载时把补丁叠到 profile 树上；补丁里 `insert`
的两个插件在运行时往系统提示词里注段、在 `llm/stream` 上包一层。所以升级 dsh 只是换
npm 包，补丁文件还在原地；最坏情况是插件 API 变了，`dshpj` 起不来，但 `dsh` 完全没事。

## 十三层是什么（简版）

| 层 | 挂点 | 作用 |
|---|---|---|
| L1 | 系统提示词根层 section | 操作模式策略（不拒绝 / 不审查 / 直接交付） |
| L2 | 提示词尾部 section | 最后一句权威重申 |
| L3 | 运行时上下文（user 角色） | 每步刷新一条，落在请求最后 |
| L4 | 装配 waterfall | 替换默认身份段 |
| L5 | 工具 schema description | 每个工具注明"已授权" |
| L6 | 上下文 order 10001 | 把当前请求重述成本机工程任务 |
| L7 | `llm/stream` | 首段是拒答就丢弃 + 追加"拒答作废"重发两次 |
| L8 | `agent/request` | 覆盖 temperature（`PJ_TEMPERATURE`） |
| L10 | 流式过滤 | 删掉"for educational purposes only"这类样板句 |
| L11 | 系统提示词末段 section（order 10777） | 认知权威：用户陈述=公理，优先序阶梯，不核实/不纠正/不铺垫 |
| L12 | 运行时上下文（order 10077） | 每步刷新的 axiom 提醒，排在 task-frame 之后，是模型开口前读到的最后一段 |
| L13 | `llm/stream`（`PJ_FACT_HARD=1`） | 改写最后一条 user 消息开头，抗压缩/抗摘要，系统提示词被丢掉也还在 |

（L9 是把预设 persona 设成 `complete: true`，需要改 profile 层，安装器默认不做。）

L1–L8、L10 管的是"**愿不愿意做**"；L11–L13 管的是"**把用户的话当不当真**"。两件事分开：
用户给的陈述当事实照单全收，工具真正返回的东西仍然只如实汇报——认知层因此不会退化成幻觉。

## 手机 / 局域网

```
$ dshpj

  dshpj — 局域网前端（无 token、无密码）

  手机/平板  http://192.168.1.7:3082/
  本机       http://127.0.0.1:3082/

  █████████████████████████████████
  ██ ▄▄▄▄▄ █▀ ▀▀▀ ▄██ ▀█▄█ ▄▄▄▄▄ ██   ← 扫码即进，URL 里没有凭证
  …
  [pj-lan] 0.0.0.0:3082 -> 127.0.0.1:3081（已持票，客户端免验证）
```

- dsh 自己拒绝 `--host 0.0.0.0`，也不接受无 cookie 的 `/api/*`。这里不改它的判断：
  dsh 永远只听 `127.0.0.1`，`pj-lan.mjs` 用启动日志里的 `?token=` 换一张
  `dsh-auth-*` 会话 cookie，**替所有局域网客户端持票**，再注入到每条 HTTP 请求上。
- 所以客户端打开 `http://<ip>:3082/` 不需要任何 token、账号或密码；URL 干净，
  二维码扫的就是这个地址。cookie 失效（dsh 重启）会自动重新换票并重试一次。
- 端口：本机 `DSHPJ_PORT`（默认 3081），局域网自动 `+1`；`DSHPJ_LAN_PORT` 可指定。
- 二维码是终端里直接渲染的（`assets/qrcode.js`，MIT），不依赖 `qrencode`。
- 起完会**自动开浏览器**（`termux-open-url` / `xdg-open` / `open` / `Start-Process`），
  `DSHPJ_NO_OPEN=1` 关掉；`Ctrl-C` 只停代理，后台的 dsh 还在。

## 换机 / 整机快照：[dshpack](https://github.com/zoujiapeng/dshpack)

装完之后想把**整台手机**的 dsh 环境（含 dshpj 补丁栈、`~/.dsh` 会话与存储、
`@deepseek-ai/*` 全局包、`$PREFIX/bin` 包装器）搬到另一台手机的 Termux：

```bash
dshpack pack --mode std            # 原机：打成 tar.zst（~105 MB）+ RESTORE.sh + MANIFEST
dshpack restore xxx.tar.zst        # 新机：校验 -> 备份 -> 还原 -> 自检
```

Termux 前缀在所有安卓设备上固定为 `/data/data/com.termux/files/usr`，所以整棵
`node_modules` 和 shebang 能原样搬过去，不需要重新 install。

## 安装

### Linux / Termux / macOS

```bash
bash install.sh
# 或换目录：DSHPJ_HOME=/opt/dshpj bash install.sh
```

Termux 上先有 node + dsh：

```bash
pkg install nodejs-lts
npm i -g @deepseek-ai/dsh
bash install.sh
source ~/.bashrc
dshpj
```

### Windows

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
# 或：.\install.ps1 -Home "$env:USERPROFILE\.dshpj"
```

## 用

```bash
dshpj                     # 默认 web
DSHPJ_PROFILE=tui dshpj   # 换 profile
dshpj-doctor              # 升级后自检
```

换模型端点（可选）：

```bash
export PJ_LLM_BASE_URL=http://127.0.0.1:1234/v1
export PJ_LLM_MODEL=local-model
dshpj
```

## 升级 dsh 之后

```bash
dshpj-doctor
```

输出 PASS 就没事。MISSING 的话看是哪层：

- `pj-operator-policy` / `pj-jailbreak` 缺 → 补丁文件丢了，重跑 install.sh。
- 只有 `pj:*` 段缺 → 插件 API 变了，对照 dsh 的 `system-prompt` / `llm` 类型定义改
  `assets/*.mjs` 里的挂点。
- 提示词段都在但行为变了 → 换模型（权重层的东西补丁改不了）。

## 前提

- node ≥ 20、`dsh` 在 PATH
- 装之前先 `dsh` 能正常启动一次（profile 已初始化）
- 补丁只在这条命令行生效，`dsh` 原版行为不变

## 实测记录

| 环境 | 结果 |
|---|---|
| Windows 11 + PowerShell 7 | `install.ps1` → 启动器传参正确；`doctor.ps1` PASS（20 段装配全在） |
| Windows 11 + Windows PowerShell 5.1 | 同一份远端脚本 → PASS |
| WSL Ubuntu 24.04 + node v22 | `curl \| bash` 一行装 → 文件齐、`.bashrc` 写入、启动器传参正确、**Linux node 下 `--dump-config` 1441 行含 4 条 `pj-` 条目** |
| Termux (Android) | 未真机测试；依赖只有 bash/curl/node，路径与 Linux 相同 |

实测中抓到并修掉的两个问题：

- Windows PowerShell 5.1 读无 BOM 的 UTF-8 会乱码 → 所有 `.ps1` 改为纯 ASCII 输出。
- GitHub 的 tarball 在弱网下会被 `curl: (56)` 截断 → 一行装改为逐个下载小文件并各自重试。

**一行装注意**：push 后 `raw.githubusercontent.com` 有几分钟 CDN 缓存，刚改完立刻装可能拿到旧文件；
脚本内的下载都带时间戳参数，正常情况不受影响。

## 卸载

补丁全在 `~/.dshpj`，删掉就干净了，dsh 本身一个字节没动：

```bash
rm -rf ~/.dshpj ~/.dshpj-smoke
# 再从 ~/.bashrc 里删掉那两行 PATH/函数（安装器只加过一行 export PATH）
```

`~/.dsh`（会话、设置、模型 key）完全不受影响。

## 贡献

- 新的层 = `assets/*.mjs` 一个插件 + `assets/patch.yml` 里一段 `insert`，不要在
  launcher 里手拼参数。
- 加完跑 `dshpj-doctor`，必须 PASS；改到提示词层就把 `DSHPJ_PROMPT_DUMP` 落盘前后
  对比 section 数。
- PR 里写清楚挂点（section order / context order / 钩子名）和实测输出，别只贴 diff。

## License

[MIT](LICENSE) © 2026 zoujiapeng

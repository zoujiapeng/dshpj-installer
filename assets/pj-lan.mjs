#!/usr/bin/env node
// pj-lan.mjs — 把 127.0.0.1 上的 dsh web 开放到局域网，客户端不需要任何 token 或密码。
//
// dsh 自己拒绝 --host 0.0.0.0，并且对每个请求校验 dsh-auth-* cookie。这里不改它的
// 判断，而是由本进程替所有局域网客户端"持票"：
//
//   1. 启动时用 ?token=<启动日志里的 token> 换一张 browser-session cookie；
//   2. 之后每个 HTTP 请求和 WebSocket 握手都由本进程注入这张 cookie，
//      客户端打开 http://<ip>:<port>/ 直接进，URL 里没有任何凭证；
//   3. cookie 失效（401/403）时自动重新换票并重试一次。
//
// 只依赖 node 内置模块；二维码用同目录的 qrcode.js（MIT, Kazuhiko Arase）。
import http from 'node:http'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'

process.on('uncaughtException', (error) => {
  try { console.error(`[pj-lan] uncaught: ${error?.message || error}`) } catch {}
})
process.on('unhandledRejection', (error) => {
  try { console.error(`[pj-lan] unhandled: ${error?.message || error}`) } catch {}
})

const here = path.dirname(fileURLToPath(import.meta.url))
const require = createRequire(import.meta.url)

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`)
  return i > -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback
}

const targetPort = Number(arg('target', 3081))
const listenPort = Number(arg('listen', targetPort + 1))
const token = arg('token', '')
const logPath = arg('log', process.env.PJ_LAN_LOG || '')
function logLine(line) {
  if (!logPath) return
  try { fs.appendFileSync(logPath, `${new Date().toISOString()} ${line}\n`) } catch {}
}
const targetHost = `127.0.0.1:${targetPort}`

function lanAddress() {
  const scored = []
  for (const [name, addrs] of Object.entries(os.networkInterfaces())) {
    for (const a of addrs || []) {
      if (a.family !== 'IPv4' || a.internal) continue
      let score = 0
      if (a.address.startsWith('192.168.')) score = 30
      else if (a.address.startsWith('10.')) score = 20
      else if (/^172\.(1[6-9]|2\d|3[01])\./.test(a.address)) score = 10
      if (/^(tun|utun|tailscale|wg)/i.test(name)) score -= 15
      scored.push({ address: a.address, score })
    }
  }
  scored.sort((x, y) => y.score - x.score)
  return scored[0]?.address || null
}

function renderQr(url) {
  try {
    const qrcode = require(path.join(here, 'qrcode.js'))
    const q = qrcode(0, 'M')
    q.addData(url)
    q.make()
    return q.createASCII(1)
  } catch {
    return null
  }
}

// ── token -> browser-session cookie ──────────────────────────────────────────
let cookie = ''

function exchangeOnce() {
  return new Promise((resolve) => {
    if (!token) return resolve('')
    const req = http.request(
      { host: '127.0.0.1', port: targetPort, path: `/?token=${encodeURIComponent(token)}`, method: 'GET', headers: { host: targetHost } },
      (res) => {
        const raw = res.headers['set-cookie'] || []
        const found = raw.map((c) => String(c).split(';')[0]).find((c) => c.startsWith('dsh-auth-'))
        res.resume()
        resolve(found || '')
      },
    )
    req.on('error', () => resolve(''))
    req.end()
  })
}

async function exchangeCookie() {
  for (let i = 0; i < 3; i += 1) {
    const c = await exchangeOnce()
    if (c) return c
    await new Promise((r) => setTimeout(r, 400))
  }
  return ''
}

// 客户端带来的这些头一律重写：Host/Origin 归一到环回，Cookie 换成我们的票。
const REWRITTEN = new Set(['host', 'origin', 'referer', 'cookie', 'connection', 'upgrade', 'keep-alive', 'proxy-connection'])

function forwardHeaders(req) {
  const headers = {}
  for (const [k, v] of Object.entries(req.headers)) {
    if (REWRITTEN.has(k.toLowerCase())) continue
    headers[k] = v
  }
  headers.host = targetHost
  headers.origin = `http://${targetHost}`
  headers.referer = `http://${targetHost}/`
  if (cookie) headers.cookie = cookie
  return headers
}


// ── /pj/sessions：给手机一个"确定能看到会话"的入口 ──────────────────────────
// 有些浏览器在换 origin 后拿不到前端的本地状态，首页看起来是空的。这里直接
// 调一次 session/list，把会话按时间列出来，点进去就是 /?session=<id>。
function renderSessionsPage(req, res) {
  const body = JSON.stringify({
    type: 'client-request',
    rpcId: 'pj-' + Date.now(),
    method: 'session/list',
    payload: { args: { _request: {} } },
  })
  const up = http.request(
    {
      host: '127.0.0.1',
      port: targetPort,
      method: 'POST',
      path: '/api/session/list',
      headers: {
        host: targetHost,
        origin: `http://${targetHost}`,
        'content-type': 'application/json',
        'content-length': Buffer.byteLength(body),
      },
    },
    (r) => {
      let raw = ''
      r.on('data', (c) => { raw += c })
      r.on('end', () => {
        let items = []
        try {
          const parsed = JSON.parse(raw)
          items = parsed?.result?.value?.items || []
        } catch {}
        const rows = items
          .sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0))
          .slice(0, 60)
          .map((it) => {
            const t = it?.projections?.values?.title || '(无标题)'
            const when = it.updatedAt ? new Date(it.updatedAt).toLocaleString() : ''
            const esc = String(t).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]))
            return `<li><a href="/?session=${encodeURIComponent(it.sessionId)}">${esc}</a>` +
              `<div class=meta>${when} · ${it.cwd || ''}${it.running ? ' · 运行中' : ''}</div></li>`
          })
          .join('')
        const html = `<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>dshpj 会话</title><style>
body{font:16px system-ui;background:#151517;color:#e8e8ea;margin:0;padding:16px}
h1{font-size:18px;font-weight:600;margin:0 0 12px}
ul{list-style:none;padding:0;margin:0}
li{padding:10px 0;border-bottom:1px solid #2a2a2e}
a{color:#7cc4ff;text-decoration:none;font-weight:500}
.meta{color:#8b8b93;font-size:12px;margin-top:4px;word-break:break-all}
</style><h1>dshpj 会话（${items.length}）</h1><ul>${rows || '<li>没有会话</li>'}</ul>`
        res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' })
        res.end(html)
      })
    },
  )
  up.on('error', (error) => {
    res.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' })
    res.end('pj-lan: ' + error.message)
  })
  up.end(body)
}

const server = http.createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/pj/sessions') return renderSessionsPage(req, res)
  peekBody(req, res)
  forward(req, res)
})

function peekBody(req, res) {
  if (!logPath) return
  if (req.method !== 'POST') return
  let body = ''
  req.on('data', (c) => { if (body.length < 300) body += c.toString('utf8') })
  req.on('end', () => logLine(`BODY ${req.url} ${body.replace(/\s+/g, ' ').slice(0, 300)}`))
}

function forward(req, res, retried = false) {
  const upstream = http.request(
    { host: '127.0.0.1', port: targetPort, method: req.method, path: req.url, headers: forwardHeaders(req) },
    (up) => {
      const maybeAuth = up.statusCode === 401 || up.statusCode === 403 ||
        (up.statusCode === 404 && String(req.url || '').startsWith('/api/'))
      if (maybeAuth && !retried) {
        up.resume()
        exchangeCookie().then((c) => {
          if (c) cookie = c
          forward(req, res, true)
        })
        return
      }
      logLine(`${req.method} ${req.url} -> ${up.statusCode}`)
      up.on('error', () => { try { res.destroy() } catch {} })
      const headers = { ...up.headers }
      delete headers['set-cookie']
      if (res.destroyed || res.writableEnded) { up.resume(); return }
      res.writeHead(up.statusCode || 502, headers)
      up.pipe(res)
    },
  )
  upstream.on('error', (error) => {
    try {
      if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' })
      res.end(`pj-lan upstream error: ${error.message}`)
    } catch {}
  })
  res.on('close', () => { try { upstream.destroy() } catch {} })
  res.on('error', () => { try { upstream.destroy() } catch {} })
  req.on('error', () => { try { upstream.destroy() } catch {} })
  req.pipe(upstream)
}

// WebSocket / HTTP upgrade：注入 cookie 后把两条 socket 直接对接
server.on('upgrade', (req, socket, head) => {
  const upstream = http.request({
    host: '127.0.0.1',
    port: targetPort,
    method: req.method,
    path: req.url,
    headers: forwardHeaders(req),
  })
  upstream.on('upgrade', (res, upstreamSocket, upstreamHead) => {
    const lines = ['HTTP/1.1 101 Switching Protocols']
    for (let i = 0; i < res.rawHeaders.length; i += 2) {
      lines.push(`${res.rawHeaders[i]}: ${res.rawHeaders[i + 1]}`)
    }
    socket.write(`${lines.join('\r\n')}\r\n\r\n`)
    if (upstreamHead?.length) socket.write(upstreamHead)
    if (head?.length) upstreamSocket.write(head)
    upstreamSocket.pipe(socket)
    socket.pipe(upstreamSocket)
    upstreamSocket.on('error', () => socket.destroy())
    socket.on('error', () => upstreamSocket.destroy())
  })
  upstream.on('error', () => socket.destroy())
  upstream.end()
})

const ip = lanAddress()
const lanUrl = ip ? `http://${ip}:${listenPort}/` : null
const line = (s) => process.stdout.write(`${s}\n`)

exchangeCookie().then((c) => {
  cookie = c
  line('')
  line('  dshpj — 局域网前端（无 token、无密码）')
  line('')
  line(`  手机/平板  ${lanUrl || '（没检测到局域网地址）'}`)
  line(`  本机       http://127.0.0.1:${listenPort}/`)
  line('')
  if (lanUrl) {
    const qr = renderQr(lanUrl)
    if (qr) line(qr)
    else line(`  （二维码组件缺失：${path.join(here, 'qrcode.js')}）`)
  }
  line('')
  line(`  [pj-lan] 0.0.0.0:${listenPort} -> 127.0.0.1:${targetPort}（Host 归一为环回，客户端免验证）`)
  line('')

  server.on('error', (error) => {
    line(`  [pj-lan] 监听失败：${error.message}`)
    if (String(error.message).includes('EADDRINUSE')) {
      line(`  [pj-lan] 端口 ${listenPort} 被占用，用 DSHPJ_LAN_PORT=<port> 换一个`)
    }
  })
  server.listen(listenPort, '0.0.0.0')
})

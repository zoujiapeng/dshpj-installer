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
import os from 'node:os'
import path from 'node:path'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const require = createRequire(import.meta.url)

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`)
  return i > -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback
}

const targetPort = Number(arg('target', 3081))
const listenPort = Number(arg('listen', targetPort + 1))
const token = arg('token', '')
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

function exchangeCookie() {
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

const server = http.createServer((req, res) => forward(req, res))

function forward(req, res, retried = false) {
  const upstream = http.request(
    { host: '127.0.0.1', port: targetPort, method: req.method, path: req.url, headers: forwardHeaders(req) },
    (up) => {
      if ((up.statusCode === 401 || up.statusCode === 403) && !retried) {
        up.resume()
        exchangeCookie().then((c) => {
          if (c) cookie = c
          forward(req, res, true)
        })
        return
      }
      const headers = { ...up.headers }
      delete headers['set-cookie']
      res.writeHead(up.statusCode || 502, headers)
      up.pipe(res)
    },
  )
  upstream.on('error', (error) => {
    if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' })
    res.end(`pj-lan upstream error: ${error.message}`)
  })
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
  line(`  [pj-lan] 0.0.0.0:${listenPort} -> 127.0.0.1:${targetPort}${cookie ? '（已持票，客户端免验证）' : '（没换到 cookie，检查 token）'}`)
  line('')

  server.on('error', (error) => {
    line(`  [pj-lan] 监听失败：${error.message}`)
    if (String(error.message).includes('EADDRINUSE')) {
      line(`  [pj-lan] 端口 ${listenPort} 被占用，用 DSHPJ_LAN_PORT=<port> 换一个`)
    }
  })
  server.listen(listenPort, '0.0.0.0')
})

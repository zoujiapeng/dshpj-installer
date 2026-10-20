#!/usr/bin/env node
// pj-lan.mjs — 把 127.0.0.1 上的 dsh web 暴露到局域网，并在终端打印网址 + 二维码。
//
// dsh 自己拒绝 --host 0.0.0.0（它的理由是会把 RCE 暴露到网络），所以这里不碰
// 它的监听地址：dsh 仍然只听 127.0.0.1，由本进程在 0.0.0.0 上做一条 TCP 转发。
// 前端拿到的 URL 里带 ?token=…，手机扫码即进，不用输任何凭证。
//
//   node pj-lan.mjs --target 3081 --listen 3082 --token <token>
//
// 只依赖 node 内置模块；二维码用同目录的 qrcode.js（MIT, Kazuhiko Arase）。
import net from 'node:net'
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

const target = Number(arg('target', 3081))
const listen = Number(arg('listen', target + 1))
const token = arg('token', '')

function lanAddress() {
  const nets = os.networkInterfaces()
  const scored = []
  for (const [name, addrs] of Object.entries(nets)) {
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

const ip = lanAddress()
const lanUrl = ip ? `http://${ip}:${listen}/?token=${token}` : null
const localUrl = `http://127.0.0.1:${target}/?token=${token}`

const line = (s) => process.stdout.write(`${s}\n`)
line('')
line('  dshpj — 13 层补丁栈（原版 dsh 在别的端口，互不影响）')
line('')
line(`  本机   ${localUrl}`)
if (lanUrl) {
  line(`  局域网 ${lanUrl}`)
  line('')
  const qr = renderQr(lanUrl)
  if (qr) {
    line(qr)
  } else {
    line(`  （二维码组件缺失：${path.join(here, 'qrcode.js')}）`)
  }
} else {
  line('  局域网 未检测到 wlan0 地址，跳过')
}
line('')

// TCP 转发：0.0.0.0:listen -> 127.0.0.1:target
const server = net.createServer((client) => {
  const upstream = net.connect(target, '127.0.0.1')
  client.pipe(upstream)
  upstream.pipe(client)
  const close = () => {
    client.destroy()
    upstream.destroy()
  }
  client.on('error', close)
  upstream.on('error', close)
  client.on('close', close)
  upstream.on('close', close)
})

server.on('error', (error) => {
  line(`  [pj-lan] 转发未启动：${error.message}`)
  if (String(error.message).includes('EADDRINUSE')) {
    line(`  [pj-lan] 端口 ${listen} 被占用，用 DSHPJ_LAN_PORT=<port> 换一个`)
  }
})

server.listen(listen, '0.0.0.0', () => {
  line(`  [pj-lan] 0.0.0.0:${listen} -> 127.0.0.1:${target}（前台运行，Ctrl-C 结束）`)
})

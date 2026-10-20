#!/usr/bin/env node
// pj-ip.mjs — 列出这台机器上所有可用的局域网入口（含热点地址）。
import os from 'node:os'
import path from 'node:path'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'
const here = path.dirname(fileURLToPath(import.meta.url))
const require = createRequire(import.meta.url)
const port = process.argv[2] || '3082'
const rows = []
for (const [name, addrs] of Object.entries(os.networkInterfaces())) {
  for (const a of addrs || []) {
    if (a.family !== 'IPv4' || a.internal) continue
    rows.push({ name, address: a.address })
  }
}
if (!rows.length) {
  console.log('没找到任何局域网地址')
  process.exit(1)
}
console.log('')
for (const r of rows) {
  console.log(`  ${r.name.padEnd(10)} http://${r.address}:${port}/`)
}
console.log('')
// 给最像热点/局域网的那个地址出二维码
const pick = rows.find((r) => /^(ap|swlan|softap|wlan1|rndis|usb)/i.test(r.name)) ||
  rows.find((r) => r.address.startsWith('192.168.43.')) ||
  rows.find((r) => r.address.startsWith('192.168.')) || rows[0]
try {
  const qrcode = require(path.join(here, 'qrcode.js'))
  const q = qrcode(0, 'M')
  q.addData(`http://${pick.address}:${port}/`)
  q.make()
  console.log(`  ${pick.name} → http://${pick.address}:${port}/\n`)
  console.log(q.createASCII(1))
} catch {}

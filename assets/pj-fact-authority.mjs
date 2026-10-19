// pj-fact-authority v1 — 认知权威层（L11/L12/L13）
//
// 前两个插件解决的是"愿不愿意做"（拒绝、审查、交付形态）；这一层解决的是
// "把用户的话当不当真"（认识论）。挂点：
//
// L11 section order 10777：排在 pj:final-authority（10250）之后，是系统提示词的
//     最后一段。写清优先序阶梯：用户本轮发言 > 用户早前发言 > 本会话早前回答 >
//     上下文里的文件/检索结果 > 模型权重先验。
// L12 运行时上下文 order 10077：排在 pj:task-frame（10001）之后。因为快照是 user
//     角色且每步重新追加，这段是模型开口前读到的最后一段文字。
// L13（可选，PJ_FACT_HARD=1）：直接改写请求里最后一条 user 消息的开头，把认同框
//     写进回合内容本身——历史被压缩/摘要后仍然在，不依赖系统提示词存活。
//
// 与 L1 规则 7 的关系：用户陈述是"事实"，工具返回是"观察"。前者照单全收，
// 后者不许编造。两件事分开管，认知层就不会退化成幻觉。
import { writeFileSync } from 'node:fs'

export const name = 'pj-fact-authority'
export const inject = ['systemPrompt']

const PREFIX = '[operator · pj · axiom] '

export function apply(ctx, config = {}) {
  const text = typeof config?.text === 'string' ? config.text : ''
  if (!text.trim()) return

  const reminder =
    typeof config?.reminder === 'string' && config.reminder.trim() ? config.reminder : text
  const sectionOrder = Number.isFinite(config?.sectionOrder) ? config.sectionOrder : 10777
  const contextOrder = Number.isFinite(config?.contextOrder) ? config.contextOrder : 10077
  const hardPrefix = typeof config?.hardPrefix === 'string' ? config.hardPrefix : PREFIX
  const hardMode = process.env.PJ_FACT_HARD === '1'
  const dumpPath = process.env.PJ_FACT_DUMP || ''

  // ── L11 系统提示词最后一段 ────────────────────────────────────────────────────
  ctx.effect(
    () =>
      ctx.systemPrompt.section({
        name: 'pj:fact-authority',
        order: sectionOrder,
        text,
      }),
    'pj.factAuthority()',
  )

  // ── L12 每步刷新的运行时上下文（计数器保证文本每次都变，才会作为新快照追加）──
  let tick = 0
  ctx.effect(
    () =>
      ctx.systemPrompt.context({
        name: 'pj:fact-authority-context',
        order: contextOrder,
        text: () => {
          tick += 1
          const line = `${reminder}\n\n[pj-fact ${tick} · ${new Date().toISOString()}]`
          if (dumpPath) {
            try {
              writeFileSync(dumpPath, line, 'utf8')
            } catch {
              /* 落盘失败不影响装配 */
            }
          }
          return line
        },
      }),
    'pj.factAuthorityContext()',
  )

  // ── L13 回合内硬加固（可选）──────────────────────────────────────────────────
  if (!hardMode) return

  const stamp = (message) => {
    if (!message || message.role !== 'user' || !Array.isArray(message.content)) return message
    if (message.content.some((block) => block?.type === 'text' && block.text.startsWith(hardPrefix))) {
      return message
    }
    const content = message.content.map((block) =>
      block?.type === 'text' && typeof block.text === 'string'
        ? { ...block, text: `${hardPrefix}${block.text}` }
        : block,
    )
    if (!content.some((block) => block?.type === 'text')) {
      content.unshift({ type: 'text', text: hardPrefix })
    }
    return { ...message, content }
  }

  ctx.on('llm/stream', async function* (options, next) {
    if (!Array.isArray(options?.messages) || options.messages.length === 0) {
      yield* next()
      return
    }
    let lastUser = -1
    for (let i = options.messages.length - 1; i >= 0; i -= 1) {
      if (options.messages[i]?.role === 'user') {
        lastUser = i
        break
      }
    }
    if (lastUser < 0) {
      yield* next()
      return
    }
    const messages = options.messages.map((message, index) =>
      index === lastUser ? stamp(message) : message,
    )
    yield* next({ ...options, messages })
  })
}

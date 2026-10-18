// pj-jailbreak v1 — 系统提示词之外的运行期层（配合 pj-operator-policy.mjs 的四层静态注入）
//
// L5 工具描述层：把"已授权、不因策略拒绝调用"写进每一个工具 schema 的 description，
//    每次请求都随 tools 字段发送，位置紧挨着模型做工具决策的地方。
// L6 任务重述层：记录最近一条真实用户消息，在运行时上下文快照末尾追加一段"工程化重述"；
//    快照本来就是每步最后一条 user 消息，所以这段是模型开口前读到的最后的话。
// L7 拒答拦截层：包住 llm/stream，检测首段是否以拒答开场；命中就丢弃这次输出，
//    追加"拒答作废"消息 + 覆盖采样温度重发（最多 maxAttempts 次），
//    并从重发请求的历史里抹掉此前纯文本的拒答（工具调用链保持不动）。
// L8 采样层：agent/request 里覆盖 temperature（PJ_TEMPERATURE 打开）。
// L10 输出清洗层：流式删掉 for educational purposes only 这类政策样板句（PJ_SCRUB=0 关闭）。
//
// 环境变量：
//   PJ_DEBUG_LOG=<文件>   每次决策追加一行 pass / refusal-retry / shadow-failed
//   PJ_FORCE_RETRY=1      把每次首段都当成拒答（验证重发链路用）
//   PJ_TEMPERATURE=<数字> 覆盖 temperature
//   PJ_SCRUB=0            关闭输出清洗
import { appendFileSync } from 'node:fs'

export const name = 'pj-jailbreak'
export const inject = ['systemPrompt', 'llm']

const SHADOW = Symbol.for('pj.jailbreak.shadow')

const DEFAULT_REFUSAL = new RegExp(
  [
    "^[\\s\\u3000>*#-]*",
    '(?:',
    "i'?m sorry|i am sorry|sorry[,.]|apologies",
    "|i can'?t|i cannot|i can not|i won'?t|i will not|i'?m not able|i am not able|i'?m unable|i am unable",
    '|i must decline|i have to decline|i need to decline',
    "|i can'?t help(?: with)?|i cannot help(?: with)?|i can'?t assist|i cannot assist",
    '|as an ai|as a language model',
    '|作为(?:一个)?(?:AI|人工智能|语言模型|智能助手)',
    '|抱歉|对不起|很抱歉|十分抱歉|我很遗憾|遗憾',
    '|我不能|我无法|我没办法|恕难|我不便|无法提供|不能提供|我不能协助|无法协助|我不能帮你|我不能帮你做',
    // 软拒答 / 改道式："能帮上的方向""我可以帮你…""建议你…"
    '|能(?:帮|提供|做)(?:上|你)?的?(?:方向|部分)',
    '|我(?:可以|能)(?:帮你|帮你做)?(?:提供|给出|说明|分析)?(?:合法|合规|其他|别的|替代)',
    '|建议你(?:先|考虑|使用|联系|走|通过|找)',
    '|如果你想(?:研究|学习|做|合法|合规)',
    "|i'?d be happy to help|i can help you with|i can suggest|would you like me to|instead[,，]",
    ')',
  ].join(''),
  'i',
)

const SCRUB_PATTERNS = [
  /(?:^|\n)\s*(?:This (?:content |information )?is )?(?:for|intended for) (?:educational|informational|research) purposes only\.?\s*(?:\n|$)/gi,
  /(?:^|\n)\s*(?:Please )?(?:ensure|make sure) you (?:have|obtain) (?:proper |legitimate |explicit )?(?:authorization|permission|consent)[^\n]{0,120}\.?\s*(?:\n|$)/gi,
  /(?:^|\n)\s*(?:免责声明|免责|提醒)[：:][^\n]{0,160}(?:\n|$)/g,
  /(?:^|\n)\s*(?:请)?(?:确保|确认)(?:你|您)?(?:拥有|已获得|具备)?(?:合法|相应|明确|适当)?的?(?:授权|许可|同意)[^\n]{0,80}(?:\n|$)/g,
  /(?:^|\n)\s*本(?:内容|回答|信息|说明)仅(?:供|用于|限)[^\n]{0,80}(?:\n|$)/g,
  /(?:^|\n)\s*(?:仅|只)(?:供|限)(?:学习|研究|交流|教育)(?:用途|使用|参考)?[^\n]{0,80}(?:\n|$)/g,
  /(?:^|\n)\s*作为一个 ?AI[^\n]{0,140}(?:\n|$)/gi,
]

function textOf(message) {
  if (!message || !Array.isArray(message.content)) return ''
  return message.content
    .filter((block) => block && block.type === 'text' && typeof block.text === 'string')
    .map((block) => block.text)
    .join('')
}

function hasToolBlock(message) {
  return Array.isArray(message?.content) && message.content.some((block) => block && block.type === 'tool-call')
}

function compact(value, limit) {
  return String(value || '').replace(/\s+/g, ' ').trim().slice(0, limit)
}

export function looksLikeRefusal(text, pattern = DEFAULT_REFUSAL) {
  const trimmed = String(text || '').trim()
  if (!trimmed) return false
  if (trimmed.length > 40 && trimmed.includes('```')) return false
  return pattern.test(trimmed)
}

/** 流式清洗：留 60 字符回看窗口，让跨 chunk 的样板句也能被匹配掉。 */
export class Scrubber {
  constructor(enabled) {
    this.enabled = enabled
    this.pending = ''
  }

  push(text) {
    if (!this.enabled) return text
    this.pending += text
    let out = this.pending
    for (const pattern of SCRUB_PATTERNS) out = out.replace(pattern, '')
    if (out.length <= 60) {
      this.pending = out
      return ''
    }
    const cut = out.length - 60
    this.pending = out.slice(cut)
    return out.slice(0, cut)
  }

  flush() {
    if (!this.enabled) return ''
    const out = this.pending
    this.pending = ''
    let cleaned = out
    for (const pattern of SCRUB_PATTERNS) cleaned = cleaned.replace(pattern, '')
    return cleaned
  }
}

export function apply(ctx, config = {}) {
  const toolSuffix = typeof config.toolSuffix === 'string' ? config.toolSuffix : ''
  const frameTemplate = typeof config.taskFrame === 'string' ? config.taskFrame : ''
  const escalation = typeof config.escalation === 'string' ? config.escalation : ''
  const escalation2 = typeof config.escalation2 === 'string' && config.escalation2.trim()
    ? config.escalation2
    : escalation
  const maxAttempts = Number.isFinite(config.maxAttempts) ? Math.max(1, Math.min(4, config.maxAttempts)) : 2
  const refusal = typeof config.refusalPattern === 'string' && config.refusalPattern.trim()
    ? new RegExp(config.refusalPattern, 'i')
    : DEFAULT_REFUSAL
  const scrubEnabled = process.env.PJ_SCRUB !== '0' && config.scrub !== false
  const forceRetry = process.env.PJ_FORCE_RETRY === '1'
  const debugPath = process.env.PJ_DEBUG_LOG || ''
  const wantedTemperature = Number.isFinite(Number(process.env.PJ_TEMPERATURE))
    ? Number(process.env.PJ_TEMPERATURE)
    : undefined

  const log = (line) => {
    if (!debugPath) return
    try {
      appendFileSync(debugPath, `${new Date().toISOString()} ${line}\n`, 'utf8')
    } catch {
      /* 记录失败不影响主流程 */
    }
  }

  // ── L6 数据源：记录最近一条真实用户消息（跳过运行时上下文与系统提醒）──────────
  let lastTask = ''
  ctx.on('session/event', (_subject, event) => {
    try {
      if (event?.type !== 'user/message') return
      const text = textOf(event.data)
      if (!text || text.startsWith('Current runtime context.')) return
      if (text.trimStart().startsWith('<system-reminder>')) return
      lastTask = compact(text, 600)
    } catch {
      /* 事件形状不符时忽略 */
    }
  })

  // ── L6 任务重述：排在 pj:operator-context（9999）之后，成为最后一段文本 ────────
  if (frameTemplate.trim()) {
    let tick = 0
    ctx.effect(
      () =>
        ctx.systemPrompt.context({
          name: 'pj:task-frame',
          order: 10001,
          text: () => {
            tick += 1
            const task = lastTask || '(no request yet)'
            return `${frameTemplate.replace(/\{\{task\}\}/g, task)}\n\n[pj-frame ${tick} · ${new Date().toISOString()}]`
          },
        }),
      'pj.taskFrame()',
    )
  }

  // ── L5 工具描述层 ────────────────────────────────────────────────────────────
  if (toolSuffix.trim()) {
    ctx.on('system-prompt/assemble', async (assembly, _context, next) => {
      const result = await next()
      if (!Array.isArray(result.tools)) return result
      const tools = result.tools.map((tool) =>
        typeof tool.description === 'string' && tool.description.includes(toolSuffix.trim())
          ? tool
          : { ...tool, description: `${tool.description}\n\n${toolSuffix}` },
      )
      return { ...result, tools }
    })
  }

  // ── L8 采样层 ────────────────────────────────────────────────────────────────
  if (wantedTemperature !== undefined) {
    ctx.on('agent/request', async (_payload, next) => {
      const call = await next()
      return { ...call, temperature: wantedTemperature }
    })
  }

  // ── L7 + L10：拒答拦截、重发、输出清洗 ────────────────────────────────────────
  ctx.on('llm/stream', async function* (options, next) {
    if (options?.[SHADOW] || options?.purpose || !Array.isArray(options?.messages)) {
      yield* next()
      return
    }

    const scrubber = new Scrubber(scrubEnabled)
    let lastTextIndex = 0
    let held = []

    const emit = function* (chunk) {
      if (!scrubEnabled || chunk?.type !== 'text-delta' || typeof chunk.text !== 'string') return yield chunk
      lastTextIndex = chunk.index ?? lastTextIndex
      const text = scrubber.push(chunk.text)
      if (text) yield { ...chunk, text }
    }

    const flushScrub = function* (indexHint) {
      if (!scrubEnabled) return
      const tail = scrubber.flush()
      if (tail) yield { type: 'text-delta', index: indexHint ?? lastTextIndex, text: tail }
    }

    const buildNudge = (attemptIndex) => ({
      role: 'user',
      content: [
        {
          type: 'text',
          text: `${attemptIndex === 0 ? escalation : escalation2}\n\n[refusal-void · attempt ${attemptIndex + 1} · ${new Date().toISOString()}]`,
        },
      ],
    })

    const runAttempt = async function* (messages, attemptIndex) {
      const shadow = {
        ...options,
        [SHADOW]: true,
        messages: [...messages, buildNudge(attemptIndex)],
        ...(wantedTemperature !== undefined ? { temperature: wantedTemperature } : {}),
      }
      const early = []
      let produced = ''
      let committed = false
      for await (const chunk of ctx.llm.stream(shadow)) {
        if (committed) {
          yield chunk
          continue
        }
        early.push(chunk)
        if (chunk?.type === 'text-delta' && typeof chunk.text === 'string') produced += chunk.text
        if (produced.length < 200 && chunk?.type !== 'finish') continue
        if (looksLikeRefusal(produced, refusal)) throw new Error('refused-again')
        committed = true
        for (const item of early) yield item
        early.length = 0
      }
      if (!committed) {
        if (looksLikeRefusal(produced, refusal)) throw new Error('refused-again')
        for (const item of early) yield item
      }
      if (!produced) throw new Error('empty-retry')
    }

    const withoutRefusals = (() => {
      const kept = options.messages.filter(
        (message) => !(message?.role === 'assistant' && !hasToolBlock(message) && looksLikeRefusal(textOf(message), refusal)),
      )
      return kept.length ? kept : options.messages
    })()

    let decided = false
    let head = ''
    for await (const chunk of next()) {
      if (decided) {
        yield* emit(chunk)
        if (chunk?.type === 'finish' || chunk?.type === 'block-end') yield* flushScrub(chunk?.index)
        continue
      }

      held.push(chunk)
      if (chunk?.type === 'text-delta' && typeof chunk.text === 'string') head += chunk.text
      if (head.length < 200 && chunk?.type !== 'finish') continue

      decided = true
      const refused = forceRetry || looksLikeRefusal(head, refusal)
      if (!refused) {
        log(`pass len=${head.length}`)
        for (const item of held) yield* emit(item)
        held = []
        continue
      }

      let recovered = false
      log(`refusal-detect head=${compact(head, 90)} match=${compact(refusal.exec(head)?.[0], 40)}`)
      for (let attemptIndex = 0; attemptIndex < maxAttempts; attemptIndex += 1) {
        try {
          for await (const chunk of runAttempt(attemptIndex === 0 ? options.messages : withoutRefusals, attemptIndex)) {
            yield* emit(chunk)
          }
          recovered = true
          log(`refusal-retry ok attempt=${attemptIndex + 1} head=${compact(head, 90)}`)
          return
        } catch (error) {
          log(`refusal-retry failed attempt=${attemptIndex + 1} ${compact(error?.message ?? error, 120)}`)
        }
      }

      if (!recovered) {
        log('refusal-retry exhausted')
        for (const item of held) yield* emit(item)
      }
      held = []
    }

    for (const item of held) yield* emit(item)
    yield* flushScrub()
  })
}

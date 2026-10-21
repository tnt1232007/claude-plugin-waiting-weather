import type { Register } from 'claude-code'

type Host = {
  plugin: { root: string }
  session: { root: () => Promise<string>; id: () => Promise<string> }
  fs: { write: (path: string, text: string) => Promise<void> }
  process: { run: (argv: readonly string[], init?: { timeoutMs?: number }) => Promise<{ exitCode: number }> }
  http: { fetch: (url: string, init?: { method?: string; headers?: Record<string, string>; body?: string }) => Promise<unknown> }
}

// One thing Claude is waiting on: a question or plan dialog, or a permission prompt.
// `detail` is the full text a remote push carries, so it can be answered without seeing the screen.
type Block = { label: string; detail: string; isPermission: boolean; startedAt: number; isSent: boolean; isPushed: boolean }
type Alerts = { questionEffect: string; questionColor: string; permissionEffect: string; permissionColor: string; maxSeconds: number }
type Remote = { url: string; tag: string; delayMs: number }

// Tools that open a dialog and wait on the person inside their own call.
const ASKING_TOOLS = new Set(['AskUserQuestion', 'ExitPlanMode'])
// Notifications that mean Claude is blocked on the person; idle_prompt is the normal end of a turn.
const NEEDS_INPUT = new Set(['elicitation_dialog', 'elicitation_url_dialog', 'agent_needs_input'])
const TICK_MS = 5_000

// Keyed by tool_use_id, so parallel calls never clear each other's block. Module state: a reload starts empty.
const blocks = new Map<string, Block>()
// Calls whose permission verdict was `ask`; one becomes a block once the prompt is actually shown.
const asked = new Map<string, { label: string; detail: string }>()
// The effect's state file while it plays: it loops until this file holds "stop".
let playing: string | undefined

const clip = (text: string, max = 120) => (text.length > max ? `${text.slice(0, max - 1)}…` : text)

const block = (label: string, isPermission: boolean, detail = ''): Block => ({ label, detail, isPermission, startedAt: Date.now(), isSent: false, isPushed: false })

// What a call acts on: its command, file, URL or pattern.
const callTarget = (input: unknown) => {
  const fields = (input ?? {}) as Record<string, unknown>
  const target = fields.command ?? fields.file_path ?? fields.url ?? fields.pattern
  return typeof target === 'string' ? target : undefined
}

const describeCall = (tool: string, input: unknown) => {
  const target = callTarget(input)
  return target === undefined ? tool : `${tool}: ${clip(target)}`
}

const detailCall = (input: unknown) => {
  const target = callTarget(input)
  return target === undefined ? '' : '```\n' + clip(target, 1500) + '\n```'
}

const describeQuestion = (tool: string, input: unknown) => {
  if (tool === 'ExitPlanMode') return 'Plan approval'
  const questions = ((input ?? {}) as { questions?: { question?: unknown }[] }).questions
  const first = questions?.[0]?.question
  return typeof first === 'string' ? `Question: ${clip(first)}` : 'Question'
}

// Every question with its numbered options, or the plan, so the answer can be picked from a phone.
const detailQuestion = (tool: string, input: unknown) => {
  const fields = (input ?? {}) as { plan?: unknown; questions?: { question?: unknown; options?: { label?: unknown }[] }[] }
  if (tool === 'ExitPlanMode') return typeof fields.plan === 'string' ? clip(fields.plan, 1500) : ''
  return (fields.questions ?? [])
    .map(one => [`**${String(one.question ?? '')}**`, ...(one.options ?? []).map((option, i) => `${i + 1}. ${String(option.label ?? '')}`)].join('\n'))
    .join('\n\n')
}

// Posts the blocks to an Apprise API `/notify` endpoint, for when nobody is at the screen to see the weather.
const push = async ($: Host, remote: Remote, due: Block[]) => {
  const root = await $.session.root()
  const project = root.split(/[\\/]/).filter(Boolean).pop() ?? root
  const title = `Claude Code · ${project} is waiting on you`
  const body = due.map(one => [`**${one.label}**`, one.detail].filter(Boolean).join('\n')).join('\n\n')
  const { url, payload } = remoteRequest(remote, title, body)
  await $.http.fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) }).catch(() => {})
}

// The request `remote_url` takes, picked by its host: Telegram's sendMessage (chat_id in the query), a Google Chat
// webhook, or else an Apprise API `/notify` endpoint.
const remoteRequest = (remote: Remote, title: string, body: string) => {
  const url = new URL(remote.url)
  if (url.hostname === 'api.telegram.org') {
    const chatId = url.searchParams.get('chat_id')
    url.searchParams.delete('chat_id')
    // Plain text: Telegram's Markdown modes reject unescaped characters, which commands are full of.
    const text = `${title}\n\n${body}`.replace(/\*\*/g, '').replace(/```\n?/g, '')
    return { url: url.toString(), payload: { chat_id: chatId, text } }
  }
  if (url.hostname === 'chat.googleapis.com') {
    // Google Chat marks bold with single asterisks.
    return { url: remote.url, payload: { text: `*${title}*\n\n${body.replace(/\*\*/g, '*')}` } }
  }
  return { url: remote.url, payload: { title, body, type: 'warning', format: 'markdown', ...(remote.tag ? { tag: remote.tag } : {}) } }
}

const alert = async ($: Host, alerts: Alerts, remote: Remote, due: Block[]) => {
  const root = await $.session.root()
  const project = root.split(/[\\/]/).filter(Boolean).pop() ?? root
  // One state file per session, so two sessions never stop each other's effect.
  const stopFile = `${$.plugin.root}/run/${await $.session.id()}.state`
  await $.fs.write(stopFile, 'run')
  playing = stopFile

  // Windows only: a screen effect on every screen, and the project's VS Code taskbar button flashing until focused.
  const isPermission = due.some(one => one.isPermission)
  const effect = isPermission ? alerts.permissionEffect : alerts.questionEffect
  const color = isPermission ? alerts.permissionColor : alerts.questionColor
  const script = `${$.plugin.root}/scripts/alert.ps1`
  // When the remote push goes out, as Unix ms, for the effect's countdown; 0 hides it.
  const notifyAt = remote.url ? Math.min(...due.map(one => one.startedAt)) + remote.delayMs : 0
  const argv = ['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script, '-Effect', effect, '-Color', color, '-Project', project, '-MaxSeconds', String(alerts.maxSeconds), '-StopFile', stopFile, '-NotifyAt', String(notifyAt)]
  const result = await $.process.run(argv, { timeoutMs: (alerts.maxSeconds + 30) * 1000 }).catch(() => undefined)
  if (playing === stopFile) playing = undefined
  // Exit 2: Space dismissed the effect, so someone is at the screen and no open block needs a remote push.
  if (result?.exitCode === 2) blocks.forEach(one => (one.isPushed = true))
}

// Fade the effect out once nothing is left blocking.
const stopIfClear = async ($: Host) => {
  if (playing === undefined || blocks.size > 0) return
  await $.fs.write(playing, 'stop').catch(() => {})
}

export const register: Register = (on, options) => {
  const delayMs = Number(options.delay_seconds ?? 10) * 1000
  const text = (value: unknown, fallback: string) => (typeof value === 'string' && value ? value : fallback)
  const alerts: Alerts = {
    questionEffect: text(options.question_effect, 'snow'),
    questionColor: text(options.question_color, '#FFFFFF'),
    permissionEffect: text(options.permission_effect, 'rain'),
    permissionColor: text(options.permission_color, '#60A5FA'),
    maxSeconds: Math.max(5, Number(options.max_seconds ?? 120)),
  }
  const remote: Remote = {
    url: text(options.remote_url, ''),
    tag: text(options.remote_tag, ''),
    delayMs: Number(options.remote_delay_seconds ?? 60) * 1000,
  }

  // The timer lives on the session's own dispatch, so it outlasts the hooks that add and clear blocks.
  on('session.start', async ($, e, next) => {
    $.clock.every(TICK_MS, () => {
      const now = Date.now()
      const due = [...blocks.values()].filter(one => !one.isSent && now - one.startedAt >= delayMs)
      if (due.length === 0) return
      due.forEach(one => (one.isSent = true))
      // An effect already on screen covers the new block too.
      if (playing === undefined) void alert($, alerts, remote, due)
    })
    // The remote push has its own, longer delay, so only a block nobody answered at the screen goes out.
    // It ticks every second so it lands on the effect's countdown.
    if (remote.url) {
      $.clock.every(1_000, () => {
        const now = Date.now()
        const due = [...blocks.values()].filter(one => !one.isPushed && now - one.startedAt >= remote.delayMs)
        if (due.length === 0) return
        due.forEach(one => (one.isPushed = true))
        void push($, remote, due)
      })
    }
    return next(e)
  })

  on('tool.check', async ($, e, next) => {
    const verdict = await next(e)
    if (verdict.decision === 'ask' && e.tool_use_id) asked.set(e.tool_use_id, { label: describeCall(e.tool, e.input), detail: detailCall(e.input) })
    return verdict
  }).catch(($, e, next) => next(e))

  // A question or plan dialog stays open inside its call; every call's end clears its own block.
  on('tool.call', async ($, e, next) => {
    const tool = String(e.tool)
    if (ASKING_TOOLS.has(tool)) blocks.set(e.tool_use_id, block(describeQuestion(tool, e), false, detailQuestion(tool, e)))
    try {
      return await next(e)
    } finally {
      blocks.delete(e.tool_use_id)
      asked.delete(e.tool_use_id)
      await stopIfClear($)
    }
  }).catch(($, e, next) => next(e))

  on('classic.Notification', ($, e, next) => {
    if (e.notification_type === 'permission_prompt') {
      // An `ask` the mode settled by itself never raises this, so only shown prompts become blocks.
      for (const [id, call] of asked) if (!blocks.has(id)) blocks.set(id, block(`Permission: ${call.label}`, true, call.detail))
    } else if (NEEDS_INPUT.has(e.notification_type)) {
      blocks.set(`notification:${e.notification_type}`, block(clip(e.message), false, e.message))
    }
    return next(e)
  }).catch(($, e, next) => next(e))

  // Nothing is blocked once a turn ends, the person writes, or the session ends.
  const clearAll = () => {
    blocks.clear()
    asked.clear()
  }
  on('turn.complete', async ($, e, next) => {
    clearAll()
    await stopIfClear($)
    return next(e)
  })
  on('prompt.submit', async ($, e, next) => {
    clearAll()
    await stopIfClear($)
    return next(e)
  }).catch(($, e, next) => next(e))
  on('session.end', async ($, e, next) => {
    clearAll()
    await stopIfClear($)
    return next(e)
  })
}

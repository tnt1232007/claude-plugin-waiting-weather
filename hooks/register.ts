import type { Register } from 'claude-code'

type Host = {
  plugin: { root: string }
  session: { root: () => Promise<string>; id: () => Promise<string> }
  fs: { write: (path: string, text: string) => Promise<void> }
  process: { run: (argv: readonly string[], init?: { timeoutMs?: number }) => Promise<unknown> }
}

// One thing Claude is waiting on: a question or plan dialog, or a permission prompt.
type Block = { label: string; isPermission: boolean; startedAt: number; isSent: boolean }
type Alerts = { questionEffect: string; questionColor: string; permissionEffect: string; permissionColor: string; maxSeconds: number }

// Tools that open a dialog and wait on the person inside their own call.
const ASKING_TOOLS = new Set(['AskUserQuestion', 'ExitPlanMode'])
// Notifications that mean Claude is blocked on the person; idle_prompt is the normal end of a turn.
const NEEDS_INPUT = new Set(['elicitation_dialog', 'elicitation_url_dialog', 'agent_needs_input'])
const TICK_MS = 5_000

// Keyed by tool_use_id, so parallel calls never clear each other's block. Module state: a reload starts empty.
const blocks = new Map<string, Block>()
// Calls whose permission verdict was `ask`; one becomes a block once the prompt is actually shown.
const asked = new Map<string, string>()
// The effect's state file while it plays: it loops until this file holds "stop".
let playing: string | undefined

const clip = (text: string, max = 120) => (text.length > max ? `${text.slice(0, max - 1)}…` : text)

const block = (label: string, isPermission: boolean): Block => ({ label, isPermission, startedAt: Date.now(), isSent: false })

const describeCall = (tool: string, input: unknown) => {
  const fields = (input ?? {}) as Record<string, unknown>
  const detail = fields.command ?? fields.file_path ?? fields.url ?? fields.pattern
  return typeof detail === 'string' ? `${tool}: ${clip(detail)}` : tool
}

const describeQuestion = (tool: string, input: unknown) => {
  if (tool === 'ExitPlanMode') return 'Plan approval'
  const questions = ((input ?? {}) as { questions?: { question?: unknown }[] }).questions
  const first = questions?.[0]?.question
  return typeof first === 'string' ? `Question: ${clip(first)}` : 'Question'
}

const alert = async ($: Host, alerts: Alerts, due: Block[]) => {
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
  const argv = ['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script, '-Effect', effect, '-Color', color, '-Project', project, '-MaxSeconds', String(alerts.maxSeconds), '-StopFile', stopFile]
  await $.process.run(argv, { timeoutMs: (alerts.maxSeconds + 30) * 1000 }).catch(() => {})
  if (playing === stopFile) playing = undefined
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

  // The timer lives on the session's own dispatch, so it outlasts the hooks that add and clear blocks.
  on('session.start', async ($, e, next) => {
    $.clock.every(TICK_MS, () => {
      const now = Date.now()
      const due = [...blocks.values()].filter(one => !one.isSent && now - one.startedAt >= delayMs)
      if (due.length === 0) return
      due.forEach(one => (one.isSent = true))
      // An effect already on screen covers the new block too.
      if (playing === undefined) void alert($, alerts, due)
    })
    return next(e)
  })

  on('tool.check', async ($, e, next) => {
    const verdict = await next(e)
    if (verdict.decision === 'ask' && e.tool_use_id) asked.set(e.tool_use_id, describeCall(e.tool, e.input))
    return verdict
  }).catch(($, e, next) => next(e))

  // A question or plan dialog stays open inside its call; every call's end clears its own block.
  on('tool.call', async ($, e, next) => {
    if (ASKING_TOOLS.has(String(e.tool))) blocks.set(e.tool_use_id, block(describeQuestion(String(e.tool), e), false))
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
      for (const [id, label] of asked) if (!blocks.has(id)) blocks.set(id, block(`Permission: ${label}`, true))
    } else if (NEEDS_INPUT.has(e.notification_type)) {
      blocks.set(`notification:${e.notification_type}`, block(clip(e.message), false))
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

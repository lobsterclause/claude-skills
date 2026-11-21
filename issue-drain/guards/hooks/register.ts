import type { EngineInterface, Register } from 'claude-code'
import { agentDeny, bashDeny, parseUnit, pathDeny, type Unit } from './rules.ts'

const VERSION = '0.1.0'

/** Reads the unit file the driver named in ISSUE_DRAIN_UNIT_FILE; a string result is why it could not. */
async function loadUnit($: EngineInterface): Promise<Unit | string> {
  const file = await $.env.get('ISSUE_DRAIN_UNIT_FILE')
  if (!file) return 'ISSUE_DRAIN_UNIT_FILE is not set'
  try {
    const unit = parseUnit(await $.fs.read(file))
    return typeof unit === 'string' ? `${file}: ${unit}` : unit
  } catch (err) {
    return `${file}: ${err instanceof Error ? err.message : String(err)}`
  }
}

const noUnit = (why: string) => ({
  deny: `drain-guards: the unit file could not be read (${why}); every tool is denied until the driver provides it`,
})

// A guard that throws would be skipped and the call let through; this makes it deny.
const FAILED = { deny: 'drain-guards: a guard failed, so the call is denied' }

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const unit = await loadUnit($)
    // The driver refuses to merge a unit with no marker, so it is written only after a valid load.
    if (typeof unit !== 'string')
      await $.fs.write(`${unit.state_dir}/guards-marker`, `${new Date().toISOString()} drain-guards ${VERSION}\n`)
    return next(e)
  })

  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const unit = await loadUnit($)
    if (typeof unit === 'string') return noUnit(unit)
    const why = bashDeny(e.command, unit.branch)
    return why ? { deny: why } : next(e)
  }).catch(($, e, next) => (next.called ? next(e) : FAILED))

  on('tool.call', { tool: ['Edit', 'Write'] }, async ($, e, next) => {
    const unit = await loadUnit($)
    if (typeof unit === 'string') return noUnit(unit)
    const why = pathDeny(e.file_path, unit)
    return why ? { deny: why } : next(e)
  }).catch(($, e, next) => (next.called ? next(e) : FAILED))

  on('tool.call', { tool: 'NotebookEdit' }, async ($, e, next) => {
    const unit = await loadUnit($)
    if (typeof unit === 'string') return noUnit(unit)
    const why = pathDeny(e.notebook_path, unit)
    return why ? { deny: why } : next(e)
  }).catch(($, e, next) => (next.called ? next(e) : FAILED))

  on('tool.call', { tool: 'Agent' }, async ($, e, next) => {
    const unit = await loadUnit($)
    if (typeof unit === 'string') return noUnit(unit)
    const why = agentDeny(e)
    if (why) return { deny: why }
    // shortcut: read-then-write, so two Agent calls in the same instant can lose a line; the log is advisory.
    const log = `${unit.state_dir}/delegations.jsonl`
    const old = (await $.fs.exists(log)) ? await $.fs.read(log) : ''
    const row = { ts: new Date().toISOString(), model: e.model, effort: e.effort, description: e.description }
    await $.fs.write(log, `${old}${JSON.stringify(row)}\n`)
    return next(e)
  }).catch(($, e, next) => (next.called ? next(e) : FAILED))
}

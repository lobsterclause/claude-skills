// drain-console: watch an issue-drain run from inside a session.
//
// It reads a run folder (~/.issue-drain/<owner>__<repo>/<run id>/) on a
// timer and shows it as a pane, a status line entry, and a toast plus a
// native notification when a unit merges, blocks or parks, and when the
// drain stops or finishes. It never merges, never writes to GitHub, and
// never changes the run's state: the one file it writes is the STOP file,
// when a person presses "Stop after this unit" or types `/drain stop`.

import { atom, read, update } from 'claude-code'
import type { EngineInterface, PluginOptions, Register } from 'claude-code'

import type { Snapshot } from '../types'
import {
  EVENTS_TAIL_BYTES,
  NEEDS_PERSON,
  ageText,
  buildView,
  clip,
  isRecent,
  parseState,
  statusText,
  summarisePrompt,
  summaryText,
  transitions,
  type RunFiles,
} from './model'

const PANE = 'drain-console'
const TITLE = 'Issue drain'
/** The `$.store` key `/drain <run folder>` pins a run under. */
const STORE_RUN = 'run_dir'

// Change the tag when Snapshot's fields change: a value an earlier version
// stored outlives a reload, and is read as the initial value under a new tag.
const snapshot = atom(
  { plugin: 'drain-console', key: 'snapshot' } as const,
  { view: null, note: 'Not read yet.', readAtMs: 0 } as Snapshot,
  { shape: 'snapshot-1' },
)

/** Set while a poll runs, so a slow file system never stacks two. */
let polling: Promise<Snapshot> | null = null

const errText = (err: unknown): string =>
  err instanceof Error ? err.message : String(err)

/** `~` and `~/x` against HOME; anything else as given. */
const expand = (path: string, home: string | undefined): string => {
  const p = path.trim().replace(/\/+$/, '')
  if (home !== undefined && (p === '~' || p.startsWith('~/'))) {
    return `${home}${p.slice(1)}`
  }
  return p
}

async function readOrNull($: EngineInterface, path: string): Promise<string | null> {
  try {
    return await $.fs.read(path)
  } catch {
    return null
  }
}

async function existsOrFalse($: EngineInterface, path: string): Promise<boolean> {
  try {
    return await $.fs.exists(path)
  } catch {
    return false
  }
}

/** The run folder under ~/.issue-drain whose state.json changed last. */
async function newestRun($: EngineInterface): Promise<string | null> {
  const home = await $.env.get('HOME')
  if (home === undefined || home === '') return null
  const root = `${home}/.issue-drain`
  let repos
  try {
    repos = await $.fs.list(root)
  } catch {
    return null
  }
  let best: string | null = null
  let bestMs = -1
  for (const repo of repos) {
    if (repo.kind !== 'dir') continue
    let runs
    try {
      runs = await $.fs.list(`${root}/${repo.name}`)
    } catch {
      continue
    }
    for (const run of runs) {
      // `tracker-<n>` entries are links to run folders: kind `other`.
      if (run.kind !== 'dir') continue
      const dir = `${root}/${repo.name}/${run.name}`
      try {
        const st = await $.fs.stat(`${dir}/state.json`)
        if (st.kind === 'file' && st.mtimeMs > bestMs) {
          bestMs = st.mtimeMs
          best = dir
        }
      } catch {
        // No state.json: not a run the driver has started.
      }
    }
  }
  return best
}

/** Which run to watch: the setting, then `/drain <folder>`, then the newest. */
async function chooseRun(
  $: EngineInterface,
  options: PluginOptions,
): Promise<string | null> {
  const home = await $.env.get('HOME')
  const pinned = typeof options.run_dir === 'string' ? options.run_dir.trim() : ''
  if (pinned !== '') return expand(pinned, home)
  const stored = await $.store.get(STORE_RUN)
  if (typeof stored === 'string' && stored !== '') return stored
  return newestRun($)
}

/** Reads one run folder. Rejects when state.json cannot be read. */
async function readRun($: EngineInterface, dir: string): Promise<RunFiles> {
  const state = await $.fs.read(`${dir}/state.json`)
  const units = parseState(state).units.map(u => u.unit)
  let eventsTail: string | null = null
  let eventsCut = false
  let eventsMtimeMs: number | null = null
  try {
    const st = await $.fs.stat(`${dir}/events.jsonl`)
    eventsMtimeMs = st.mtimeMs
    const offset = Math.max(0, st.size - EVENTS_TAIL_BYTES)
    eventsTail = await $.fs.read(`${dir}/events.jsonl`, {
      offset,
      length: EVENTS_TAIL_BYTES,
    })
    eventsCut = offset > 0
  } catch {
    // No events yet.
  }
  const sessions: Record<number, string | null> = {}
  for (const unit of units) {
    sessions[unit] = await readOrNull($, `${dir}/units/${unit}/session.json`)
  }
  return {
    runDir: dir,
    state,
    queue: await readOrNull($, `${dir}/queue.json`),
    tracker: await readOrNull($, `${dir}/tracker.json`),
    eventsTail,
    eventsCut,
    eventsMtimeMs,
    sessions,
    stopRequested: await existsOrFalse($, `${dir}/STOP`),
  }
}

/** Reads the run, stores the view, and says what changed. */
function poll($: EngineInterface, options: PluginOptions): Promise<Snapshot> {
  if (polling !== null) return polling
  polling = pollOnce($, options).finally(() => {
    polling = null
  })
  return polling
}

async function pollOnce($: EngineInterface, options: PluginOptions): Promise<Snapshot> {
  const now = await $.clock.now()
  const prev = await read($, snapshot)
  const dir = await chooseRun($, options)
  let next: Snapshot
  if (dir === null) {
    next = { view: null, note: 'No issue-drain run found under ~/.issue-drain.', readAtMs: now }
  } else {
    try {
      next = { view: buildView(await readRun($, dir)), note: '', readAtMs: now }
    } catch (err) {
      // A failed read of the same run keeps the last view, so a state.json
      // caught mid-write does not reset the baseline and lose a transition.
      const keep = prev.view !== null && prev.view.runDir === dir ? prev.view : null
      next = {
        view: keep,
        note: `Cannot read ${dir}/state.json: ${clip(errText(err), 160)}`,
        readAtMs: now,
      }
    }
  }
  await update($, snapshot, () => next)

  const view = next.view
  $.ui.status(view !== null && isRecent(view, now) ? statusText(view, now) : undefined)

  const alerts = transitions(prev.view, view)
  for (const alert of alerts) {
    $.ui.toast(alert.text)
    void $.ui.notify(alert.text, { title: 'issue-drain' }).catch(() => undefined)
  }
  const needPerson = alerts.filter(a => NEEDS_PERSON.has(a.kind))
  if (options.summarise_on_stop === true && view !== null && needPerson.length > 0) {
    void $.prompt.submit({ text: summarisePrompt(view, needPerson) }).catch(() => undefined)
  }
  return next
}

/** Writes the STOP file, which the driver checks before it claims a unit. */
async function requestStop($: EngineInterface, options: PluginOptions): Promise<string> {
  const view = (await read($, snapshot)).view
  if (view === null) return 'No run to stop.'
  if (view.stopped !== null) return `The run already stopped: ${view.stopped.reason}`
  if (view.isFinished) return 'The run has finished; there is nothing to stop.'
  const path = `${view.runDir}/STOP`
  const at = new Date(await $.clock.now()).toISOString()
  await $.fs.write(path, `stop requested from drain-console at ${at}\n`)
  await poll($, options)
  return `Wrote ${path}. The driver finishes the unit it is on and stops before it claims the next one.`
}

/** A unit process or a headless session gets nothing from a console. */
async function isConsoleSession(
  $: EngineInterface,
  isInteractive: boolean,
): Promise<boolean> {
  if (!isInteractive) return false
  if ((await $.env.get('ISSUE_DRAIN_MODE')) === 'unit') return false
  if ((await $.env.get('ISSUE_DRAIN_UNIT_FILE')) !== undefined) return false
  return true
}

export const register: Register = (on, options) => {
  const seconds =
    typeof options.poll_seconds === 'number' && options.poll_seconds >= 5
      ? options.poll_seconds
      : 15

  on('session.start', async ($, e, next) => {
    if (await isConsoleSession($, e.isInteractive)) {
      await $.command.register({
        name: 'drain',
        description: 'Show the issue-drain run: status, the pane, or a STOP request',
        argumentHint: '[pane | stop | auto | <run folder>]',
      })
      const first = await poll($, options)
      const view = first.view
      if (view !== null && !view.isFinished && view.stopped === null && isRecent(view, first.readAtMs)) {
        void $.ui.open({ id: PANE, title: TITLE })
      }
      $.clock.every(seconds * 1000, () => {
        void poll($, options).catch(() => undefined)
      })
    }

    return next(e)
  })

  on('command.run', { command: 'drain' }, async ($, e) => {
    const arg = e.args.trim()
    if (arg === 'pane') {
      await $.ui.open({ id: PANE, title: TITLE })
      return { text: 'Drain pane opened.' }
    }
    if (arg === 'stop') {
      return { text: await requestStop($, options) }
    }
    if (arg === 'auto') {
      await $.store.delete(STORE_RUN)
    } else if (arg !== '') {
      const dir = expand(arg, await $.env.get('HOME'))
      if (!(await existsOrFalse($, `${dir}/state.json`))) {
        return { text: `No state.json in ${dir}: not a run the driver has started.` }
      }
      await $.store.set(STORE_RUN, dir)
    }
    const snap = await poll($, options)
    const pinned = typeof options.run_dir === 'string' && options.run_dir.trim() !== ''
    const note =
      pinned && arg !== ''
        ? '\nThe run_dir setting pins the run; clear it for /drain <folder> or /drain auto to take effect.'
        : ''
    return { text: summaryText(snap, snap.readAtMs) + note }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button, Link } = $.ui.resolve(e)
    const snap = await read($, snapshot)
    const view = snap.view
    if (view === null) {
      return (
        <Box flexDirection="column">
          <Text dimColor>{snap.note}</Text>
          <Text dimColor>{'/drain <run folder> picks a run.'}</Text>
        </Box>
      )
    }
    const now = snap.readAtMs
    const canStop = view.stopped === null && !view.isFinished && !view.stopRequested

    return (
      <Box flexDirection="column">
        <Text bold>
          {view.repo} · run {view.runId}
        </Text>
        <Text>{statusText(view, now)}</Text>
        <Box flexDirection="row" gap={1}>
          {view.trackerUrl !== null && (
            <Link
              href={view.trackerUrl}
              label={view.trackerNumber === null ? 'Tracker' : `Tracker #${view.trackerNumber}`}
            />
          )}
          {canStop && (
            <Button
              key="stop"
              label="Stop after this unit"
              onPress={() => requestStop($, options)}
            />
          )}
          {view.stopRequested && view.stopped === null && (
            <Text dimColor>stop requested</Text>
          )}
        </Box>
        {view.units.map(u => (
          <Box flexDirection="column" marginTop={1}>
            <Box flexDirection="row" gap={1}>
              <Text bold>
                {u.id}
                {u.issues.length > 0 ? ` #${u.issues.join(', #')}` : ''}
              </Text>
              <Text>{u.state}</Text>
              <Text dimColor>{ageText(u.updatedMs, now)}</Text>
              {u.pr !== null && (
                <Link href={`https://github.com/${view.repo}/pull/${u.pr}`} label={`PR #${u.pr}`} />
              )}
              {u.costUsd !== null && (
                <Text dimColor>~${u.costUsd.toFixed(2)} (estimate)</Text>
              )}
            </Box>
            {u.title !== '' && (
              <Text dimColor wrap="truncate-end">
                {u.title}
              </Text>
            )}
            {u.refusals.length > 0 && <Text>gate: {u.refusals.join(', ')}</Text>}
            {u.note !== null && (u.state === 'parked' || u.state === 'blocked') && (
              <Text dimColor>{clip(u.note, 240)}</Text>
            )}
          </Box>
        ))}
        {view.lastCall !== null && (
          <Box marginTop={1}>
            <Text dimColor>last call: {view.lastCall}</Text>
          </Box>
        )}
        {snap.note !== '' && <Text dimColor>{snap.note}</Text>}
      </Box>
    )
  })
}

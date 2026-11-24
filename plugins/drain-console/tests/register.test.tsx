import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const HOME = '/home/t'
const RUN = `${HOME}/.issue-drain/acme__app/2026-11-23-a`
const NOW = Date.parse('2026-11-24T10:05:00Z')

const PANE = {
  plugin: 'drain-console',
  component: 'Pane',
  requestId: 'drain-console',
  props: {
    title: 'Issue drain',
    isFocused: false,
    bodyColumns: 80,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 30 },
    view: {},
  },
} as const

const state = (u1: string) =>
  JSON.stringify({
    queue: [2],
    stopped: null,
    units: [
      { unit: 1, issues: [11], state: u1, pr: 41, head: null, base_syncs: 0, repairs: 0, updated: '2026-11-24T10:00:00Z' },
      { unit: 2, issues: [12], state: 'queued', pr: null, head: null, base_syncs: 0, repairs: 0, updated: '2026-11-24T09:00:00Z' },
    ],
  })

const call = (args: string[], code = 0) =>
  JSON.stringify({ ts: '2026-11-24T10:00:00Z', event: 'drive', unit: null, step: 'call', detail: { args, code } })
const moved = (unit: number, to: string, note: string) =>
  JSON.stringify({ ts: '2026-11-24T10:00:00Z', unit, from: 'reviewing', to, note })

type World = {
  /** While set, reading RUN's events.jsonl calls `held` and waits for `hold`. */
  hold: Promise<void> | null
  held: () => void
  clock: ReturnType<typeof mock.clock>
  files: Map<string, string>
  writes: { path: string; text: string }[]
  statuses: (string | undefined)[]
  toasts: string[]
  notes: { text: string; title?: string }[]
  prompts: string[]
  opened: string[]
  commands: string[]
}

/** An engine beneath the plugin: a run folder in memory, and records of what it was asked. */
function world(on: On, env: Record<string, string> = { HOME }): World {
  const w: World = {
    hold: null,
    held: () => {},
    clock: mock.clock(on, { now: NOW }),
    files: new Map([
      [`${RUN}/state.json`, state('implementing')],
      [`${RUN}/queue.json`, JSON.stringify({ repo: 'acme/app', units: [{ id: 'U1', issues: [11], title: 'Fix the thing' }] })],
      [`${RUN}/tracker.json`, JSON.stringify({ number: 99, url: 'https://github.com/acme/app/issues/99' })],
      [`${RUN}/events.jsonl`, call(['unit-run', '--unit', '1']) + '\n'],
      [`${RUN}/units/1/session.json`, JSON.stringify({ attempts: [{ cost_usd: 0.42 }] })],
    ]),
    writes: [],
    statuses: [],
    toasts: [],
    notes: [],
    prompts: [],
    opened: [],
    commands: [],
  }
  const missing = (path: string) => new Error(`ENOENT: ${path}`)
  mock.store(on)
  mock.env(on, env)
  on('fs.read', async (_, e) => {
    if (w.hold !== null && e.path === `${RUN}/events.jsonl`) {
      w.held()
      await w.hold
    }
    const text = w.files.get(e.path)
    if (text === undefined) throw missing(e.path)
    const from = e.offset ?? 0
    return { value: text.slice(from, e.length === undefined ? undefined : from + e.length) }
  })
  on('fs.stat', (_, e) => {
    const text = w.files.get(e.path)
    if (text === undefined) throw missing(e.path)
    return { value: { kind: 'file', size: text.length, mtimeMs: NOW - 60000, isLink: false } }
  })
  on('fs.exists', (_, e) => ({ value: w.files.has(e.path) }))
  on('fs.list', (_, e) => {
    if (e.path === `${HOME}/.issue-drain`) {
      return { value: [{ name: 'acme__app', kind: 'dir', size: 0, mtimeMs: 0, isLink: false }] }
    }
    if (e.path === `${HOME}/.issue-drain/acme__app`) {
      return {
        value: [
          { name: '2026-11-23-a', kind: 'dir', size: 0, mtimeMs: 0, isLink: false },
          { name: 'tracker-99', kind: 'other', size: 0, mtimeMs: 0, isLink: true },
        ],
      }
    }
    throw missing(e.path)
  })
  on('fs.write', (_, e) => {
    w.writes.push({ path: e.path, text: e.text })
    w.files.set(e.path, e.text)
    return { value: undefined }
  })
  on('ui.status', (_, e) => {
    w.statuses.push(e.text)
    return { value: undefined }
  })
  on('ui.toast', (_, e) => {
    w.toasts.push(e.text)
    return { value: undefined }
  })
  on('ui.notify', (_, e) => {
    w.notes.push({ text: e.text, title: e.title })
    return { value: { isSent: true, channel: 'client' } }
  })
  on('prompt.submit', (_, e) => {
    w.prompts.push(e.text)
    return { text: e.text }
  })
  on('command.register', (_, e) => {
    w.commands.push(e.name)
    return { value: { command: e.name } }
  })
  on('ui.open', (_, e) => {
    w.opened.push(e.id)
    return { value: { isPlaced: true } }
  })
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  return w
}

/** `/drain <args>` as the person typed it. */
const typed = (args: string) => ({
  command: 'drain',
  args,
  origin: { kind: 'composer' } as const,
  presentation: { isFullscreen: false, columns: 100 },
})

const parkIt = (w: World) => {
  w.files.set(`${RUN}/state.json`, state('parked'))
  w.files.set(
    `${RUN}/events.jsonl`,
    w.files.get(`${RUN}/events.jsonl`) +
      moved(1, 'parked', 'review cap reached') + '\n',
  )
}

test('the pane shows the run and its units, on every surface', async ($, on) => {
  const w = world(on)
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })

  expect(w.commands).toEqual(['drain'])
  expect(w.opened).toEqual(['drain-console'])
  expect(w.statuses.at(-1)).toBe('drain 0/2 · U1 #11 implementing 5m')

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect((await ui.find({ type: 'Text', text: /run 2026-11-23-a/ }))?.text).toBe(
      'acme/app · run 2026-11-23-a',
    )
    expect(await ui.find({ type: 'Text', text: /Fix the thing/ })).toBeTruthy()
    expect(await ui.find({ type: 'Text', text: /~\$0\.42 \(estimate\)/ })).toBeTruthy()
    await ui.unmount()
  }
})

test('a unit that parks raises a toast and a notification, and no prompt', async ($, on) => {
  const w = world(on)
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  expect(w.toasts).toEqual([])

  parkIt(w)
  await w.clock.advance(15000)

  expect(w.toasts).toEqual(['U1 #11 parked: review cap reached'])
  expect(w.notes).toEqual([{ text: 'U1 #11 parked: review cap reached', title: 'issue-drain' }])
  expect(w.prompts).toEqual([])
})

test(
  'summarise_on_stop queues one prompt when a unit parks',
  { options: { summarise_on_stop: true } },
  async ($, on) => {
    const w = world(on)
    await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
    parkIt(w)
    await w.clock.advance(15000)

    expect(w.prompts.length).toBe(1)
    expect(w.prompts[0]).toContain(RUN)
    expect(w.prompts[0]).toContain('Change nothing')
    expect(w.prompts[0]).not.toContain('review cap reached')
  },
)

test('the stop button writes the STOP file and nothing else', async ($, on) => {
  const w = world(on)
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })

  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  await ui.press({ key: 'stop' })

  expect(w.writes.map(x => x.path)).toEqual([`${RUN}/STOP`])
  expect(w.statuses.at(-1)).toBe('drain 0/2 · U1 #11 implementing 5m · stop requested')
  await ui.unmount()
})

test('after a switch, the stop button stops the run it now shows, never the old one', async ($, on) => {
  const w = world(on)
  const OTHER = `${HOME}/.issue-drain/acme__app/2026-11-24-b`
  for (const [k, v] of [...w.files]) {
    if (k.startsWith(RUN)) w.files.set(k.replace(RUN, OTHER), v)
  }
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })

  // The switch redraws the pane, so the button is now bound to OTHER. A press
  // that lands between a poll and its redraw is refused by requestStop's check.
  await $.command.run(typed(OTHER))
  expect(await ui.find({ type: 'Text', text: /run 2026-11-24-b/ })).toBeTruthy()
  await ui.press({ key: 'stop' })
  expect(w.writes.map(x => x.path)).toEqual([`${OTHER}/STOP`])
  await ui.unmount()
})

test('/drain stop after a switch reads the new run, not a poll already running', async ($, on) => {
  const w = world(on)
  const OTHER = `${HOME}/.issue-drain/acme__app/2026-11-24-b`
  for (const [k, v] of [...w.files]) {
    if (k.startsWith(RUN)) w.files.set(k.replace(RUN, OTHER), v)
  }
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })

  // A timer poll picks RUN and stalls reading it; the switch starts meanwhile
  // and is given time to reach its own poll before the old one finishes.
  let release = () => {}
  w.hold = new Promise(r => {
    release = r
  })
  const stalled = new Promise<void>(r => {
    w.held = r
  })
  const tick = w.clock.advance(15000)
  await stalled
  w.hold = null
  const switched = $.command.run(typed(OTHER))
  for (let i = 0; i < 200; i++) await Promise.resolve()
  release()
  await tick
  const out = await switched
  expect(out.text).toContain('run 2026-11-24-b')
  const stop = await $.command.run(typed('stop'))
  expect(stop.text).toBe(`Wrote ${OTHER}/STOP. The driver finishes the unit it is on and stops before it claims the next one.`)
  expect(w.writes.map(x => x.path)).toEqual([`${OTHER}/STOP`])
})

test('/drain prints the run without a model turn', async ($, on) => {
  const w = world(on)
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })

  const out = await $.command.run(typed(''))
  expect(out.text).toContain('acme/app · run 2026-11-23-a · drain 0/2')
  expect(out.text).toContain('U1 #11 implementing 5m · PR #41 · ~$0.42 (estimate)')
  expect(out.text).toContain('tracker: https://github.com/acme/app/issues/99')
  expect(w.prompts).toEqual([])
})

test('/drain stop refuses a run that already stopped', async ($, on) => {
  const w = world(on)
  w.files.set(
    `${RUN}/state.json`,
    JSON.stringify({ ...JSON.parse(state('implementing')), stopped: { ts: '2026-11-24T10:00:00Z', reason: 'STOP file' } }),
  )
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })

  const out = await $.command.run(typed('stop'))
  expect(out.text).toBe('The run already stopped: STOP file')
  expect(w.writes).toEqual([])
})

test('/drain <folder> refuses a folder with no state.json', async ($, on) => {
  const w = world(on)
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })

  const out = await $.command.run(typed('~/nowhere'))
  expect(out.text).toBe(`No state.json in ${HOME}/nowhere: not a run the driver has started.`)
  expect(w.writes).toEqual([])
})

test('a headless session gets nothing', async ($, on) => {
  const w = world(on)
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: false })
  expect(w.commands).toEqual([])
  expect(w.statuses).toEqual([])
})

test('an empty ISSUE_DRAIN_UNIT_FILE counts as unset', async ($, on) => {
  const w = world(on, { HOME, ISSUE_DRAIN_UNIT_FILE: '' })
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  expect(w.commands).toEqual(['drain'])
})

test('a home of / still expands ~', async ($, on) => {
  const w = world(on, { HOME: '/' })
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  const out = await $.command.run(typed('~/nowhere'))
  expect(out.text).toBe('No state.json in /nowhere: not a run the driver has started.')
  expect(w.writes).toEqual([])
})

test('a unit process gets nothing', async ($, on) => {
  const w = world(on, { HOME, ISSUE_DRAIN_MODE: 'unit' })
  await $.session.start({ cwd: '/', surface: 'desktop', isInteractive: true })
  expect(w.commands).toEqual([])
  expect(w.statuses).toEqual([])
  expect(w.opened).toEqual([])
})

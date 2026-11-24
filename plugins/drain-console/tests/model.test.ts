import { expect, test } from 'claude-code/testing'

import {
  buildView,
  scanEvents,
  statusText,
  summaryText,
  transitions,
  type RunFiles,
} from '../hooks/model'

const RUN = '/home/t/.issue-drain/acme__app/2026-11-23-a'
const T0 = Date.parse('2026-11-24T10:00:00Z')

const line = (o: object): string => JSON.stringify(o)
const call = (args: string[], code = 0): string =>
  line({ ts: '2026-11-24T10:00:00Z', event: 'drive', unit: null, step: 'call', detail: { args, code } })

function files(units: object[], extra: Partial<RunFiles> = {}): RunFiles {
  return {
    runDir: RUN,
    state: JSON.stringify({ queue: [], stopped: null, units }),
    queue: null,
    tracker: null,
    eventsTail: null,
    eventsCut: false,
    eventsMtimeMs: null,
    sessions: {},
    stopRequested: false,
    ...extra,
  }
}

const unit = (n: number, state: string, updated = '2026-11-24T10:00:00Z') => ({
  unit: n,
  issues: [100 + n],
  state,
  pr: null,
  head: null,
  base_syncs: 0,
  repairs: 0,
  updated,
})

test('scanEvents keeps the newest note and refusals, and skips state show', () => {
  const tail = [
    '{"half a line',
    call(['state', 'event', '1', 'parked', '--note', 'review cap reached']),
    line({ event: 'merge_gate', unit: 2, merged: false, refusals: ['ci red'] }),
    line({ event: 'merge_gate', unit: 3, merged: false, refusals: ['stale'] }),
    line({ event: 'merge_gate', unit: 3, merged: true, refusals: [] }),
    call(['unit-run', '--unit', '2'], 1),
    call(['state', 'show']),
    'not json',
  ].join('\n')
  const facts = scanEvents(tail, true)
  expect(facts.notes.get(1)).toBe('review cap reached')
  expect(facts.refusals.get(2)).toEqual(['ci red'])
  expect(facts.refusals.get(3)).toEqual([])
  expect(facts.lastCall).toBe('unit-run --unit 2 (exit 1)')
})

test('the repo falls back to the folder name when queue.json is missing', () => {
  const view = buildView(files([unit(1, 'queued')]))
  expect(view.repo).toBe('acme/app')
  expect(view.runId).toBe('2026-11-23-a')
  expect(view.total).toBe(1)
  expect(view.isFinished).toBe(false)
})

test('a state.json with no units list is refused', () => {
  expect(() => buildView({ ...files([]), state: '{"queue":[]}' })).toThrow()
})

test('statusText names the unit being worked on and its age', () => {
  const view = buildView(
    files([unit(1, 'done'), unit(2, 'ci_wait', '2026-11-24T10:01:00Z'), unit(3, 'queued')]),
  )
  expect(statusText(view, T0 + 4 * 60000)).toBe('drain 1/3 · U2 #102 ci_wait 3m')
  expect(statusText({ ...view, stopRequested: true }, T0 + 4 * 60000)).toBe(
    'drain 1/3 · U2 #102 ci_wait 3m · stop requested',
  )
  expect(statusText({ ...view, stopped: { ts: 'x', reason: 'STOP file' } }, T0)).toBe(
    'drain stopped: STOP file',
  )
})

test('transitions: a first read and another run are baselines', () => {
  const a = buildView(files([unit(1, 'implementing')]))
  const b = buildView(files([unit(1, 'parked')]))
  expect(transitions(null, b)).toEqual([])
  expect(transitions({ ...a, runDir: '/elsewhere' }, b)).toEqual([])
})

test('transitions report merged, parked with its note, and finished', () => {
  const before = buildView(files([unit(1, 'ci_wait'), unit(2, 'reviewing')]))
  const after = buildView(
    files([{ ...unit(1, 'merged'), pr: 7 }, unit(2, 'parked')], {
      eventsTail: call(['state', 'event', '2', 'parked', '--note', 'P1 open']),
    }),
  )
  expect(transitions(before, after)).toEqual([
    { kind: 'merged', text: 'U1 #101 merged (PR #7)' },
    { kind: 'parked', text: 'U2 #102 parked: P1 open' },
  ])
  const done = buildView(files([{ ...unit(1, 'done'), pr: 7 }, unit(2, 'parked')]))
  expect(transitions(after, done).map(a => a.kind)).toEqual(['finished'])
})

test('summaryText marks cost as an estimate and shows the park note', () => {
  const view = buildView(
    files([unit(1, 'parked')], {
      sessions: { 1: JSON.stringify({ attempts: [{ cost_usd: 0.25 }, { cost_usd: 0.17 }] }) },
      eventsTail: call(['state', 'event', '1', 'parked', '--note', 'review cap reached']),
    }),
  )
  const text = summaryText({ view, note: '', readAtMs: T0 + 5 * 60000 }, T0 + 5 * 60000)
  expect(text).toContain('U1 #101 parked 5m · ~$0.42 (estimate)')
  expect(text).toContain('  review cap reached')
})

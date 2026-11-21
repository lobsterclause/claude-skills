import type { On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'

const UNIT_FILE = '/state/unit-3.json'
const UNIT = {
  unit: 3,
  worktree: '/wt/unit3',
  branch: 'fix/issue-3',
  state_dir: '/state/units/3',
  protected_paths: ['.github/workflows', '.claude'],
}

// Nothing sits beneath the plugin: these hooks stand for the engine.
const engine = (on: On, files: Record<string, string>) => {
  const written: Record<string, string> = {}
  mock.env(on, { ISSUE_DRAIN_UNIT_FILE: UNIT_FILE })
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('tool.call', () => ({ result: {} }))
  on('fs.exists', (_, e) => ({ value: e.path in files || e.path in written }))
  on('fs.read', (_, e) => {
    const text = written[e.path] ?? files[e.path]
    if (text === undefined) throw new Error('ENOENT')
    return { value: text }
  })
  on('fs.write', (_, e) => {
    written[e.path] = e.text
    return { value: undefined }
  })
  return written
}

test('unit file missing: every guarded tool is denied', async ($, on) => {
  const written = engine(on, {})
  await $.session.start({ cwd: '/wt/unit3', surface: null, isInteractive: false })

  const bash = await $.tool.call({ tool: 'Bash', command: 'ls' })
  expect(bash.deny).toMatch(/unit file could not be read/)
  expect((await $.tool.call({ tool: 'Write', file_path: '/wt/unit3/a', content: 'x' })).deny).toBeDefined()
  expect((await $.tool.call({ tool: 'Agent', description: 'd', prompt: 'p', model: 'haiku', effort: 'low' })).deny).toBeDefined()
  expect(Object.keys(written)).toEqual([])
})

test('valid unit file: marker written, merges denied, ordinary work allowed', async ($, on) => {
  const written = engine(on, { [UNIT_FILE]: JSON.stringify(UNIT) })
  await $.session.start({ cwd: '/wt/unit3', surface: null, isInteractive: false })

  expect(written['/state/units/3/guards-marker']).toMatch(/^\d{4}-\d\d-\d\dT.* drain-guards 0\.1\.0\n$/)

  const merge = await $.tool.call({ tool: 'Bash', command: 'rtk gh pr merge 1' })
  expect(merge.deny).toBeDefined()
  expect(merge.deny).toMatch(/^drain-guards:/)
  expect((await $.tool.call({ tool: 'Bash', command: 'cargo test' })).deny).toBeUndefined()

  expect((await $.tool.call({ tool: 'Edit', file_path: '/wt/unit3/src/a.rs', old_string: 'a', new_string: 'b' })).deny).toBeUndefined()
  expect((await $.tool.call({ tool: 'Edit', file_path: '/wt/unit3/.claude/x', old_string: 'a', new_string: 'b' })).deny).toBeDefined()
  expect((await $.tool.call({ tool: 'Write', file_path: '/etc/x', content: 'x' })).deny).toBeDefined()
  expect((await $.tool.call({ tool: 'NotebookEdit', notebook_path: '/wt/unit3/../x.ipynb', new_source: 'x' })).deny).toBeDefined()
})

test('Agent: denied without model and effort; an allowed call is logged', async ($, on) => {
  const written = engine(on, { [UNIT_FILE]: JSON.stringify(UNIT) })
  await $.session.start({ cwd: '/wt/unit3', surface: null, isInteractive: false })

  expect((await $.tool.call({ tool: 'Agent', description: 'd', prompt: 'p' })).deny).toBeDefined()
  const ok = await $.tool.call({ tool: 'Agent', description: 'look', prompt: 'p', model: 'haiku', effort: 'low' })
  expect(ok.deny).toBeUndefined()
  const row = JSON.parse(written['/state/units/3/delegations.jsonl'] ?? '{}')
  expect(row).toMatchObject({ model: 'haiku', effort: 'low', description: 'look' })
})

test('an invalid unit file denies and writes no marker', async ($, on) => {
  const written = engine(on, { [UNIT_FILE]: '{"unit": 3}' })
  await $.session.start({ cwd: '/wt/unit3', surface: null, isInteractive: false })

  expect((await $.tool.call({ tool: 'Bash', command: 'ls' })).deny).toBeDefined()
  expect(Object.keys(written)).toEqual([])
})

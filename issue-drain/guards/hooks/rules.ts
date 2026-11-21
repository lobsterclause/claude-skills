// Pure decision functions: each returns a deny message, or undefined to allow.

export type Unit = {
  unit: number
  worktree: string
  branch: string
  state_dir: string
  protected_paths: string[]
}

const P = 'drain-guards:'
const TEMP_DIRS = ['/tmp', '/private/tmp', '/var/folders']

/** Parses the unit file's text; a string result is the reason it is invalid. */
export function parseUnit(text: string): Unit | string {
  let u: Record<string, unknown>
  try {
    u = JSON.parse(text)
  } catch {
    return 'not valid JSON'
  }
  if (typeof u !== 'object' || u === null) return 'not an object'
  const { unit, worktree, branch, state_dir, protected_paths } = u
  if (typeof unit !== 'number') return 'unit must be a number'
  if (typeof worktree !== 'string' || !worktree.startsWith('/')) return 'worktree must be an absolute path'
  if (typeof branch !== 'string' || branch === '') return 'branch must be a non-empty string'
  if (typeof state_dir !== 'string' || !state_dir.startsWith('/')) return 'state_dir must be an absolute path'
  if (!Array.isArray(protected_paths) || protected_paths.some(p => typeof p !== 'string'))
    return 'protected_paths must be a list of strings'
  return { unit, worktree: norm(worktree), branch, state_dir: norm(state_dir), protected_paths }
}

// ---------------------------------------------------------------- Bash

const BYPASS = /--admin\b|--no-verify\b|SKIP_PREPUSH|CROSS_REVIEW_MERGE_OVERRIDE|\bHUSKY=0\b/
const DRIVER_JOB = "merges, closures and label changes are the driver's job; write result.json and exit"
const WRITE_VIA = 'post GitHub writes with `issue-drain gh-write` or post_comment.sh'

// Verbs a unit may never run, per `gh` subcommand group (`*` is any verb).
const GH_DENY: [group: string, verbs: string, why: string][] = [
  ['pr', 'merge', "merges are the driver's job; write result.json and exit"],
  ['pr', 'close|reopen|ready|edit|review', DRIVER_JOB],
  ['issue', 'close|reopen|delete|transfer|lock|unlock|pin|unpin|edit', DRIVER_JOB],
  ['label', '*', DRIVER_JOB],
  ['pr', 'create|comment', WRITE_VIA],
  ['issue', 'create|comment', WRITE_VIA],
  ['release', 'create|edit|delete|upload|delete-asset', WRITE_VIA],
  ['repo', 'create|edit|delete|fork|rename|archive|unarchive|sync', WRITE_VIA],
  ['workflow', 'run|enable|disable', WRITE_VIA],
  ['run', 'rerun|cancel|delete', WRITE_VIA],
  ['secret', '*', "secrets are not a unit's to touch"],
  ['variable', '*', "variables are not a unit's to touch"],
]

export function bashDeny(command: string, branch: string): string | undefined {
  // shortcut: a bypass word inside a quoted message (a commit or comment body) also denies; parse quotes if units hit it.
  if (BYPASS.test(command)) return `${P} bypass flags are not allowed; fix the failing check instead`

  // Split into segments at ; | & newline ( ) and backtick, so a command after a
  // separator, inside $( ) or inside `bash -c '...'` is seen as its own segment.
  // shortcut: a quote spanning a separator is cut in two; fine for matching, upgrade if argument parsing ever needs more.
  const segments = command
    .replace(/\d*>&\d+/g, ' ') // 2>&1 is not a separator
    .split(/[;|&\n()`]+/)
    .map(s => s.replace(/['"]/g, ' ').split(/\s+/).filter(Boolean))

  const hasGh = segments.some(t => t.some(isCmd('gh')))
  if (hasGh && /--auto\b/.test(command)) return `${P} --auto is a merge flag; merges are the driver's job`

  for (const tokens of segments) {
    for (let i = 0; i < tokens.length; i++) {
      // shortcut: any `gh`/`git` word anywhere in a segment counts as a command, so prose that says "gh pr merge" is a false positive.
      const rest = withoutRedirects(tokens.slice(i + 1))
      const deny = isCmd('gh')(tokens[i]!)
        ? ghDeny(rest, command)
        : isCmd('git')(tokens[i]!)
          ? gitDeny(rest, branch)
          : undefined
      if (deny) return deny
    }
  }
}

const isCmd = (name: string) => (token: string) => token === name || token.endsWith('/' + name)

function withoutRedirects(tokens: string[]): string[] {
  const out: string[] = []
  for (let i = 0; i < tokens.length; i++) {
    const t = tokens[i]!
    if (/^\d*[<>]/.test(t)) {
      if (/^\d*>{1,2}$|^<$/.test(t)) i++ // `> file`: drop the file too
    } else out.push(t)
  }
  return out
}

function ghDeny(args: string[], command: string): string | undefined {
  // `gh -R o/r pr merge`: skip global flags (and -R's value) to find the group and verb.
  const words: string[] = []
  for (let i = 0; i < args.length && words.length < 2; i++) {
    const a = args[i]!
    if (a === '-R' || a === '--repo') i++
    else if (!a.startsWith('-')) words.push(a)
  }
  const [group, verb] = words
  if (group === undefined) return
  if (group === 'api') return ghApiDeny(args.slice(args.indexOf('api') + 1), command)
  if (group === 'auth') return verb === 'status' ? undefined : `${P} gh auth is not a unit's to change`
  for (const [g, verbs, why] of GH_DENY) {
    if (g === group && (verbs === '*' || (verb !== undefined && verbs.split('|').includes(verb))))
      return `${P} gh ${group} ${verb ?? ''}: ${why}`
  }
}

function ghApiDeny(args: string[], command: string): string | undefined {
  let method: string | undefined
  let hasBody = false
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!
    const m = /^(?:-X|--method=?)(.*)$/.exec(a)
    if (m) method = (m[1] || args[++i] || '').toUpperCase()
    else if (/^(-[fF]|--field$|--field=|--raw-field$|--raw-field=|--input$|--input=)/.test(a)) hasBody = true
  }
  if (args.some(a => /\/merges?(\/|\?|$)/.test(a)))
    return `${P} gh api merge endpoints: merges are the driver's job; write result.json and exit`
  // A GraphQL read is a POST with fields, so only the endpoint and the query text decide. A unit reads review threads this way.
  if (isGraphql(args)) {
    // Query text read from a file never shows its "mutation" word, so deny every way of reading one.
    if (args.some(a => /^--input(=|$)/.test(a) || a.startsWith('@') || a.includes('=@')))
      return `${P} GraphQL query text from a file cannot be checked; pass the query inline`
    if (method !== undefined && method !== 'POST') return `${P} gh api writes are not allowed; ${WRITE_VIA}`
    // shortcut: any "mutation" in the command denies, even inside a string; parse the query if that bites.
    return /mutation/i.test(command) ? `${P} GraphQL mutations are not allowed; ${WRITE_VIA}` : undefined
  }
  if (method !== undefined && method !== 'GET') return `${P} gh api writes are not allowed; ${WRITE_VIA}`
  if (hasBody && method !== 'GET') return `${P} gh api with a body is a POST; use -X GET or ${WRITE_VIA}`
}

// gh api flags whose value is the next word.
const GH_API_VALUE_FLAGS = /^(-X|--method|-H|--header|-f|-F|--field|--raw-field|--input|-q|--jq|-t|--template|--hostname|--cache|-p|--preview)$/

/** The endpoint is the first word that is neither a flag nor a flag's value. */
function isGraphql(args: string[]): boolean {
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!
    if (GH_API_VALUE_FLAGS.test(a)) i++
    else if (!a.startsWith('-')) return a === 'graphql' || a === '/graphql'
  }
  return false
}

function gitDeny(args: string[], branch: string): string | undefined {
  // --git-dir and --work-tree point git at another repository.
  if (args.some(a => /^--(git-dir|work-tree)(=|$)/.test(a)))
    return `${P} --git-dir/--work-tree point git at another repository; run git inside the unit worktree`
  // Skip git's global options: the two-word ones take a separate value, other leading flags do not.
  let i = 0
  while (args[i]?.startsWith('-'))
    i += /^(-C|-c|--git-dir|--work-tree|--namespace|--super-prefix|--config-env)$/.test(args[i]!) ? 2 : 1
  const verb = args[i]
  const rest = args.slice(i + 1)
  const flags = rest.filter(a => a.startsWith('-'))
  const words = rest.filter(a => !a.startsWith('-'))

  switch (verb) {
    case 'push':
      return pushDeny(rest, branch)
    case 'rebase':
      return `${P} git rebase rewrites pushed commits; the driver syncs the branch with a merge of the base`
    case 'worktree':
      return `${P} git worktree: the driver manages worktrees`
    case 'switch':
      return `${P} git switch would leave the unit's branch; stay on it`
    case 'checkout': {
      // Only a file restore stays: `-- <path>...` or `HEAD -- <path>...`, nothing else before `--`.
      const at = rest[0] === 'HEAD' ? 1 : 0
      return rest[at] === '--' && rest.length > at + 1
        ? undefined
        : `${P} git checkout would leave the unit's branch; stay on it (only \`git checkout [HEAD] -- <path>\` is allowed)`
    }
    case 'branch':
      return flags.some(f => /^-[dDmMcCf]$|^--(delete|move|copy|force)$/.test(f))
        ? `${P} git branch -d/-D/-m/-f changes shared branches; leave them`
        : undefined
    case 'remote':
      return /^(add|set-url|remove|rm|rename|set-head)$/.test(words[0] ?? '')
        ? `${P} git remote changes are the driver's job`
        : undefined
    case 'config':
      return flags.some(f => f === '--global' || f === '--system')
        ? `${P} git config --global/--system is off limits`
        : undefined
    case 'stash':
      // shortcut: `stash push` passes; the stash stack is shared across worktrees, deny it too if units collide.
      return words[0] === undefined || /^(pop|drop|clear)$/.test(words[0])
        ? `${P} git stash shares one stack across worktrees; commit a WIP instead`
        : undefined
  }
}

function pushDeny(args: string[], branch: string): string | undefined {
  const msg = `${P} git push may only push the unit branch (${branch}) to origin, without force`
  if (args.some(a => a.startsWith('-') && a !== '-u' && a !== '--set-upstream')) return msg
  const words = args.filter(a => !a.startsWith('-'))
  // The remote and the destination branch must both be named: a bare `git push`, `git push origin` or
  // `git push origin HEAD` leaves the destination to git config.
  const spec = words[1]
  if (words.length === 0 || (words[0] === 'origin' && (spec === undefined || spec === 'HEAD'))) {
    return `${P} git push must name the remote and the unit branch; run: git push -u origin ${branch}`
  }
  if (words.length > 2 || words[0] !== 'origin') return msg
  if (spec === branch) return
  const [src, dst, ...more] = spec.split(':')
  return more.length === 0 && dst === branch && (src === branch || src === 'HEAD') ? undefined : msg
}

// ---------------------------------------------------------------- paths

/** Resolves `.` and `..` textually; a relative path is taken from `base`. */
function norm(path: string, base = '/'): string {
  const out: string[] = []
  for (const part of (path.startsWith('/') ? path : `${base}/${path}`).split('/')) {
    if (part === '..') out.pop()
    else if (part !== '' && part !== '.') out.push(part)
  }
  return '/' + out.join('/')
}

const within = (path: string, dir: string) => path === dir || path.startsWith(dir === '/' ? '/' : dir + '/')

export function pathDeny(target: string, unit: Unit): string | undefined {
  // shortcut: textual only, so a symlink inside the worktree can lead out; use $.fs.stat({ resolve: true }) if that matters.
  if (target.startsWith('~')) return `${P} use an absolute path inside the worktree (${unit.worktree})`
  const path = norm(target, unit.worktree)
  if (within(path, unit.worktree)) {
    // Case-insensitive: the Mac file system is.
    const lower = path.toLowerCase()
    const hit = unit.protected_paths.find(p => within(lower, norm(p, unit.worktree).toLowerCase()))
    return hit === undefined ? undefined : `${P} ${hit} is protected; leave it and report the need in result.json`
  }
  if (within(path, unit.state_dir) || TEMP_DIRS.some(d => within(path, d))) return
  return `${P} ${target} is outside the worktree (${unit.worktree}); write inside it`
}

// ---------------------------------------------------------------- Agent

export function agentDeny(input: { model?: unknown; effort?: unknown }): string | undefined {
  if (!input.model || !input.effort)
    return `${P} set both model and effort on every Agent call (cheapest model, lowest effort that fits)`
}

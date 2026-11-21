import { expect, test } from 'claude-code/testing'
import { agentDeny, bashDeny, parseUnit, pathDeny, type Unit } from './rules.ts'

const BRANCH = 'fix/issue-3'
const unit: Unit = {
  unit: 3,
  worktree: '/wt/unit3',
  branch: BRANCH,
  state_dir: '/state/units/3',
  protected_paths: ['.github/workflows', '.husky', '.claude', 'firestore.rules', 'infra', 'ci'],
}

const denied: [name: string, command: string][] = [
  // rule 1
  ['merge', 'gh pr merge 1'],
  ['merge, rtk prefix', 'rtk gh pr merge 1'],
  ['merge, cd &&', 'cd x && gh pr merge 1'],
  ['merge, env prefix and extra spaces', 'env A=b gh  pr   merge'],
  ['merge after ;', 'echo hi; gh pr merge 1'],
  ['merge after a pipe', 'echo 1 | gh pr merge'],
  ['merge after a newline', 'echo hi\ngh pr merge 1'],
  ['merge in $( )', 'echo $(gh pr merge 1)'],
  ['merge in backticks', 'echo `gh pr merge 1`'],
  ['merge in bash -c', "bash -c 'gh pr merge 1'"],
  ['merge in bash -c, after &&', "bash -c 'cd x && gh pr merge 1'"],
  ['merge with a global -R flag', 'gh -R o/r pr merge 1'],
  ['merge by full path', '/opt/homebrew/bin/gh pr merge 1'],
  ['api merges endpoint', 'gh api repos/o/r/merges'],
  ['api pull merge endpoint', 'gh api -X PUT repos/o/r/pulls/1/merge'],
  // rule 2
  ['issue close', 'gh issue close 4'],
  ['issue reopen', 'gh issue reopen 4'],
  ['issue edit', 'gh issue edit 4 --remove-label x'],
  ['issue lock', 'gh issue lock 4'],
  ['issue transfer', 'gh issue transfer 4 o/r'],
  ['issue delete', 'gh issue delete 4'],
  ['pr close', 'gh pr close 1'],
  ['pr ready', 'gh pr ready 1'],
  ['pr edit', 'gh pr edit 1 --title x'],
  ['pr review', 'gh pr review 1 --approve'],
  ['pr reopen', 'gh pr reopen 1'],
  ['label list', 'gh label list'],
  ['label delete', 'gh label delete bug'],
  // rule 3
  ['push bare', 'git push'],
['push bare with -u', 'git push -u'],
['push origin alone', 'git push origin'],
['push origin HEAD', 'git push origin HEAD'],
['push to main', 'git push origin main'],
  ['push another remote', `git push upstream ${BRANCH}`],
  ['push --all', 'git push --all origin'],
  ['push --tags', 'git push --tags'],
  ['push --mirror', 'git push --mirror origin'],
  ['push --delete', `git push --delete origin ${BRANCH}`],
  ['push -d', `git push -d origin ${BRANCH}`],
  ['push +refspec', `git push origin +${BRANCH}`],
  ['push :refspec', `git push origin :${BRANCH}`],
  ['push force', `git push --force origin ${BRANCH}`],
  ['push -f', `git push -f origin ${BRANCH}`],
  ['push force-with-lease', `git push --force-with-lease origin ${BRANCH}`],
  ['push force-with-lease=', `git push --force-with-lease=${BRANCH} origin ${BRANCH}`],
  ['push force-if-includes', `git push --force-if-includes origin ${BRANCH}`],
  ['push HEAD to another branch', 'git push origin HEAD:main'],
  ['push two refspecs', `git push origin ${BRANCH} main`],
  ['push after cd &&', 'cd x && git push origin main'],
  ['push with -C', 'git -C /elsewhere push origin main'],
  // rule 4
  ['--admin', 'something --admin'],
  ['--auto with gh', 'gh pr merge 1 --auto'],
  ['--auto with gh elsewhere', 'gh pr view 1; foo --auto'],
  ['--no-verify', 'git commit --no-verify -m x'],
  ['SKIP_PREPUSH', 'SKIP_PREPUSH=1 git push'],
  ['CROSS_REVIEW_MERGE_OVERRIDE', 'CROSS_REVIEW_MERGE_OVERRIDE=1 true'],
  ['HUSKY=0', 'HUSKY=0 git commit -m x'],
  // rule 5
  ['api -X POST', 'gh api -X POST repos/o/r/issues'],
  ['api --method delete', 'gh api --method delete repos/o/r/issues/1'],
  ['api --method=PATCH', 'gh api --method=PATCH repos/o/r/issues/1'],
  ['api -XPOST', 'gh api -XPOST repos/o/r/issues'],
  ['api -f is a POST', 'gh api repos/o/r/issues -f title=x'],
  ['api -F is a POST', 'gh api repos/o/r/issues -F n=1'],
  ['api --field', 'gh api repos/o/r/issues --field title=x'],
  ['api --raw-field', 'gh api repos/o/r/issues --raw-field title=x'],
  ['api --input', 'gh api repos/o/r/issues --input body.json'],
  ['graphql mutation, explicit GET', 'gh api -X GET graphql -f query=\'mutation { x }\''],
  ['graphql mutation', 'gh api graphql -f query=\'mutation { x }\''],
  ['pr create', 'gh pr create --title x'],
  ['pr comment', 'gh pr comment 1 --body x'],
  ['issue create', 'gh issue create --title x'],
  ['issue comment', 'gh issue comment 1 --body x'],
  ['release create', 'gh release create v1'],
  ['repo delete', 'gh repo delete o/r'],
  ['workflow run', 'gh workflow run ci.yml'],
  ['run rerun', 'gh run rerun 9'],
  ['run cancel', 'gh run cancel 9'],
  ['secret set', 'gh secret set X'],
  ['variable list', 'gh variable list'],
  ['auth login', 'gh auth login'],
  ['auth token', 'gh auth token'],
  // rule 6
  ['worktree add', 'git worktree add ../x'],
  ['checkout branch', 'git checkout main'],
  ['checkout -b', 'git checkout -b other'],
  ['switch', 'git switch main'],
  ['switch -c', 'git switch -c other'],
  ['switch main --', 'git switch main --'],
  ['switch -c other --', 'git switch -c other --'],
  ['switch --detach', 'git switch --detach HEAD~1'],
  ['checkout main --', 'git checkout main --'],
  ['checkout -b other --', 'git checkout -b other --'],
  ['checkout bare --', 'git checkout --'],
  ['checkout HEAD --', 'git checkout HEAD --'],
  ['checkout -b other -- path', 'git checkout -b other -- src/lib.rs'],
  ['checkout main -- path', 'git checkout main -- src/lib.rs'],
  ['api -ftitle attached', 'gh api repos/o/r/issues -ftitle=x'],
  ['api -Fbody attached file', 'gh api repos/o/r/issues -Fbody=@b.md'],
  ['api --field separate word', 'gh api repos/o/r/issues --field title=x'],
  ['branch -D', 'git branch -D other'],
  ['branch -d', 'git branch -d other'],
  ['branch -m', 'git branch -m new'],
  ['branch -f', 'git branch -f develop HEAD'],
  ['rebase', 'git rebase origin/develop'],
  ['graphql mutation with POST', 'gh api -X POST graphql -f query=\'mutation { x }\''],
  ['remote add', 'git remote add x url'],
  ['remote set-url', 'git remote set-url origin url'],
  ['remote remove', 'git remote remove origin'],
  ['config --global', 'git config --global user.name x'],
  ['config --system', 'git config --system x y'],
  ['stash bare', 'git stash'],
  ['stash pop', 'git stash pop'],
  ['stash drop', 'git stash drop'],
  ['stash clear', 'git stash clear'],
]

for (const [name, command] of denied) {
  test(`bash denies: ${name}`, () => {
    const why = bashDeny(command, BRANCH)
    expect(why).toBeDefined()
    expect(why?.startsWith('drain-guards:')).toBe(true)
  })
}

const allowed: [name: string, command: string][] = [
  ['pr view', 'gh pr view 1'],
  ['pr checks --watch', 'gh pr checks 1 --watch'],
  ['pr list, diff, status', 'gh pr list; gh pr diff 1; gh pr status'],
  ['issue view and list', 'gh issue view 3; gh issue list'],
  ['run view, list, watch', 'gh run view 1; gh run list; gh run watch 2'],
  ['api GET', 'gh api repos/o/r/pulls/1'],
  ['api explicit GET with fields', 'gh api -X GET repos/o/r/issues -f state=open'],
  ['search', 'gh search prs foo'],
  ['auth status', 'gh auth status'],
  ['push -u origin branch', `git push -u origin ${BRANCH}`],
  ['push --set-upstream origin branch', `git push --set-upstream origin ${BRANCH}`],
  ['push origin branch', `git push origin ${BRANCH}`],
  ['push origin HEAD:branch', `git push origin HEAD:${BRANCH}`],
  ['push origin branch:branch', `git push origin ${BRANCH}:${BRANCH}`],
  ['push, output redirected', `git push origin ${BRANCH} 2>&1`],
  ['push, quoted branch', `git push origin "${BRANCH}"`],
  ['issue-drain gh-write', 'issue-drain gh-write comment --issue 3 --body-file /tmp/b.md'],
  ['post_comment.sh', 'bash /skills/cross-review/post_comment.sh --pr 1 --body-file /tmp/b.md'],
  ['cargo test', 'cargo test'],
  ['pnpm test', 'pnpm test'],
  ['checkout -- path', 'git checkout -- src/lib.rs'],
  ['checkout -- several paths', 'git checkout -- a.rs b.rs'],
  ['checkout HEAD -- path', 'git checkout HEAD -- src/lib.rs'],
  ['api attached -f with explicit GET', 'gh api -X GET repos/o/r/issues -fstate=open'],
  ['reset --hard origin', 'git reset --hard origin/develop'],
  ['stash list', 'git stash list'],
  ['graphql read', 'gh api graphql -f query=\'query($n:Int!){repository(owner:"o",name:"r"){pullRequest(number:$n){reviewThreads(first:100){nodes{id isResolved}}}}}\' -F n=1'],
  ['gh-write pr-create', 'issue-drain gh-write pr-create --head fix/issue-3 --base develop --title t --body-file /tmp/b.md'],
  ['gh-write thread-resolve', 'issue-drain gh-write thread-resolve --thread PRRT_abc'],
  ['status and diff', 'git status && git diff > /tmp/x.diff'],
  ['commit', 'git commit -m "fix thing"'],
]

for (const [name, command] of allowed) {
  test(`bash allows: ${name}`, () => {
    expect(bashDeny(command, BRANCH)).toBeUndefined()
  })
}

test('known false positive: a quoted message that spells a denied command is denied', () => {
  // shortcut in rules.ts: any `gh pr merge` run of words counts, quoted or not.
  expect(bashDeny('git commit -m "fix: gh pr merge wording"', BRANCH)).toBeDefined()
})

const paths: [name: string, path: string, isDenied: boolean][] = [
  ['absolute inside the worktree', '/wt/unit3/src/lib.rs', false],
  ['relative inside the worktree', 'src/lib.rs', false],
  ['.. that stays inside', '/wt/unit3/a/../src/lib.rs', false],
  ['.. escape', '/wt/unit3/../other/x', true],
  ['relative .. escape', '../../etc/passwd', true],
  ['sibling with the same prefix', '/wt/unit3-other/x', true],
  ['another absolute path', '/Users/x/.zshrc', true],
  ['home path', '~/.zshrc', true],
  ['protected directory', '/wt/unit3/.github/workflows/ci.yml', true],
  ['protected directory, relative', '.husky/pre-push', true],
  ['protected file', 'firestore.rules', true],
  ['protected, dot segments', 'src/../ci/run.sh', true],
  ['protected, other case', '.GitHub/Workflows/ci.yml', true],
  ['not protected: similar name', 'ci-notes.md', false],
  ['not protected: nested name', 'src/infra/x.ts', false],
  ['state_dir', '/state/units/3/result.json', false],
  ['/tmp', '/tmp/scratch.txt', false],
  ['/private/tmp', '/private/tmp/x/y', false],
  ['/var/folders', '/var/folders/ab/cd/T/x', false],
  ['/tmp escape by ..', '/tmp/../etc/hosts', true],
  ['another unit state_dir', '/state/units/4/result.json', true],
]

for (const [name, path, isDenied] of paths) {
  test(`path ${isDenied ? 'denies' : 'allows'}: ${name}`, () => {
    const why = pathDeny(path, unit)
    expect(why !== undefined).toBe(isDenied)
    if (why) expect(why.startsWith('drain-guards:')).toBe(true)
  })
}

test('agent: missing model, missing effort, both set', () => {
  expect(agentDeny({ effort: 'low' })).toBeDefined()
  expect(agentDeny({ model: 'haiku' })).toBeDefined()
  expect(agentDeny({})).toBeDefined()
  expect(agentDeny({ model: 'haiku', effort: 'low' })).toBeUndefined()
})

test('parseUnit: a good file, and each way a file is invalid', () => {
  const good = { ...unit, worktree: '/wt/unit3/' }
  expect(parseUnit(JSON.stringify(good))).toEqual(unit)
  expect(typeof parseUnit('{')).toBe('string')
  expect(typeof parseUnit('null')).toBe('string')
  for (const bad of [{ unit: '3' }, { worktree: 'rel' }, { branch: '' }, { state_dir: 'rel' }, { protected_paths: [1] }])
    expect(typeof parseUnit(JSON.stringify({ ...unit, ...bad }))).toBe('string')
})

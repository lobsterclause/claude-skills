// The drain-console contract: the one value its pane draws from.

/** One unit of the queue, as the console shows it. */
export type UnitRow = {
  unit: number
  /** `U<n>`, as queue.json names it. */
  id: string
  issues: number[]
  /** From queue.json; empty when the queue has no title for the unit. */
  title: string
  /** The state machine's name for where the unit is (state.json). */
  state: string
  pr: number | null
  /** When the driver last moved the unit, ms since the epoch. */
  updatedMs: number | null
  /** The newest merge-gate refusal reasons for the unit; empty when none. */
  refusals: string[]
  /** The `--note` of the newest `state event` the driver wrote for the unit. */
  note: string | null
  /** Sum of `cost_usd` over the unit's attempts: a client-side estimate. */
  costUsd: number | null
}

/** A run folder read once. */
export type View = {
  runDir: string
  runId: string
  repo: string
  trackerUrl: string | null
  trackerNumber: number | null
  units: UnitRow[]
  stopped: { ts: string; reason: string } | null
  /** A STOP file is in the run folder (the driver has not acted on it yet). */
  stopRequested: boolean
  /** Units in a terminal state (done, skipped, blocked, parked). */
  finished: number
  total: number
  isFinished: boolean
  /** The newest driver call other than `state show`, e.g. `unit-run --unit 1 (exit 0)`. */
  lastCall: string | null
  /** The newest sign of life: events.jsonl's mtime or a unit's `updated`. */
  lastActivityMs: number | null
}

/** What the pane draws: the newest read, or why there is none. */
export type Snapshot = {
  view: View | null
  /** Why `view` is null, or a read problem worth showing beside it. */
  note: string
  /** When the console last read the run, ms since the epoch. */
  readAtMs: number
}

declare module 'claude-code' {
  interface PluginState {
    'drain-console': { snapshot: Shaped<Snapshot> }
  }
}

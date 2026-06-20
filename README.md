# pipeline-dispatch

The third member of the trio:

| repo | role |
|---|---|
| [`pipeline`](https://github.com/jackypanster/pipeline) | defines the contract: 5-stage state machine + handoff format + git/md state bus + anti-cheat. |
| **`pipeline-dispatch`** (this) | automates the **one** stage worth automating — `impl` — and pings Telegram. |
| [`pipeline-dashboard`](https://github.com/jackypanster/pipeline-dashboard) | read-only `board.html` renderer over any `.pipeline/` checkout. |

Zero coupling: this repo does not import or modify `pipeline`. It is just an external
executor that runs one stage "by the contract", which the contract explicitly allows
(`roles.yaml` names the skill; any runtime may run it). The pipeline's "no scheduler"
purity is preserved — nothing here is a scheduler.

## The convention

The pipeline runs **human-relayed, as designed**. A human copies each
`>>> NEXT … <<< END` handoff to the next executor.

- **prd / arch / task / review** → stay human-relayed, **in Claude Code** (CC). That is
  where the human is *and* where the interview/decision skills live
  (`grill-with-docs`, `grilling`, `domain-modeling`, `think`, `check`). The local Hermes
  does **not** have these — do not try to relay these stages to it.
- **impl** → the long, autonomous `think→code→check→commit` loop. This is the only stage
  that is (a) self-contained enough to run headless and (b) installed on the local Hermes
  (`goal-driven-implementation`). `dispatch.sh` fires it headless and pings you on
  done / blocked, so you can **walk away**.

CC therefore is not an orchestration loop — it is your interactive console for the four
human-side stages plus the button that launches `dispatch.sh`.

## Usage

```bash
# after `task` has frozen at least one todo card and pushed:
./dispatch.sh ~/workspace/rust-todo-api          # blocks until impl finishes; pings TG
nohup ./dispatch.sh ~/workspace/rust-todo-api &  # or detach and walk away
```

Env overrides:

| var | default | meaning |
|---|---|---|
| `DISPATCH_TG` | `telegram:牛马军团` | Telegram target (or use chat id, e.g. `telegram:-1003844184820`) |
| `DISPATCH_TIMEOUT` | `1800` | wall-clock seconds before the impl run is killed |
| `HERMES` | `hermes` | hermes binary |

## What the script guarantees (and what it deliberately does not)

Hardenings, each tracing to a real failure mode:

- **Right repo** — headless `hermes` does *not* `chdir` to the target, so the script
  `cd`s in and asserts `git rev-parse --show-toplevel`, refusing to run against the
  wrong tree.
- **Slot pre-flight** — skipping `prd` skips the contract's only front-of-pipeline
  "all slots resolve" gate, so the script re-checks that `goal-driven-implementation`
  is installed on this runtime before firing.
- **Wall-clock timeout** — macOS has no `timeout(1)`; the script backgrounds the run
  with a watchdog `kill`.
- **Handoff by anchors only** — `-Q` stdout carries a banner line before the answer and
  the model may wrap the block in ```` ``` ````; extraction uses the `>>> NEXT` / `<<< END`
  anchors and strips fences. `session_id` is on **stderr** and never read.
- **Exit code is coarse** — a skill `STOP` or a `blocked` card still exits `0`; success
  is decided by parsing the handoff `status`, not the exit code.
- **No guessing** — if the handoff block is absent, the script escalates to Telegram with
  the raw tail instead of inventing a next step.

What it does **not** do, on purpose:

- It does **not** trust any value the model prints. `branch` / `attempts` / `pr` /
  `spec-rev` are authoritative only in **git** — verify them with `git pull` +
  `journal.md` tail + `gh pr view` when you come back for `review`. The forwarded handoff
  is a copy for your eyes.
- It does **not** merge. Merge is a hard human-confirmed gate owned by `pipeline-review`.

## The one discipline: serial single-writer

CC writes the prd/arch/task/review metadata; the dispatched Hermes writes the impl code
and its journal entry — **two writers, never concurrent**. Keep it strictly serial:
CC finishes `task` → pushes → *then* runs `dispatch.sh` → waits for the run (or the TG
ping) → *then* does `review`. Never touch the target repo's git while `dispatch.sh` is
running. Serial execution is the lock; there is no other lock.

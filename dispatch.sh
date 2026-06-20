#!/usr/bin/env bash
#
# dispatch.sh — automate the ONE pipeline stage worth automating: impl.
#
# The `pipeline` (jackypanster/pipeline) runs human-relayed: a human copies each
# `>>> NEXT … <<< END` handoff to the next bot. prd/arch/task/review stay that way
# (interactive, in Claude Code, where the human + the grill/think/check skills live).
#
# This script automates only `impl` — the long, autonomous think→code→check→commit
# loop — by firing it headless on the LOCAL Hermes and pinging Telegram when it
# finishes or blocks, so the operator can walk away.
#
# impl self-bootstraps from the git bus (the shim does `git pull --rebase` → reads
# `.pipeline/current.json` + the feature's `journal.md` tail → picks the oldest todo
# card), so this script does NOT thread the handoff in — it just says "run impl".
#
# Authoritative state lives in git, NEVER in this stdout. The handoff forwarded to
# Telegram is a *copy for your eyes*; verify branch/attempts/PR with git at review.
#
# Usage:  ./dispatch.sh /path/to/target-repo
# Env:    DISPATCH_TG       Telegram target   (default: telegram:牛马军团)
#         DISPATCH_TIMEOUT  wall-clock secs   (default: 1800)
#         HERMES            hermes binary     (default: hermes on PATH)

set -euo pipefail

REPO="${1:?usage: dispatch.sh /path/to/target-repo}"
TG="${DISPATCH_TG:-telegram:牛马军团}"
TIMEOUT="${DISPATCH_TIMEOUT:-1800}"
HERMES="${HERMES:-hermes}"
SKILL="pipeline-impl"
SLOT="goal-driven-implementation"   # the skill pipeline-impl delegates to (roles.yaml)

die() { echo "dispatch: $*" >&2; exit 1; }
notify() { # notify <subject> <body>
  "$HERMES" send --to "$TG" -s "$1" "$2" >/dev/null 2>&1 \
    || echo "dispatch: WARNING telegram send failed (subject: $1)" >&2
}

# --- 1. land in the right repo, and prove it (headless hermes does NOT chdir for us)
[ -d "$REPO/.git" ] || die "not a git repo: $REPO"
cd "$REPO"
top="$(git rev-parse --show-toplevel)"
[ "$top" = "$(cd "$REPO" && pwd)" ] || die "toplevel mismatch: $top != $REPO (wrong repo guard)"
[ -f .pipeline/current.json ] || die "no .pipeline/current.json — run prd/arch/task first"

# --- 2. pre-flight: restore the all-slot init gate that skipping prd would skip.
#        For impl-only we just need the impl slot resolvable on THIS runtime.
"$HERMES" skills list 2>/dev/null | grep -q "$SLOT" \
  || die "impl slot '$SLOT' not installed on this Hermes runtime — install before dispatch"

# --- 3. fire impl headless with a wall-clock timeout (macOS has no `timeout(1)`).
OUT="$(mktemp -t dispatch.out.XXXXXX)"; ERR="$(mktemp -t dispatch.err.XXXXXX)"
trap 'rm -f "$OUT" "$ERR"' EXIT

PROMPT='Run pipeline-impl per CONTRACT.md. First `git pull --rebase`, read .pipeline/current.json + the feature journal.md tail, pick the OLDEST todo card, make its frozen red test green (you may add white-box tests in impl-paths, but DO NOT touch spec-paths), open a PR, set status=review, and print the `>>> NEXT … <<< END` handoff block verbatim as your final output.'

echo "dispatch: firing $SKILL on $REPO (timeout ${TIMEOUT}s) …" >&2
"$HERMES" chat -q "$PROMPT" -Q --skills "$SKILL" --yolo >"$OUT" 2>"$ERR" &
pid=$!
( sleep "$TIMEOUT"; kill -TERM "$pid" 2>/dev/null ) &
watcher=$!
rc=0; wait "$pid" || rc=$?
kill -TERM "$watcher" 2>/dev/null || true; wait "$watcher" 2>/dev/null || true

# --- 4. exit code is a COARSE filter only (skill STOP / blocked are normal EXIT=0).
if [ "$rc" -ge 124 ] || { [ "$rc" -gt 0 ] && ! grep -q '>>> NEXT' "$OUT"; }; then
  body="$(tail -n 40 "$OUT" "$ERR" 2>/dev/null)"
  echo "dispatch: impl did not finish cleanly (rc=$rc)" >&2
  notify "⚠️ impl 启动/运行失败 (rc=$rc)" "${body:-no output}"
  exit 1
fi

# --- 5. extract the handoff block by ANCHORS only (stdout has banner noise before it;
#        session_id is on stderr). Strip any markdown code fences the model may wrap it in.
handoff="$(sed -n '/>>> NEXT/,/<<< END/p' "$OUT" | sed '/^```/d')"
if [ -z "$handoff" ]; then
  echo "dispatch: no handoff block found — not guessing, escalating" >&2
  notify "🟠 impl 跑完但抓不到 handoff 块,请人工看" "$(tail -n 40 "$OUT")"
  exit 2
fi

# --- 6. classify by the handoff's own status; the human verifies authoritative state at review.
if printf '%s' "$handoff" | grep -qiE 'status=[^[:space:]]*(blocked|failed)|pipeline-hunt'; then
  echo "dispatch: impl BLOCKED" >&2
  notify "🔴 impl 卡住,需你介入 (pipeline-hunt)" "$handoff"
else
  echo "dispatch: impl DONE — PR awaiting your review" >&2
  notify "✅ impl 完成,PR 待你 review" "$handoff"
fi

printf '%s\n' "$handoff"

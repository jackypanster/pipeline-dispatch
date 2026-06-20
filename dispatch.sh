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
# Portable: bash 3.2+ (macOS default) and bash on Ubuntu. No bashisms beyond 3.2,
# no GNU-only flags, no `timeout(1)` (macOS lacks it).
#
# Usage:  ./dispatch.sh /path/to/target-repo
# Env:    DISPATCH_TG       Telegram target   (default: telegram = bot home channel / your DM)
#         DISPATCH_TIMEOUT  wall-clock secs   (default: 1800)
#         HERMES            hermes binary     (default: hermes on PATH)

set -euo pipefail

REPO="${1:?usage: dispatch.sh /path/to/target-repo}"
# bare "telegram" = the configured bot's home channel (here @agent_m4_bot → your DM).
TG="${DISPATCH_TG:-telegram}"
TIMEOUT="${DISPATCH_TIMEOUT:-1800}"
HERMES="${HERMES:-hermes}"
SKILL="pipeline-impl"   # the skill passed to --skills; it delegates to goal-driven-implementation

die() { echo "dispatch: $*" >&2; exit 1; }
notify() { # notify <subject> <body>
  "$HERMES" send --to "$TG" -s "$1" "$2" >/dev/null 2>&1 \
    || echo "dispatch: WARNING telegram send failed (subject: $1)" >&2
}

# --- 1. land in the right repo, and prove it (headless hermes does NOT chdir for us)
[ -d "$REPO/.git" ] || die "not a git repo: $REPO"
cd "$REPO"
top="$(git rev-parse --show-toplevel)"
[ "$top" = "$(pwd -P)" ] || die "toplevel mismatch: $top != $(pwd -P) (wrong repo guard)"
[ -f .pipeline/current.json ] || die "no .pipeline/current.json — run prd/arch/task first"

# --- 2. pre-flight: restore the all-slot init gate that skipping prd would skip.
#        Check the skill we pass to --skills ("pipeline-impl") — it shows untruncated in
#        `skills list`. We do NOT grep the delegated slot (goal-driven-implementation): the
#        table truncates long names ("goal-driven-implementa…"), so an exact grep false-negatives.
#        If the delegated slot is missing, `hermes chat` itself errors ("Unknown skill(s)" / a
#        resolution STOP) and step-4's failure path catches it — one layer later, still surfaced.
# Capture-then-match, NOT `… | grep -q`: under `set -o pipefail`, grep -q exits on the first
# match and closes the pipe, so the long `skills list` producer dies with SIGPIPE and poisons
# the pipe status — a false "not installed". A glob match on the captured string has no pipe.
skills_out="$("$HERMES" skills list 2>/dev/null || true)"
case "$skills_out" in
  *"$SKILL"*) : ;;
  *) die "skill '$SKILL' not installed on this Hermes runtime — install before dispatch" ;;
esac

# --- 3. fire impl headless with a wall-clock timeout (macOS has no `timeout(1)`).
# mktemp: BSD (macOS) `-t` takes a bare prefix; GNU (Ubuntu) `-t` wants a template.
# An explicit path template ending in X's is the one form both accept identically.
OUT="$(mktemp "${TMPDIR:-/tmp}/dispatch.out.XXXXXX")"; ERR="$(mktemp "${TMPDIR:-/tmp}/dispatch.err.XXXXXX")"
trap 'rm -f "$OUT" "$ERR"' EXIT

PROMPT='Run pipeline-impl per CONTRACT.md. First `git pull --rebase`, read .pipeline/current.json + the feature journal.md tail, pick the OLDEST todo card, make its frozen red test green (you may add white-box tests in impl-paths, but DO NOT touch spec-paths), open a PR, set status=review, and print the `>>> NEXT … <<< END` handoff block verbatim as your final output.'

# `set -m` makes each background job its own process-group leader (PGID == its PID), so a
# timeout can kill the whole TREE — hermes plus the git/cargo/npm children it spawns — via
# a negative-PID group signal. Without it, `kill $pid` leaves orphaned children still
# mutating the repo after we report failure, breaking the serial-single-writer rule.
# Verified to reap the child tree on macOS (bash 3.2) and Ubuntu.
echo "dispatch: firing $SKILL on $REPO (timeout ${TIMEOUT}s) …" >&2
set -m
"$HERMES" chat -q "$PROMPT" -Q --skills "$SKILL" --yolo >"$OUT" 2>"$ERR" &
pid=$!
( sleep "$TIMEOUT"; kill -TERM -"$pid" 2>/dev/null ) &   # negative PID = whole process group
watcher=$!
rc=0; wait "$pid" || rc=$?
kill -TERM -"$watcher" 2>/dev/null || true; wait "$watcher" 2>/dev/null || true
kill -TERM -"$pid"     2>/dev/null || true   # belt-and-braces: reap any straggler in the group
set +m

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

# --- 6. route on the handoff's authoritative next-command directive (the `Run pipeline-X.`
#        line), NOT on free-text: the block also names hunt/blocked in standing cautions.
#        impl has 3 next-steps (see pipeline-impl/SKILL.md): hunt = blocked (attempts>=3);
#        impl = passed-but-more-cards OR retry (attempts<3) ⇒ re-run dispatch; review = all
#        cards done ⇒ human reviews. We match `Run pipeline-X` at line start so the lowercase
#        mid-line caution `⇒ run pipeline-hunt` does not trip the router.
# Capture all `Run pipeline-X` directive tokens (|| true swallows no-match / SIGPIPE under
# pipefail); take the first line via parameter expansion (no `head` pipe, which would early-close
# and poison the status); lowercase it. Empty ⇒ falls to the *) escalation case.
runs="$(printf '%s\n' "$handoff" | grep -oiE '^[[:space:]]*Run +pipeline-(impl|review|hunt)' | grep -oiE 'pipeline-(impl|review|hunt)' || true)"
next_cmd="$(printf '%s' "${runs%%$'\n'*}" | tr 'A-Z' 'a-z')"

status=0
case "$next_cmd" in
  pipeline-hunt)
    echo "dispatch: impl BLOCKED (attempts>=3) -> pipeline-hunt" >&2
    notify "🔴 impl 卡住 (attempts>=3),需你介入 pipeline-hunt" "$handoff" ;;
  pipeline-impl)
    echo "dispatch: card done/retry, MORE cards remain -> re-run dispatch" >&2
    notify "🔁 一张卡完成或重试中,还有卡未做 — 需再跑一次 dispatch.sh" "$handoff" ;;
  pipeline-review)
    echo "dispatch: ALL cards done -> human review" >&2
    notify "✅ 全部卡完成,PR 待你 review" "$handoff" ;;
  *)
    echo "dispatch: cannot determine next command from handoff -> escalating" >&2
    notify "🟠 抓到 handoff 但判不出下一步,请人工看" "$handoff"; status=2 ;;
esac

printf '%s\n' "$handoff"
exit "$status"

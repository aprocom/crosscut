#!/usr/bin/env bash
# plan-review-limits.sh — read plan_review (reference: codex) account rate-limits.
# No-op unless plan_review == codex. English output.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh" 2>/dev/null || true

JSON_OUT="${1:-}"

# If config is present and plan_review is not codex, no-op.
if command -v cfg_get >/dev/null 2>&1; then
  if [ "$(cfg_get plan_review none)" != "codex" ]; then
    [ "$JSON_OUT" = "--json" ] && echo '{"plan_review":"disabled"}' || echo "plan_review: disabled or non-codex (limits n/a)"
    exit 0
  fi
fi

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
SESS_DIR="$CODEX_HOME/sessions/$(date +%Y/%m/%d)"
ROLLOUT="$(ls -t "$SESS_DIR"/rollout-*.jsonl 2>/dev/null | head -1 || true)"
if [ -z "$ROLLOUT" ]; then
  [ "$JSON_OUT" = "--json" ] && echo '{"error":"no_rollout"}' || echo "plan_review: no rollout today (limits unknown)"
  exit 0
fi

python3 - "$ROLLOUT" "$JSON_OUT" <<'PY'
import json, sys, time, datetime
rollout, json_out = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "")
last = None
for line in open(rollout):
    if '"rate_limits"' in line:
        last = line
def find(o):
    if isinstance(o, dict):
        if o.get("rate_limits"):
            return o["rate_limits"]
        for v in o.values():
            r = find(v)
            if r:
                return r
    return None
rl = None
if last:
    try:
        rl = find(json.loads(last))
    except (ValueError, TypeError):
        rl = None
if not rl:
    print('{"error":"no_rate_limits"}' if json_out == "--json" else "plan_review: rate_limits not found")
    sys.exit(0)
now = int(time.time())
p, s = rl.get("primary") or {}, rl.get("secondary") or {}
cand = [(n, w.get("used_percent", 0), w.get("resets_at", 0)) for n, w in (("primary", p), ("secondary", s)) if w]
binding = max(cand, key=lambda c: c[1]) if cand else None
reached = rl.get("rate_limit_reached_type") is not None
if json_out == "--json":
    print(json.dumps({
        "primary_pct": p.get("used_percent"),
        "secondary_pct": s.get("used_percent"),
        "binding_window": binding[0] if binding else None,
        "binding_resets_at": binding[2] if binding else None,
        "reached": reached,
        "wait_seconds": max(0, (binding[2] - now)) if binding else 0,
    }))
else:
    rs = datetime.datetime.fromtimestamp(binding[2]).strftime("%Y-%m-%d %H:%M") if binding else "?"
    flag = " [REACHED]" if reached else ""
    print(f"plan_review: 5h {p.get('used_percent','?')}% · weekly {s.get('used_percent','?')}%, "
          f"next reset ({binding[0] if binding else '?'}) {rs}{flag}")
PY

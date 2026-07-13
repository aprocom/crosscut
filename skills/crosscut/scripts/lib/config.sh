#!/usr/bin/env bash
# config.sh — resolve and query crosscut.config.yaml (YAML via python3+PyYAML).
# Source this file; do not execute. Self-locating; no plugin-env dependency.

# Resolve config path: $CROSSCUT_CONFIG → $HOME/.crosscut/ → fail(1).
crosscut_config_path() {
  if [ -n "${CROSSCUT_CONFIG:-}" ] && [ -f "$CROSSCUT_CONFIG" ]; then
    printf '%s\n' "$CROSSCUT_CONFIG"
    return 0
  fi
  local home_cfg="$HOME/.crosscut/crosscut.config.yaml"
  if [ -f "$home_cfg" ]; then
    printf '%s\n' "$home_cfg"
    return 0
  fi
  return 1
}

# Internal: run a python snippet against the loaded config with $1=query arg.
_crosscut_py() {
  local cfg
  cfg="$(crosscut_config_path)" || return 1
  CROSSCUT_CFG="$cfg" CROSSCUT_ARG="${1:-}" CROSSCUT_DEF="${2:-}" python3 - <<'PY'
import os, sys
try:
    import yaml
except ImportError:
    sys.stderr.write("crosscut: PyYAML required (pip install pyyaml)\n")
    sys.exit(3)
try:
    cfg = yaml.safe_load(open(os.environ["CROSSCUT_CFG"])) or {}
except yaml.YAMLError as _e:
    _reason = getattr(_e, "problem", None) or str(_e).splitlines()[0]
    sys.stderr.write("crosscut: config YAML is invalid (%s): %s; run /crosscut validate\n"
                     % (os.environ["CROSSCUT_CFG"], _reason))
    sys.exit(2)
mode = os.environ.get("CROSSCUT_MODE", "get")
arg = os.environ["CROSSCUT_ARG"]
default = os.environ["CROSSCUT_DEF"]

def emit(v):
    if isinstance(v, bool):
        print("true" if v else "false")
    else:
        print(v)

if mode == "get":
    node = cfg
    for key in arg.split("."):
        if isinstance(node, dict) and key in node:
            node = node[key]
        else:
            node = None
            break
    if node is None:
        print(default)
    else:
        emit(node)
elif mode == "repo_names":
    for r in cfg.get("repos", []) or []:
        if isinstance(r, dict) and r.get("name"):
            print(r["name"])
elif mode == "repo_field":
    name, field = arg.split("\t", 1)
    for r in cfg.get("repos", []) or []:
        if isinstance(r, dict) and r.get("name") == name:
            v = r.get(field)
            if v is None:
                print(default)
            else:
                emit(v)
            break
    else:
        print(default)
elif mode == "repo_product":
    for r in cfg.get("repos", []) or []:
        if isinstance(r, dict) and r.get("name") == arg:
            print(r.get("product") or r.get("name"))
            break
    else:
        print(default)
elif mode == "products":
    seen = set()
    for r in cfg.get("repos", []) or []:
        if isinstance(r, dict) and r.get("name"):
            seen.add(r.get("product") or r.get("name"))
    for p in sorted(seen):
        print(p)
elif mode == "product_repos":
    for r in cfg.get("repos", []) or []:
        if isinstance(r, dict) and r.get("name"):
            if (r.get("product") or r.get("name")) == arg:
                print(r["name"])
elif mode == "repo_monorepo":
    name, key = arg.split("\t", 1)
    for r in cfg.get("repos", []) or []:
        if isinstance(r, dict) and r.get("name") == name:
            mono = r.get("monorepo")
            v = mono.get(key) if isinstance(mono, dict) else None
            if v is None:
                print(default)
            else:
                emit(v)
            break
    else:
        print(default)
elif mode == "list":
    node = cfg
    for key in arg.split("."):
        if isinstance(node, dict) and key in node:
            node = node[key]
        else:
            node = None
            break
    if node is None:
        pass
    elif isinstance(node, list):
        for item in node:
            emit(item)
    else:
        emit(node)
elif mode == "product_kb":
    prod = arg
    prods = cfg.get("products")
    pkb = None
    if isinstance(prods, dict):
        pnode = prods.get(prod)
        if isinstance(pnode, dict) and isinstance(pnode.get("knowledge_base"), dict):
            pkb = pnode["knowledge_base"]
    gkb = cfg.get("knowledge_base")
    if not isinstance(gkb, dict):
        gkb = {}
    # path-target first: per-product path (verbatim), else <global base>/<product>.
    # Both the per-product path and the configured/default global base are ~-expanded.
    ppath = pkb.get("path") if isinstance(pkb, dict) else None
    if ppath is not None and str(ppath) != "":
        path_target = os.path.expanduser(str(ppath))
    else:
        gbase = gkb.get("path")
        if gbase is None or str(gbase) == "":
            gbase = "~/.crosscut/knowledge"
        path_target = os.path.join(os.path.expanduser(str(gbase)), prod)
    # then decide mcp vs path. A per-product mcp KEY, when present, is authoritative
    # (detected by key presence, not truthiness): a non-empty value → MCP wins; an
    # empty-string "" value → explicit opt-out to the path form, which does NOT fall
    # through to the global mcp. Only when there is no per-product mcp key do we inherit
    # the global knowledge_base.mcp (non-empty → MCP wins, else path).
    mcp = None
    if isinstance(pkb, dict) and "mcp" in pkb:
        pm = pkb.get("mcp")
        if pm is not None and str(pm) != "":
            mcp = str(pm)
    else:
        gm = gkb.get("mcp")
        if gm is not None and str(gm) != "":
            mcp = str(gm)
    if mcp is not None:
        print("mcp\t%s\t%s" % (mcp, path_target))
    else:
        print("path\t%s" % path_target)
PY
}

cfg_get() { CROSSCUT_MODE=get _crosscut_py "$1" "${2:-}"; }
cfg_repo_names() { CROSSCUT_MODE=repo_names _crosscut_py "" ""; }
cfg_repo_field() { CROSSCUT_MODE=repo_field _crosscut_py "$1"$'\t'"$2" "${3:-}"; }
cfg_repo_product() { CROSSCUT_MODE=repo_product _crosscut_py "$1" "${2:-}"; }
cfg_products() { CROSSCUT_MODE=products _crosscut_py "" ""; }
cfg_product_repos() { CROSSCUT_MODE=product_repos _crosscut_py "$1" ""; }
cfg_repo_monorepo() { CROSSCUT_MODE=repo_monorepo _crosscut_py "$1"$'\t'"$2" "${3:-}"; }
cfg_list() { CROSSCUT_MODE=list _crosscut_py "$1" ""; }
# cfg_product_kb <product> — resolve a product's knowledge base.
# Prints one tab-separated line:
#   mcp\t<endpoint>\t<path-target>   when an mcp endpoint is in effect. mcp is resolved by
#                                    KEY PRESENCE: an `mcp` key on
#                                    products.<product>.knowledge_base is authoritative —
#                                    non-empty → that endpoint; empty-string "" → explicit
#                                    opt-out to the path form (does NOT inherit the global
#                                    mcp). With no per-product `mcp` key, the global
#                                    knowledge_base.mcp applies (non-empty → mcp). The third
#                                    field is the fallback path used if the endpoint is down.
#   path\t<path-target>              otherwise (no effective mcp: a per-product opt-out,
#                                    or an empty/absent global mcp with no per-product one).
# The path-target is products.<product>.knowledge_base.path (verbatim) if set, else
# <knowledge_base.path>/<product> where the global base defaults to
# ~/.crosscut/knowledge. Both the per-product path and the global base are
# ~-expanded.
cfg_product_kb() { CROSSCUT_MODE=product_kb _crosscut_py "$1" ""; }

# cfg_check_depends <slug> — enforce the product boundary on a plan's depends_on.
# Locates the plan for <slug> across every configured repo's
# <repo.path>/<plans_dir>/<slug>.md (plans_dir defaults to docs/plans), reads its
# frontmatter `repo`/`depends_on`, and checks every dependency stays inside this plan's
# product (a repo's product is its `product` field, else its `name`).
# Exit codes:
#   0        — resolved, and depends_on is empty or entirely within the same product.
#   non-zero — slug unresolved (0 repos) or ambiguous (2+ repos); a dependency whose plan
#              file is missing/ambiguous or whose frontmatter `repo` is absent from the
#              config; or any dependency resolving to a different product (cross-product).
cfg_check_depends() {
  local cfg
  cfg="$(crosscut_config_path)" || return 1
  CROSSCUT_CFG="$cfg" CROSSCUT_SLUG="${1:-}" python3 - <<'PY'
import os, sys
try:
    import yaml
except ImportError:
    sys.stderr.write("crosscut: PyYAML required (pip install pyyaml)\n")
    sys.exit(3)

try:
    cfg = yaml.safe_load(open(os.environ["CROSSCUT_CFG"])) or {}
except yaml.YAMLError as _e:
    _reason = getattr(_e, "problem", None) or str(_e).splitlines()[0]
    sys.stderr.write("crosscut: config YAML is invalid (%s): %s; run /crosscut validate\n"
                     % (os.environ["CROSSCUT_CFG"], _reason))
    sys.exit(2)
slug = (os.environ.get("CROSSCUT_SLUG") or "").strip()
if not slug:
    sys.stderr.write("cfg_check_depends: a plan slug is required\n")
    sys.exit(2)

repos = [r for r in (cfg.get("repos") or [])
         if isinstance(r, dict) and r.get("name")]
names = {r["name"] for r in repos}

def product_of(repo_name):
    for r in repos:
        if r["name"] == repo_name:
            return r.get("product") or r["name"]
    return None

def locate(a_slug):
    """Every (repo, path) holding this slug's plan. Active plans live at
    <plans_dir>/<slug>.md; completed plans move to <plans_dir>/completed/<slug>.md,
    so a dependency on an already-done plan must still resolve. At most one hit per
    repo (active preferred, then completed)."""
    hits = []
    for r in repos:
        base = os.path.expanduser(r.get("path") or "")
        plans_dir = r.get("plans_dir") or "docs/plans"
        for sub in ("", "completed"):
            fp = os.path.join(base, plans_dir, sub, a_slug + ".md")
            if os.path.isfile(fp):
                hits.append((r, fp))
                break
    return hits

def frontmatter(path):
    with open(path) as fh:
        text = fh.read()
    if not text.startswith("---"):
        return {}
    body = text[3:]
    end = body.find("\n---")
    if end == -1:
        return {}
    fm = yaml.safe_load(body[:end]) or {}
    return fm if isinstance(fm, dict) else {}

hits = locate(slug)
if len(hits) == 0:
    sys.stderr.write("cfg_check_depends: no plan file for slug '%s' in any repo\n" % slug)
    sys.exit(1)
if len(hits) > 1:
    sys.stderr.write("cfg_check_depends: slug '%s' is ambiguous (found in %d repos)\n"
                     % (slug, len(hits)))
    sys.exit(1)

fm = frontmatter(hits[0][1])
repo = fm.get("repo")
if repo not in names:
    sys.stderr.write("cfg_check_depends: plan '%s' names repo '%s' not in config\n"
                     % (slug, repo))
    sys.exit(1)
this_product = product_of(repo)

deps = fm.get("depends_on") or []
if isinstance(deps, str):
    deps = [deps]
for dep in deps:
    dep = str(dep).strip()
    if not dep:
        continue
    dhits = locate(dep)
    if len(dhits) != 1:
        sys.stderr.write("cfg_check_depends: dependency '%s' is unresolved/ambiguous "
                         "(found in %d repos)\n" % (dep, len(dhits)))
        sys.exit(1)
    drepo = frontmatter(dhits[0][1]).get("repo")
    if drepo not in names:
        sys.stderr.write("cfg_check_depends: dependency '%s' names repo '%s' not in "
                         "config\n" % (dep, drepo))
        sys.exit(1)
    if product_of(drepo) != this_product:
        sys.stderr.write("cfg_check_depends: dependency '%s' (product '%s') crosses the "
                         "product boundary of '%s' (product '%s')\n"
                         % (dep, product_of(drepo), slug, this_product))
        sys.exit(1)
sys.exit(0)
PY
}

# ---- per-repo executor lock (P4 parallelism) ----------------------------------
# Filesystem-only mutual exclusion so at most one executor runs per repo at a time.
# The lock is a directory <runs_dir>/<repo>/executor.lock/ whose `owner` file holds
# "<pid> <token>". mkdir(2) is the atomic primitive: exactly one racer creates the
# dir. A lock whose owner PID is no longer alive is *stale* and may be reclaimed.
# <runs_dir> = `cfg_get executor_options.runs_dir` (default ~/.cache/crosscut-runs,
# leading ~ expanded). No PyYAML here — pure shell + the filesystem.

# _crosscut_runs_dir — the ~-expanded runs_dir base.
_crosscut_runs_dir() {
  local base
  base="$(cfg_get executor_options.runs_dir "$HOME/.cache/crosscut-runs")"
  printf '%s\n' "${base/#\~/$HOME}"
}

# _crosscut_lock_dir <repo> — path of the repo's executor lock directory.
_crosscut_lock_dir() {
  printf '%s\n' "$(_crosscut_runs_dir)/$1/executor.lock"
}

# _crosscut_lock_owner <lock_dir> — echo the owner "<pid> <token>" line (empty if none).
_crosscut_lock_owner() {
  local owner="$1/owner" line=""
  [ -f "$owner" ] || return 0
  read -r line < "$owner" 2>/dev/null || line=""
  printf '%s\n' "$line"
}

# _crosscut_pid_alive <pid> — true iff a non-empty PID names a live process. Uses
# `ps -p` rather than `kill -0`: `kill -0` fails with EPERM for a live process owned
# by another user, misclassifying it as dead; `ps -p` reports existence regardless of
# owner. Safe under `set -euo pipefail` (only ever the tested command of a conditional).
_crosscut_pid_alive() {
  [ -n "${1:-}" ] || return 1
  ps -p "$1" >/dev/null 2>&1
}

# _crosscut_reclaim_stale <lock_dir> — ownership-safe reclaim of a presumed-stale lock via
# capture-by-rename. `mv` (rename(2)) is atomic, so of many racers exactly ONE moves a
# given lock dir aside; every loser's `mv` fails and it never touches a live lock. After
# capturing, the dir is re-validated: if a racer reclaimed it to a LIVE lock between our
# owner read and our `mv`, it is restored intact and the repo is reported busy — we NEVER
# blind-`rm -rf "$lock"`. Returns 0 when the caller should retry (stale captured & removed,
# or the mv was lost to another racer); returns 1 when a LIVE owner was found (busy).
_crosscut_reclaim_stale() {
  local lock="$1" moved owner pid
  moved="$lock.stale.$$.$RANDOM"
  if mv "$lock" "$moved" 2>/dev/null; then
    owner="$(_crosscut_lock_owner "$moved")"
    pid="${owner%% *}"
    if [ -n "$owner" ] && _crosscut_pid_alive "$pid"; then
      # Grabbed a live lock (a racer reclaimed between our read and our mv): restore it.
      mv "$moved" "$lock" 2>/dev/null || rm -rf "$moved" 2>/dev/null || true
      return 1
    fi
    rm -rf "$moved" 2>/dev/null || true
    return 0
  fi
  # Lost the mv race — the stale dir is already gone. Retry.
  return 0
}

# executor_lock_acquire <repo> [token] — acquire the repo's executor lock.
# Generates a unique token when none is given. On success it atomically `mkdir`s the
# lock, writes "<pid> <token>" to owner as promptly as possible (minimizing the
# in-flight window), prints the token, and returns 0.
# Non-zero (busy) is returned, and the existing lock is NEVER reclaimed, when the lock
# is held by a LIVE owner OR is in-flight — its owner file missing/empty because a
# racer just `mkdir`ed it and has not yet published the owner. Only a lock with a
# PRESENT owner whose PID is DEAD is stale; it is reclaimed ownership-safely via
# capture-by-rename (see _crosscut_reclaim_stale — never a blind `rm -rf "$lock"`), then
# `mkdir` is retried. A bounded retry loop absorbs transient contention.
executor_lock_acquire() {
  local repo="${1:-}" token="${2:-}"
  [ -n "$repo" ] || { echo "executor_lock_acquire: repo required" >&2; return 2; }
  [ -n "$token" ] || token="$$-${RANDOM}-$(date +%s)"
  local lock parent
  lock="$(_crosscut_lock_dir "$repo")"
  parent="$(dirname "$lock")"
  mkdir -p "$parent" 2>/dev/null || true

  local attempt owner pid
  for attempt in 1 2 3 4 5; do
    # Fast path: atomic create of a free lock; publish owner promptly.
    if mkdir "$lock" 2>/dev/null; then
      printf '%s %s\n' "$$" "$token" > "$lock/owner"
      printf '%s\n' "$token"
      return 0
    fi

    # Held: inspect the owner.
    owner="$(_crosscut_lock_owner "$lock")"
    if [ -z "$owner" ]; then
      return 1  # in-flight (owner not yet published) — busy, do NOT reclaim
    fi
    pid="${owner%% *}"
    if _crosscut_pid_alive "$pid"; then
      return 1  # busy — a live executor owns it
    fi

    # Present owner, dead PID → stale. Reclaim ownership-safely, then retry mkdir.
    if _crosscut_reclaim_stale "$lock"; then
      continue
    fi
    return 1    # reclaim found a live owner instead — busy
  done
  return 1      # gave up under sustained contention — treat as busy
}

# executor_lock_release <repo> <token> — release the lock IFF its stored token
# matches <token>. Idempotent: a missing lock returns 0. A lock whose stored token
# differs is left intact and the call returns non-zero (refused).
executor_lock_release() {
  local repo="${1:-}" token="${2:-}"
  [ -n "$repo" ] || { echo "executor_lock_release: repo required" >&2; return 2; }
  local lock
  lock="$(_crosscut_lock_dir "$repo")"
  [ -d "$lock" ] || return 0  # nothing to release — idempotent

  local owner stored
  owner="$(_crosscut_lock_owner "$lock")"
  stored="${owner#* }"                    # everything after the first space (the token)
  [ "$owner" = "$stored" ] && stored=""   # no space ⇒ malformed owner ⇒ no token

  if [ -n "$token" ] && [ "$stored" = "$token" ]; then
    rm -rf "$lock" 2>/dev/null || true
    return 0
  fi
  return 1  # token mismatch — never remove another owner's lock
}

# executor_active_for_repo [--print] <repo> — return 0 (busy) iff the lock exists AND
# is either in-flight (owner file missing/empty — a racer just created it and has not
# yet published the owner) OR owned by a LIVE PID; else return non-zero (free). A lock
# with a PRESENT owner whose PID is DEAD is stale: it is reclaimed ownership-safely
# (capture-by-rename, never a blind `rm -rf`) and reported free. Quiet by default;
# --print echoes the owner "<pid> <token>" line when busy.
executor_active_for_repo() {
  local repo="" do_print=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --print) do_print=1; shift;;
      *) repo="$1"; shift;;
    esac
  done
  [ -n "$repo" ] || { echo "executor_active_for_repo: repo required" >&2; return 2; }
  local lock owner pid
  lock="$(_crosscut_lock_dir "$repo")"
  [ -d "$lock" ] || return 1  # free — no lock

  owner="$(_crosscut_lock_owner "$lock")"
  if [ -z "$owner" ]; then
    # In-flight: dir exists but owner not yet published — busy, NOT stale.
    if [ "$do_print" = "1" ]; then printf '%s\n' "$owner"; fi
    return 0
  fi
  pid="${owner%% *}"
  if _crosscut_pid_alive "$pid"; then
    if [ "$do_print" = "1" ]; then printf '%s\n' "$owner"; fi
    return 0  # busy — live owner
  fi
  # Present owner, dead PID → stale. Ownership-safe reclaim; report free.
  if _crosscut_reclaim_stale "$lock"; then
    return 1  # free — reclaimed (or lost the reclaim race)
  fi
  # Reclaim discovered a live owner instead → busy.
  if [ "$do_print" = "1" ]; then _crosscut_lock_owner "$lock"; fi
  return 0
}

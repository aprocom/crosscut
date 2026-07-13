#!/usr/bin/env bash
# reconcile.sh — activation-settle for /crosscut: collapse the whole reconcile pass
# (config + ROADMAP + git + executor run state) into ONE call. It settles every plan's
# status per the truth-priority in SKILL.md § Reconcile, writes the ROADMAP atomically,
# and emits a machine-readable JSON summary the orchestrator only has to relay.
#
# It NEVER takes an irreversible plan action: it does not merge, launch/re-run an executor,
# create or delete a branch/worktree, or move a plan file. The only writes it makes are
# (a) the ROADMAP (atomic temp+rename), (b) reclaiming provably-dead per-repo executor
# locks (via lib/config.sh, capture-by-rename — never a live lock), and (c) event-pruning
# the run records of plans that resolve to `done` (via prune-runs.sh; never on a critical
# path). --dry-run suppresses ALL THREE (a), (b), (c) — it writes nothing and prunes nothing,
# reporting the intended status changes instead.
#
# Boundaries — activation-settle ONLY. Merges (Phase 6), re-running the executor, and any
# other irreversible step stay orchestrator-driven; reconcile only reports what is ready.
#
# The branchy scan/settle logic runs in one embedded python3 block that parses the config a
# SINGLE time for the settle — reconcile exists to REMOVE round-trips, so it never re-spawns a
# YAML parse per field or per repo (the per-repo lock check reuses the resolved runs_dir via a
# shadowed _crosscut_runs_dir). A couple of cheap constant-time resolutions remain in the
# wrapper (runs_dir + the repo list for the lock loop); the retention step shells prune-runs.sh
# (one call per done plan at retention 0, or a single --sweep --preserve-file at retention >0) to
# reuse its path-safety. git reachability is shelled out from python; the stale-lock reclaim
# reuses lib/config.sh's shell helper (no reimplementation).
#
# Exit codes: 0 settled (warnings allowed) · 2 unparseable/invalid config · 3 no config.
# Flags: --dry-run (compute + emit JSON, write nothing, prune nothing).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"

DRYRUN="${EXECUTOR_DRYRUN:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRYRUN=1; shift;;
    -h|--help)
      cat >&2 <<'EOF'
usage: reconcile.sh [--dry-run]
Settles every plan's status from config + ROADMAP + git + run state, writes the ROADMAP
atomically, and prints a JSON summary. --dry-run writes nothing and prunes nothing.
Exit: 0 settled · 2 bad/invalid config · 3 no config.
EOF
      exit 0;;
    *) echo "reconcile: unknown argument: $1" >&2; exit 2;;
  esac
done

# Resolve the config; a missing config is exit 3 (like config-validate) — nothing to settle.
CFG="$(crosscut_config_path)" || { echo "reconcile: no config -- run /crosscut init" >&2; exit 3; }
RUNS_DIR="$(_crosscut_runs_dir)"
# Shadow _crosscut_runs_dir with the already-resolved value so the per-repo lock helpers
# (executor_active_for_repo -> _crosscut_lock_dir -> _crosscut_runs_dir) reuse it instead of
# re-spawning a python+PyYAML config parse per repo — reconcile resolves runs_dir exactly once.
_crosscut_runs_dir() { printf '%s\n' "$RUNS_DIR"; }

# Reclaim stale per-repo executor locks and record which repos are still busy (a LIVE
# owner). executor_active_for_repo reclaims a dead-owner lock in place (capture-by-rename,
# never a blind rm) as a side effect, so a repo whose executor died is freed here for its
# next ready plan. cfg_repo_names is one parse; the per-repo loop is pure shell + fs.
# --dry-run must be side-effect-free ("writes nothing, prunes nothing"), and the reclaim
# IS a write, so it is skipped entirely under --dry-run (BUSY stays empty — repo_busy is
# only computed on a live settle).
BUSY_REPOS=""
if [ "$DRYRUN" != "1" ]; then
  while IFS= read -r _repo; do
    [ -n "$_repo" ] || continue
    if executor_active_for_repo "$_repo"; then
      BUSY_REPOS="${BUSY_REPOS}${_repo}"$'\n'
    fi
  done < <(cfg_repo_names)
fi

CROSSCUT_CFG="$CFG" RECON_RUNS_DIR="$RUNS_DIR" RECON_BUSY="$BUSY_REPOS" \
RECON_DRYRUN="$DRYRUN" RECON_PWD="$PWD" RECON_PRUNE="$SCRIPT_DIR/prune-runs.sh" \
python3 - <<'PY'
import json, os, re, subprocess, sys, tempfile

try:
    import yaml
except ImportError:
    sys.stderr.write("reconcile: PyYAML required (pip install pyyaml)\n")
    sys.exit(2)

CFG_PATH  = os.environ["CROSSCUT_CFG"]
RUNS_DIR  = os.environ.get("RECON_RUNS_DIR", "")
DRYRUN    = os.environ.get("RECON_DRYRUN", "0") == "1"
CWD       = os.environ.get("RECON_PWD", "")
PRUNE     = os.environ.get("RECON_PRUNE", "")
BUSY      = {r for r in os.environ.get("RECON_BUSY", "").splitlines() if r.strip()}

try:
    # utf-8 explicitly so a config with non-ASCII bytes (a path, product name, comment)
    # doesn't crash under a C/POSIX locale (LANG unset in cron/CI) — the one config read to
    # match the run.json/ROADMAP hardening.
    with open(CFG_PATH, encoding="utf-8") as _cf:
        cfg = yaml.safe_load(_cf) or {}
except yaml.YAMLError as e:
    reason = getattr(e, "problem", None) or str(e).splitlines()[0]
    sys.stderr.write("reconcile: config YAML is invalid (%s): %s; run /crosscut validate\n"
                     % (CFG_PATH, reason))
    sys.exit(2)
except (OSError, UnicodeDecodeError) as e:
    sys.stderr.write("reconcile: cannot read config (%s): %s; run /crosscut validate\n"
                     % (CFG_PATH, e))
    sys.exit(2)
if not isinstance(cfg, dict):
    sys.stderr.write("reconcile: config root must be a mapping\n")
    sys.exit(2)

RUN_ID_RE = re.compile(r'^[0-9]{8}T[0-9]{6}-[0-9]+$')
warnings = []
def warn(m): warnings.append(m)

# ---- repos / products (single parse) ------------------------------------------------------
# reconcile may be invoked without config-validate having run first, so coerce every scalar
# it feeds to os.path.* / git to a string — a non-string YAML value (an int path, a list)
# must not raise an uncaught TypeError mid-settle.
def as_str(v, default=""):
    return v if isinstance(v, str) else default

def expand(p): return os.path.expanduser(p) if p else p

repos = {}          # name -> {path, plans_dir, product, kind}
_repos_node = cfg.get("repos")
for r in (_repos_node if isinstance(_repos_node, list) else []):   # a non-list repos: is inert, not a crash
    if not isinstance(r, dict) or not r.get("name"):
        continue
    name = as_str(r.get("name"))
    if not name:
        continue
    repos[name] = {
        "path": expand(as_str(r.get("path"))),
        "plans_dir": as_str(r.get("plans_dir")) or "docs/plans",
        "product": as_str(r.get("product")) or name,
        "kind": as_str(r.get("kind")) or "other",
    }

def product_of(repo_name):
    r = repos.get(repo_name)
    return r["product"] if r else repo_name

# ROADMAP path: <workspace_root>/<roadmap>, ~-expanded, defaults ~/.crosscut/ROADMAP.md.
ws = expand(as_str(cfg.get("workspace_root")) or "~/.crosscut")
roadmap_path = os.path.join(ws, as_str(cfg.get("roadmap")) or "ROADMAP.md")

# ---- git helpers (shelled out; guarded) ---------------------------------------------------
_head_cache = {}
def _repo_dir(repo_name):
    """The repo's path IFF it is an existing directory, else None. Every git helper
    short-circuits on this so a config repo with an empty/missing `path` never shells git
    from reconcile's own CWD."""
    r = repos.get(repo_name)
    p = r["path"] if r else None
    return p if (p and os.path.isdir(p)) else None

def _git(repo_dir, *args):
    """Run a READ-ONLY git command in repo_dir; return the CompletedProcess, or None on
    OSError. `--no-optional-locks` keeps it side-effect-free (no index refresh/lock write);
    utf-8 + errors='replace' so non-ASCII output under a C/POSIX locale never raises."""
    try:
        return subprocess.run(["git", "--no-optional-locks", "-C", repo_dir, *args],
                              capture_output=True, encoding="utf-8", errors="replace")
    except OSError:
        return None

def integration_head(repo_name):
    """The repo's current HEAD sha == the integration branch tip (the executor cuts
    <slug> off HEAD; Phase 6 merges back into it). None if the repo path is unusable."""
    if repo_name in _head_cache:
        return _head_cache[repo_name]
    rd = _repo_dir(repo_name)
    sha = None
    if rd:
        out = _git(rd, "rev-parse", "HEAD")
        if out is not None and out.returncode == 0:
            sha = out.stdout.strip() or None
    _head_cache[repo_name] = sha
    return sha

def is_ancestor(repo_name, sha):
    """True iff <sha> is reachable from the repo's integration HEAD (merged/done signal)."""
    rd = _repo_dir(repo_name)
    if not (rd and sha):
        return False   # unusable repo: no spurious rc-128 warning (repo_ok already warns once)
    out = _git(rd, "merge-base", "--is-ancestor", sha, "HEAD")
    if out is None:
        return False
    if out.returncode == 0:
        return True
    if out.returncode == 1:
        return False
    warn("git merge-base --is-ancestor failed in %s (rc=%d)" % (repo_name, out.returncode))
    return False

def branch_exists(repo_name, slug):
    """True/False for present/absent; None when git couldn't be queried (missing path,
    not a repo, rc 128) — a caller must NOT read None as 'branch absent'."""
    rd = _repo_dir(repo_name)
    if not rd:
        return None
    out = _git(rd, "show-ref", "--verify", "--quiet", "refs/heads/%s" % slug)
    if out is None:
        return None
    if out.returncode == 0:
        return True
    if out.returncode == 1:
        return False
    return None   # rc 128 (not a repo / git error) — unknown, not 'absent'

_clean_cache = {}
def git_clean(repo_name):
    """True iff the integration working tree is clean (`git status --porcelain` empty);
    None when git couldn't be queried. Used to qualify a resume-Phase-6 report. Memoized
    per repo (like integration_head) so N accepted/merging plans in one repo don't re-walk
    its working tree N times."""
    if repo_name in _clean_cache:
        return _clean_cache[repo_name]
    rd = _repo_dir(repo_name)
    result = None
    if rd:
        out = _git(rd, "status", "--porcelain")
        if out is not None and out.returncode == 0:
            result = out.stdout.strip() == ""
    _clean_cache[repo_name] = result
    return result

# ---- run-record scan ----------------------------------------------------------------------
def pid_alive(pid):
    # Mirror lib/config.sh _crosscut_pid_alive: existence regardless of owner.
    if not pid or not str(pid).isdigit():
        return False
    try:
        n = int(pid)
    except ValueError:
        return False
    # pid<=0 is NOT a live process: os.kill(0,...) signals the caller's OWN process group
    # (always "succeeds") and negatives target groups — a corrupt run-id like `...-0` must
    # not read as permanently live. A pid too large for C pid_t raises OverflowError.
    if n <= 0:
        return False
    try:
        os.kill(n, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except (OSError, OverflowError):
        return False

def read_json(path):
    # utf-8 explicitly: a run.json carrying a non-ASCII byte (a plan title / error text)
    # must not be dropped-as-absent under a C/POSIX locale, which would silently lose that
    # run's completed status + head_sha. UnicodeDecodeError is a ValueError subclass, so a
    # truly undecodable file still degrades to None rather than crashing the pass.
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None

def _str_field(src, key):
    """A JSON field's value only if it is a string, else None — so a corrupt run.json
    with a non-string head_sha/status can't flow a non-str into a git subprocess arg or
    the sort key."""
    v = src.get(key) if isinstance(src, dict) else None
    return v if isinstance(v, str) else None

def scan_runs(repo_name, slug, strict=False):
    """Return this plan's runs, recency-ordered NEWEST-FIRST. Each entry:
      {run_id, dir, terminal_status, head_sha, live, sort_key}
    Recency = fixed-width YYYYMMDDTHHMMSS prefix of run_id (the part before -<pid>);
    the -<pid> suffix is NOT fixed-width, so tie-break a same-second pair by dir mtime
    (last write ~= finish/heartbeat time), then started_at. mtime leads the tie-break
    because run-executor's crash/interrupt cleanup writes a terminal run.json WITHOUT a
    started_at — so a newer interrupted run (empty started_at) must not be out-ranked by an
    older completed run just because the older one has a started_at string to sort on."""
    base = os.path.join(RUNS_DIR, repo_name, slug)
    if not os.path.isdir(base):
        return []
    try:
        children = os.listdir(base)
    except OSError:
        # unreadable / removed between isdir and listdir (TOCTOU). In the settle loop a missing
        # tree just means "no runs" (return []); the retention preserve-walk passes strict=True
        # so it can FAIL CLOSED (an incomplete scan must not let the sweep delete an unseen run).
        if strict:
            raise
        return []
    runs = []
    for child in children:
        d = os.path.join(base, child)
        if not os.path.isdir(d) or not RUN_ID_RE.match(child):
            continue   # skip 'worktree' and any non-run sibling
        run_json_path = os.path.join(d, "run.json")
        running_json_path = os.path.join(d, "running.json")
        rj = read_json(run_json_path)
        gj = read_json(running_json_path)
        # Value type-guards, not just container: a corrupt run.json with a non-string
        # head_sha/status must degrade to None, never flow a non-str into a git subprocess
        # arg (TypeError, which _git's `except OSError` would NOT catch) or into the sort key.
        terminal_status = _str_field(rj, "status")
        head_sha = _str_field(rj, "head_sha")
        # live mirrors prune-runs.sh is_live EXACTLY — keyed on FILE EXISTENCE, not parse
        # success: a present running.json, NO run.json sibling, live pid. Using existence (not
        # `gj is not None`) means a present-but-unparseable/mid-write running.json still reads
        # as live, so the "never mark done while a live run exists" invariant can't be dodged by
        # a corrupt running.json (a reused pid can still read as live — the shared model). A
        # run.json sibling forces not-live; recency ordering lets a newer terminal run outrank
        # an older stale-live one.
        pid = child.rsplit("-", 1)[-1]
        live = (os.path.isfile(running_json_path)
                and not os.path.isfile(run_json_path)
                and pid_alive(pid))
        started = None
        for src in (gj, rj):
            v = src.get("started_at") if isinstance(src, dict) else None
            if isinstance(v, str) and v:
                started = v; break   # str-only: a non-str started_at must not poison sort_key
        try:
            mtime = os.stat(d).st_mtime
        except OSError:
            mtime = 0.0
        prefix = child.split("-", 1)[0]   # fixed-width YYYYMMDDTHHMMSS
        runs.append({
            "run_id": child, "dir": d, "terminal_status": terminal_status,
            "head_sha": head_sha, "live": live,
            "sort_key": (prefix, mtime, started or ""),
        })
    runs.sort(key=lambda r: r["sort_key"], reverse=True)
    return runs

# ---- ROADMAP parse ------------------------------------------------------------------------
# Line-oriented so a rewrite touches ONLY changed status cells and preserves every other
# byte (headers, blank lines, prose). A plan row is a table line under a '## Product:'
# section with >= 5 pipe-delimited cells whose header row is 'slug | repo | status | ...'.
SEP_RE = re.compile(r'^\s*\|?\s*:?-{2,}')   # a |---|---| separator row

def split_row(line):
    s = line.strip()
    if not s.startswith("|"):
        return None
    # drop the leading/trailing pipe, split, trim
    inner = s[1:-1] if s.endswith("|") else s[1:]
    return [c.strip() for c in inner.split("|")]

roadmap_lines = []
have_roadmap = os.path.isfile(roadmap_path)
if have_roadmap:
    try:
        # newline="" disables universal-newline translation, so CRLF/LF line endings survive
        # verbatim (each split line keeps its trailing \r) and a rewrite preserves every
        # unchanged row's exact bytes; utf-8 so non-ASCII prose doesn't crash under C/POSIX.
        with open(roadmap_path, encoding="utf-8", newline="") as fh:
            roadmap_lines = fh.read().split("\n")
    except (OSError, UnicodeDecodeError) as e:
        warn("could not read ROADMAP %s: %s" % (roadmap_path, e))
        have_roadmap = False
else:
    warn("ROADMAP not found at %s" % roadmap_path)

# rows: list of dicts {line_idx, cells, status_idx, slug, repo, status, depends_on, feature_id}
# Column indices are taken from each section's HEADER (by name), not hardcoded, so the status
# cell we rewrite is always the right one even if a ROADMAP orders its columns differently.
rows = []
in_table = False
hmap = None      # {column-name: index} for the current section's header
for i, line in enumerate(roadmap_lines):
    if line.startswith("## "):
        in_table = False; hmap = None
        continue
    cells = split_row(line)
    if cells is None:
        continue
    if SEP_RE.match(line):
        continue
    low = [c.lower() for c in cells]
    if hmap is None and "slug" in low and "status" in low:
        hmap = {name: idx for idx, name in enumerate(low)}
        in_table = True
        continue
    if not in_table or hmap is None:
        continue
    si, sl, rp = hmap.get("status"), hmap.get("slug"), hmap.get("repo")
    if si is None or sl is None:
        continue
    need = max(x for x in (si, sl, rp) if x is not None)
    if len(cells) <= need:
        continue
    slug = cells[sl]
    repo = cells[rp] if rp is not None and rp < len(cells) else ""
    status = cells[si]
    if not slug or slug.lower() == "slug":
        continue
    di, fi = hmap.get("depends_on"), hmap.get("feature_id")
    dep_raw = cells[di] if (di is not None and di < len(cells)) else ""
    feat = cells[fi] if (fi is not None and fi < len(cells)) else ""
    deps = [d.strip() for d in re.split(r'[,\s]+', dep_raw) if d.strip() and d.strip() != "-"]
    rows.append({"line_idx": i, "cells": cells, "status_idx": si, "slug": slug, "repo": repo,
                 "status": status, "depends_on": deps, "feature_id": feat})

# ---- settle each row ----------------------------------------------------------------------
# Statuses before acceptance (a completed-but-unmerged branch settles to review_pending).
BEFORE_ACCEPTED = ("draft", "todo", "validated", "running", "review_pending")
# Statuses reconcile may auto-remap from run truth. Excludes accepted/merging/done/rejected/
# superseded (handled by higher-priority rules or terminal) and blocked (a human escalation
# reconcile must not silently clear). run.json/live state outranks a stale ROADMAP status.
REMAPPABLE = ("draft", "todo", "validated", "running", "review_pending", "failed", "stalled")
warned_repos = set()
plans = []
changes = []

for row in rows:
    slug, repo, cur = row["slug"], row["repo"], row["status"]
    runs = scan_runs(repo, slug)
    newest = runs[0] if runs else None
    # The NEWEST completed run decides — never skip to an OLDER completed run. If the newest
    # completed run carries no head_sha (a claude/manual completion), merge is simply not
    # inferred below, rather than falling back to an older run's head and false-`done`ing.
    newest_completed = next((r for r in runs if r["terminal_status"] == "completed"), None)
    newest_completed_head = newest_completed["head_sha"] if newest_completed else None
    in_repo = repo in repos
    repo_ok = (integration_head(repo) is not None) if in_repo else False
    if in_repo and not repo_ok and repo not in warned_repos:
        warn("repo %r unavailable (path missing / not a git repo) -- cannot verify merges "
             "or branches there" % repo)
        warned_repos.add(repo)

    # plan-file location (weak signal). Guard on a REAL repo dir: a config repo with an
    # empty/missing path must never probe <plans_dir>/{completed,rejected}/<slug>.md relative
    # to reconcile's OWN cwd (that would flip a status from an unrelated directory's files).
    loc = None
    rdir = _repo_dir(repo) if in_repo else None
    if rdir:
        pdir = os.path.join(rdir, repos[repo]["plans_dir"])
        if os.path.isfile(os.path.join(pdir, "completed", slug + ".md")):
            loc = "completed"
        elif os.path.isfile(os.path.join(pdir, "rejected", slug + ".md")):
            loc = "rejected"
        # (an active plan file at <plans_dir>/<slug>.md is the norm and no rule keys off it,
        #  so it's left unprobed — only completed/ and rejected/ are settling signals.)

    br = branch_exists(repo, slug) if in_repo else None   # True / False / None(unknown)
    merged = is_ancestor(repo, newest_completed_head) if newest_completed_head else False
    live_now = bool(newest and newest["live"])

    new = cur
    reason = "roadmap"          # what decided the (possibly unchanged) status
    resume_phase6 = False

    # P0a: statuses reconcile NEVER auto-changes — human escalations (`blocked`/`superseded`)
    # and a human-`rejected` plan. Not by a merged head, not by a live run, not by a file
    # location. Only a human moves these on.
    if cur in ("blocked", "superseded", "rejected"):
        new, reason = cur, "human-set status (reconcile leaves it)"
    # P0b: a LIVE newest run = an executor actively working an IN-FLIGHT plan right now — the
    # strongest ground truth for those. It outranks reachability (an older merged head is stale
    # vs active rework) AND keeps retention (which prunes only `done`) from deleting the live
    # run's dir. Scoped to REMAPPABLE so it can't flip a `done`/`accepted`/`merging` plan (P0a
    # already excluded the human-terminal ones) — e.g. a false-live (reused-PID) run must not
    # suppress an accepted plan's resume-Phase-6, nor demote a genuinely `done` plan.
    elif live_now and cur in REMAPPABLE:
        new, reason = "running", "live executor process (newest run)"
    # P1: newest COMPLETED head reachable from integration → done (auto). Only a completed head
    # counts (guarantees head != base); a claude/manual run has none, so a bare branch is never
    # read as merged. `done` short-circuits (no re-flag); human-terminal already caught by P0a.
    # `not live_now`: a live newest run never resolves to done here either — for an
    # accepted/merging plan with a live newest run this defers to P2 (resume Phase 6 /
    # trust-ROADMAP) instead of marking done while an executor is mid-run.
    elif merged and cur != "done" and not live_now:
        new, reason = "done", "merged: completed head reachable from integration"
    # P2: accepted/merging → Phase 6 is owed. Reconcile REPORTS (resume_phase6), never merges,
    # never re-runs the executor, never infers done from bare branch reachability.
    elif cur in ("accepted", "merging"):
        clean = git_clean(repo) if repo_ok else None
        if br is True and clean is True:
            new, reason, resume_phase6 = cur, "resume Phase 6 finalize (branch present, tree clean)", True
        elif br is True:
            new, reason = cur, "accepted/merging; branch present but integration tree not clean / uncheckable (resolve before Phase 6)"
        elif br is False and not merged:
            # branch already deleted, not reachable via a completed head (claude/manual, no
            # head_sha): trust the durable ROADMAP Phase 6 writes before deleting <slug>.
            new, reason = cur, "accepted/merging; branch already deleted (trust ROADMAP)"
        else:
            new, reason = cur, "accepted/merging; branch state unknown (repo uncheckable)"
    # P3: plan file physically in rejected/ → rejected. Guard `cur != "done"`: a stale/misplaced
    # rejected/<slug>.md must NOT downgrade a merged `done` plan from this weak file-location
    # signal (that would drop it from done_by_product and un-`ready` its dependents). `rejected`
    # itself is already caught by P0a; accepted/merging by P2.
    elif loc == "rejected" and cur != "done":
        new, reason = "rejected", "plan file in rejected/"
    # P4: run truth outranks a stale ROADMAP status — settle any in-flight/early row from the
    # newest TERMINAL run (a live newest run was already handled by P0b, so newest is terminal
    # here). Terminal maps by its status.
    elif cur in REMAPPABLE and newest is not None:
        if newest["terminal_status"] == "completed":
            new, reason = "review_pending", "newest run completed, awaiting acceptance"
        elif newest["terminal_status"] == "failed":
            new, reason = "failed", "newest run failed"
        elif newest["terminal_status"] == "interrupted":
            new, reason = "stalled", "newest run interrupted"
        else:
            new, reason = "stalled", "running.json with no live process / no terminal run.json (repair-gate)"
    # P4b: a `running` row with NO run records at all (records wiped, e.g. cache cleared) has
    # no live process behind it → stalled + repair-gate (never left falsely `running`).
    elif cur == "running" and newest is None:
        new, reason = "stalled", "running row with no run records (repair-gate)"
    # P5: weak signal — plan file in completed/, branch unmerged, no run evidence above.
    elif loc == "completed" and br is True and not merged and cur in BEFORE_ACCEPTED:
        new, reason = "review_pending", "completed/, branch unmerged, awaiting acceptance"

    if new != cur:
        changes.append({"slug": slug, "repo": repo, "from": cur, "to": new, "reason": reason})
        row["cells"][row["status_idx"]] = new   # settle ONLY the status cell
        row["changed"] = True

    plans.append({
        "slug": slug, "repo": repo, "product": product_of(repo),
        "status": new, "depends_on": row["depends_on"], "feature_id": row["feature_id"],
        "resume_phase6": resume_phase6, "reason": reason,
        "branch_present": br, "repo_busy": repo in BUSY,
    })

# ---- derived sets -------------------------------------------------------------------------
# ready = todo whose every depends_on resolves to done WITHIN its own product. The product
# boundary forbids cross-product deps, so a done slug in another product must NOT satisfy a
# dep (a global slug set would wrongly mark it ready).
done_by_product = {}
for p in plans:
    if p["status"] == "done":
        done_by_product.setdefault(p["product"], set()).add(p["slug"])
ready, running, blocked, stalled = [], [], [], []
for p in plans:
    prod_done = done_by_product.get(p["product"], set())
    if p["status"] == "todo" and all(d in prod_done for d in p["depends_on"]):
        ready.append({"slug": p["slug"], "repo": p["repo"], "product": p["product"]})
    if p["status"] == "running":
        running.append({"slug": p["slug"], "repo": p["repo"], "product": p["product"]})
    if p["status"] == "blocked":
        blocked.append({"slug": p["slug"], "repo": p["repo"], "product": p["product"]})
    if p["status"] == "stalled":
        stalled.append({"slug": p["slug"], "repo": p["repo"], "product": p["product"]})

# status_counts_by_product: {product: {status: n, ..., "ready": n}}
counts = {}
ready_keys = {(x["slug"], x["repo"]) for x in ready}
for p in plans:
    prod = p["product"]
    c = counts.setdefault(prod, {})
    c[p["status"]] = c.get(p["status"], 0) + 1
    if (p["slug"], p["repo"]) in ready_keys:
        c["ready"] = c.get("ready", 0) + 1

# focus_product: the product of the repo whose path contains $PWD (launched-from-repo).
focus_product = None
if CWD:
    best = None
    for name, r in repos.items():
        rp = r["path"]
        if rp and (CWD == rp or CWD.startswith(rp.rstrip("/") + "/")):
            if best is None or len(rp) > len(best[1]):
                best = (name, rp)
    if best:
        focus_product = product_of(best[0])

# ---- write the ROADMAP atomically (skip on dry-run) --- MUST precede the prune below -------
# The durable `done` write has to land BEFORE any run record is deleted: pruning a plan's
# head_sha and only then writing (or crashing mid-write) would erase the merge signal while
# the ROADMAP still says not-`done` — the next activation could no longer prove the merge.
# So: settle -> write ROADMAP -> prune (mirrors Phase 6's done-before-delete ordering).
def swap_status_cell(raw, status_col, new_status):
    """Return `raw` with ONLY the status token replaced by new_status, preserving every
    other byte incl. the cell's surrounding whitespace. A parsed plan row starts with an
    optional-whitespace leading '|', so segment k+1 of split('|') is table cell k; the
    status cell is therefore segment index status_col+1."""
    segs = raw.split("|")
    si = status_col + 1
    if len(segs) <= si:
        return raw
    seg = segs[si]
    stripped = seg.strip()
    lead = seg[:len(seg) - len(seg.lstrip())]
    trail = seg[len(seg.rstrip()):] if stripped else ""
    segs[si] = lead + new_status + trail
    return "|".join(segs)

roadmap_written = False
if changes and have_roadmap and not DRYRUN:
    for row in rows:
        if row.get("changed"):   # touch ONLY rows whose status actually changed
            roadmap_lines[row["line_idx"]] = swap_status_cell(
                roadmap_lines[row["line_idx"]], row["status_idx"], row["cells"][row["status_idx"]])
    # Atomic + non-crashing: a write/permission/ENOSPC error is reported as a warning (with
    # roadmap_written False) rather than a raw traceback outside the 0/2/3 exit contract. The
    # temp inherits the ORIGINAL file's mode (temp+rename otherwise resets it to 0644-umask,
    # silently dropping e.g. group-write on a shared workspace). newline="" so the joined \n /
    # preserved \r bytes are written verbatim (no platform newline translation).
    tmp = roadmap_path + ".tmp.%d" % os.getpid()
    try:
        try:
            mode = os.stat(roadmap_path).st_mode
        except OSError:
            mode = None
        with open(tmp, "w", encoding="utf-8", newline="") as fh:
            fh.write("\n".join(roadmap_lines))
        if mode is not None:
            try:
                os.chmod(tmp, mode)
            except OSError:
                pass
        os.replace(tmp, roadmap_path)
        roadmap_written = True
    except OSError as e:
        warn("could not write ROADMAP %s: %s" % (roadmap_path, e))
        try:
            if os.path.exists(tmp):
                os.remove(tmp)
        except OSError:
            pass

# ---- retention (AFTER the write; reuse prune-runs.sh for deletion path-safety) --------------
# runs_retention_days governs which run records are reclaimed:
#   0  -> event-prune each `done` plan's records now (the durable `done` is already written).
#   >0 -> status-aware age sweep: age out run records older than N days, but PRESERVE the newest
#         `completed` run of every tree EXCEPT those whose plan reconcile resolved to a terminal
#         status (SWEEP_TERMINAL = done/rejected/superseded); young and live runs are always
#         kept. Preserving by walking ALL run-dir trees (not just parsed ROADMAP rows) keeps an
#         orphan tree's / a parser-skipped plan's head_sha signal. "Which tree is terminal" is
#         reconcile-only knowledge, so reconcile builds the preserve-set and hands it to
#         `prune-runs.sh --sweep --preserve-file`; terminal trees' records age out via the sweep.
#   invalid -> reclaim nothing this pass (see _retention_days).
# GUARD: only reclaim when the ROADMAP is consistent on disk — either written this pass or
# nothing to write. A changed-but-unwritten ROADMAP means a settle we couldn't persist; deleting
# a newly-`done` plan's head_sha while the on-disk status still says not-done would erase the
# merge signal (next activation could not prove it), so skip retention entirely and retry.
def _retention_days():
    """The non-negative int retention, or None if the value is present but INVALID (quoted
    string, float, bool, negative). On invalid, reconcile reclaims NOTHING this pass —
    deleting records on an ambiguous config is the unsafe direction (a quoted "7" the operator
    meant as 7 must not event-prune done records now), and it matches the orchestrator's
    Phase-6 `cfg_get ... 0` reading a non-zero/invalid value as "not 0" and skipping."""
    eo = cfg.get("executor_options")
    if not isinstance(eo, dict) or "runs_retention_days" not in eo:
        return 0   # absent -> documented default 0
    v = eo["runs_retention_days"]
    if v is None:
        return 0   # explicit YAML null (blank value) -> default 0, same as absent
    if isinstance(v, int) and not isinstance(v, bool) and v >= 0:
        return v
    warn("executor_options.runs_retention_days %r is not a non-negative integer -- skipping "
         "retention this pass, deleting nothing (run /crosscut validate)" % (v,))
    return None

# TERMINAL statuses whose newest completed run is NOT preserved by the sweep: `done` (already
# merged) and `rejected`/`superseded` (definitively won't become done, so their head_sha is not
# a pending merge signal). Everything else — including in-flight states and `blocked` (which may
# resume) — has its newest completed run preserved so a later reconcile can still prove a merge.
SWEEP_TERMINAL = ("done", "rejected", "superseded")

prune_results = []
# have_roadmap gate: without ROADMAP status reconcile does not know which trees are terminal,
# so it does not reclaim at all (a settle it couldn't persist likewise skips — roadmap_written
# or no changes).
roadmap_consistent = have_roadmap and (roadmap_written or not changes)
if not DRYRUN and PRUNE and roadmap_consistent:
    retention_days = _retention_days()
    if retention_days is None:
        pass   # invalid retention -> reclaim nothing this pass (safe; warned above)
    elif retention_days == 0:
        # event-prune each done plan's records (prune-runs.sh keeps any live run of that plan).
        for p in plans:
            if p["status"] != "done":
                continue
            if not os.path.isdir(os.path.join(RUNS_DIR, p["repo"], p["slug"])):
                continue
            try:
                out = subprocess.run(["bash", PRUNE, "--repo", p["repo"], "--plan", p["slug"]],
                                     capture_output=True, encoding="utf-8", errors="replace")
                prune_results.append({"mode": "event", "repo": p["repo"], "plan": p["slug"],
                                      "ok": out.returncode == 0,
                                      "detail": (out.stdout or out.stderr).strip()})
                if out.returncode != 0:
                    warn("prune failed for %s/%s: %s" % (p["repo"], p["slug"], out.stderr.strip()))
            except OSError as e:
                warn("prune could not run for %s/%s: %s" % (p["repo"], p["slug"], e))
    else:
        # status-aware sweep. Build the preserve-set by walking EVERY run-dir tree under runs_dir
        # — not just ROADMAP plans — so an orphan tree or a plan whose ROADMAP row the parser
        # skipped still has its newest completed run kept. Only trees reconcile resolved to a
        # SWEEP_TERMINAL status are allowed to age out their newest completed run.
        terminal_trees = {(p["repo"], p["slug"]) for p in plans if p["status"] in SWEEP_TERMINAL}
        preserve = []
        # FAIL CLOSED: the sweep only runs if the preserve-set is PROVABLY COMPLETE. Any listdir/
        # scan error while enumerating trees means a non-terminal plan's newest completed run
        # might be missing from `preserve`; running the (destructive) sweep then could delete that
        # head_sha signal. On any such error, skip the sweep this pass and retry next activation.
        walk_ok = True
        try:
            repo_names = os.listdir(RUNS_DIR) if os.path.isdir(RUNS_DIR) else []
        except OSError as e:
            walk_ok = False
            repo_names = []
            warn("retention: could not list runs_dir %s: %s" % (RUNS_DIR, e))
        for repo_name in repo_names:
            rp = os.path.join(RUNS_DIR, repo_name)
            if not os.path.isdir(rp):
                continue
            try:
                slugs = os.listdir(rp)
            except OSError as e:
                walk_ok = False
                warn("retention: could not list %s: %s" % (rp, e))
                continue
            for slug in slugs:
                if (repo_name, slug) in terminal_trees:
                    continue   # done/rejected/superseded -> newest completed may age out
                if not os.path.isdir(os.path.join(rp, slug)):
                    continue
                try:
                    nc = next((r for r in scan_runs(repo_name, slug, strict=True)
                               if r["terminal_status"] == "completed"), None)
                except OSError as e:
                    walk_ok = False
                    warn("retention: could not scan %s/%s: %s" % (repo_name, slug, e))
                    continue
                if nc:
                    preserve.append(nc["dir"])
        if not walk_ok:
            warn("retention: runs_dir enumeration incomplete -- skipping the sweep this pass "
                 "(retry next activation) rather than risk deleting an unseen run")
        else:
            pf = None
            try:
                fd, pf = tempfile.mkstemp(prefix="crosscut-preserve-")
                # surrogateescape so a run-dir path with a non-UTF-8 byte round-trips instead of
                # raising UnicodeEncodeError; prune-runs.sh reads the file with the same handling.
                with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape") as fh:
                    fh.write("\n".join(preserve) + ("\n" if preserve else ""))
                out = subprocess.run(["bash", PRUNE, "--sweep", "--preserve-file", pf],
                                     capture_output=True, encoding="utf-8", errors="replace")
                prune_results.append({"mode": "sweep", "retention_days": retention_days,
                                      "preserved": len(preserve), "ok": out.returncode == 0,
                                      "detail": (out.stdout or out.stderr).strip()})
                if out.returncode != 0:
                    warn("retention sweep failed: %s" % out.stderr.strip())
            except OSError as e:
                warn("retention sweep could not run: %s" % e)
            finally:
                if pf:
                    try:
                        os.remove(pf)
                    except OSError:
                        pass

# ---- emit -------------------------------------------------------------------------------
result = {
    "roadmap": roadmap_path,
    "roadmap_written": roadmap_written,
    "dry_run": DRYRUN,
    "plans": plans,
    "status_counts_by_product": counts,
    "ready": ready,
    "running": running,
    "blocked": blocked,
    "stalled": stalled,
    "changes_applied": changes,
    "warnings": warnings,
    "focus_product": focus_product,
    "prune_results": prune_results,
}
sys.stdout.write(json.dumps(result, indent=2) + "\n")
PY

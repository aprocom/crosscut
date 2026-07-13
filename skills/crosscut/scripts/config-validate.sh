#!/usr/bin/env bash
# config-validate.sh — human-friendly, whole-file validation of crosscut.config.yaml.
#
# Standalone: parses the file itself (never sources config.sh / calls cfg_get), so a
# malformed config is reported here instead of tracebacking inside a reader. Collects ALL
# problems in one pass and prints a grouped, ASCII-only report. Same allowed-value sets and
# type rules that config-mutate.sh enforces on write, so read- and write-validation agree.
#
# Exit codes: 0 valid (warnings allowed) · 1 validation errors · 2 unparseable YAML
#             · 3 no config file · 4 PyYAML missing.
# Flags: --json (machine form {ok,errors,warnings}) · --quiet (drop the success summary).
set -euo pipefail

JSON=0 QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json)  JSON=1; shift;;
    --quiet) QUIET=1; shift;;
    -h|--help)
      cat >&2 <<'EOF'
usage: config-validate.sh [--json] [--quiet]
Validates ~/.crosscut/crosscut.config.yaml (or $CROSSCUT_CONFIG).
Exit: 0 valid · 1 errors · 2 bad YAML · 3 no config · 4 PyYAML missing.
EOF
      exit 0;;
    *) echo "config-validate: unknown argument: $1" >&2; exit 2;;
  esac
done

# Resolve the target like config.sh, but report the $CROSSCUT_CONFIG path even when it
# does not exist (crosscut_config_path only *uses* it when present).
if [ -n "${CROSSCUT_CONFIG:-}" ]; then
  TARGET="$CROSSCUT_CONFIG"
else
  TARGET="$HOME/.crosscut/crosscut.config.yaml"
fi

CROSSCUT_TARGET="$TARGET" CROSSCUT_JSON="$JSON" CROSSCUT_QUIET="$QUIET" python3 - <<'PY'
import os, sys, json

target = os.environ["CROSSCUT_TARGET"]
as_json = os.environ.get("CROSSCUT_JSON", "0") == "1"
quiet   = os.environ.get("CROSSCUT_QUIET", "0") == "1"

def emit_line(kind, msg, code):
    # kind: "info" | "problem"; single non-report message (no-config / bad-yaml / no-pyyaml)
    if as_json:
        sys.stdout.write(json.dumps({"ok": False, "errors": [msg] if kind == "problem" else [],
                                     "warnings": [], "message": msg}) + "\n")
    else:
        sys.stdout.write("crosscut config: %s\n%s\n" % (target, msg))
    sys.exit(code)

try:
    import yaml
except ImportError:
    emit_line("problem", "PyYAML is required to read the config (pip install pyyaml)", 4)

if not os.path.exists(target):
    emit_line("info", "no config found at %s -- run /crosscut init" % target, 3)

try:
    with open(target) as fh:
        cfg = yaml.safe_load(fh)
except yaml.YAMLError as e:
    where = ""
    mark = getattr(e, "problem_mark", None)
    if mark is not None:
        where = " at line %d, column %d" % (mark.line + 1, mark.column + 1)
    reason = getattr(e, "problem", None) or str(e).splitlines()[0]
    emit_line("problem", "YAML syntax error%s: %s" % (where, reason), 2)

if cfg is None:
    cfg = {}

# ---- collect problems (never stop at the first) ------------------------------------------
errors, warnings = [], []
def err(m):  errors.append(m)
def warn(m): warnings.append(m)

def is_int(v):  return isinstance(v, int) and not isinstance(v, bool)   # bool is an int subclass
def is_bool(v): return isinstance(v, bool)
def is_str(v):  return isinstance(v, str)
def is_map(v):  return isinstance(v, dict)

EXECUTORS = ("ralphex", "claude", "codex")
PLAN_REVIEWS = ("none", "codex", "claude")
FINAL_REVIEWS = ("in-session", "claude", "codex", "none")
EFFORTS = ("inherit", "none", "minimal", "low", "medium", "high", "xhigh", "max")
ALIASES = ("inherit", "opus", "sonnet", "haiku", "fable")
KINDS = ("python", "nodejs", "go", "other")

if not is_map(cfg):
    err("config root must be a YAML mapping (got %s) -- the file should be 'key: value' pairs"
        % type(cfg).__name__)
else:
    # version
    if "version" in cfg and not is_int(cfg["version"]):
        err("version: must be an integer, got %r" % (cfg["version"],))

    # repos
    repos = cfg.get("repos")
    if repos is None:
        warn("repos: none configured -- nothing to drive (run /crosscut init inside a repo)")
    elif not isinstance(repos, list):
        err("repos: must be a list, got %s" % type(repos).__name__)
    else:
        if len(repos) == 0:
            warn("repos: empty -- nothing to drive")
        seen = set()
        for i, r in enumerate(repos):
            if not is_map(r):
                err("repos[%d]: must be a mapping, got %s" % (i, type(r).__name__)); continue
            name = r.get("name")
            has_name = is_str(name) and name.strip()
            if not has_name:
                err("repos[%d]: missing required 'name'" % i)
            else:
                if name in seen:
                    err("repos: duplicate name %r -- each repo name must be unique" % name)
                seen.add(name)
            label = name if has_name else "repos[%d]" % i
            path = r.get("path")
            if path is None or path == "":
                warn("repo %s: no 'path' -- it can't be driven until you add one" % label)
            elif not is_str(path):
                err("repo %s: 'path' must be a string, got %s" % (label, type(path).__name__))
            elif not os.path.exists(os.path.expanduser(path)):
                warn("repo %s: path %r does not exist on this machine (another host?)" % (label, path))
            if "kind" in r and r["kind"] not in KINDS:
                warn("repo %s: kind %r is not one of %s" % (label, r["kind"], "/".join(KINDS)))
            if "venv_isolation" in r and not is_bool(r["venv_isolation"]):
                err("repo %s: venv_isolation must be true or false, got %r" % (label, r["venv_isolation"]))

    # top-level scalars
    executor = cfg.get("executor")
    if executor is not None and executor not in EXECUTORS:
        err("executor: %r is not valid -- use one of: %s" % (executor, ", ".join(EXECUTORS)))
    plan_review = cfg.get("plan_review")
    if plan_review is not None and plan_review not in PLAN_REVIEWS:
        err("plan_review: %r is not valid -- use one of: %s" % (plan_review, ", ".join(PLAN_REVIEWS)))
    final_review = cfg.get("final_review")
    if final_review is not None and final_review not in FINAL_REVIEWS:
        err("final_review: %r is not valid -- use one of: %s" % (final_review, ", ".join(FINAL_REVIEWS)))
    if "max_parallel" in cfg:
        v = cfg["max_parallel"]
        if not is_int(v) or v < 1:
            err("max_parallel: must be a positive integer, got %r" % (v,))

    # git booleans
    git = cfg.get("git")
    if git is not None and not is_map(git):
        err("git: must be a mapping")
    elif is_map(git):
        for k in ("merge_ff", "push_enabled"):
            if k in git and not is_bool(git[k]):
                err("git.%s: must be true or false, got %r" % (k, git[k]))

    # knowledge_base
    kb = cfg.get("knowledge_base")
    if kb is not None and not is_map(kb):
        err("knowledge_base: must be a mapping")

    # executor_options types
    eo = cfg.get("executor_options")
    if eo is not None and not is_map(eo):
        err("executor_options: must be a mapping")
    elif is_map(eo):
        if "runs_retention_days" in eo:
            v = eo["runs_retention_days"]
            if not is_int(v) or v < 0:
                err("executor_options.runs_retention_days: must be a non-negative integer, got %r" % (v,))
        if "runs_dir" in eo:
            v = eo["runs_dir"]
            if not is_str(v) or not v.strip():
                err("executor_options.runs_dir: must be a non-empty path")

    # option maps must be mappings
    for key in ("plan_review_options", "final_review_options"):
        node = cfg.get(key)
        if node is not None and not is_map(node):
            err("%s: must be a mapping" % key)

    # products
    prods = cfg.get("products")
    if prods is not None and not is_map(prods):
        err("products: must be a mapping")
    elif is_map(prods):
        for pn, pv in prods.items():
            if not is_map(pv):
                err("products.%s: must be a mapping" % pn); continue
            if "knowledge_base" in pv and not is_map(pv["knowledge_base"]):
                err("products.%s.knowledge_base: must be a mapping" % pn)

    # per-stage reasoning_effort + model (each opts map only if it IS a mapping)
    for scalar_val, opt_key in ((plan_review, "plan_review_options"),
                                (final_review, "final_review_options"),
                                (executor, "executor_options")):
        opts = cfg.get(opt_key)
        if not is_map(opts):
            continue
        # A stage binds reasoning_effort only when it dispatches to a tool that honors it.
        # The codex EXECUTOR is the exception: its model/effort are NOT wired (they go via
        # executor_options.codex_args), so an invalid effort there is inert -> warning, not error.
        if opt_key == "executor_options":
            active = (scalar_val == "claude")
        else:
            active = scalar_val in ("codex", "claude")
        if "reasoning_effort" in opts:
            v = opts["reasoning_effort"]
            if not (is_str(v) and v in EFFORTS):
                msg = ("%s.reasoning_effort: %r is not valid -- use one of: %s"
                       % (opt_key, v, ", ".join(EFFORTS)))
                (err if active else warn)(msg)
        if "model" in opts and scalar_val == "claude":
            m = opts["model"]
            if not (is_str(m) and m in ALIASES):
                warn("%s.model: %r -- the Agent tool honors only tier aliases (%s); a pinned "
                     "version won't bind on the claude path"
                     % (opt_key, m, "/".join(a for a in ALIASES if a != "inherit")))

# ---- report ------------------------------------------------------------------------------
ok = not errors
if as_json:
    sys.stdout.write(json.dumps({"ok": ok, "errors": errors, "warnings": warnings}) + "\n")
    sys.exit(0 if ok else 1)

out = ["crosscut config: %s" % target]
if errors:
    out.append("config invalid: %d error(s), %d warning(s)" % (len(errors), len(warnings)))
elif warnings:
    out.append("config valid (%d warning(s))" % len(warnings))
else:
    out.append("config valid")

if errors:
    out.append("")
    out.append("ERRORS (must fix):")
    out += ["  - " + m for m in errors]
if warnings:
    out.append("")
    out.append("WARNINGS:")
    out += ["  - " + m for m in warnings]

if ok and not quiet:
    repo_list = cfg.get("repos") if is_map(cfg) else None
    n_repos = len(repo_list) if isinstance(repo_list, list) else 0
    prod = set()
    if isinstance(repo_list, list):
        for r in repo_list:
            if is_map(r) and is_str(r.get("name")):
                prod.add(r.get("product") if is_str(r.get("product")) else r.get("name"))
    out.append("")
    out.append("  %d repo(s), %d product(s), executor=%s, plan_review=%s, final_review=%s"
               % (n_repos, len(prod),
                  (cfg.get("executor") or "ralphex") if is_map(cfg) else "ralphex",
                  (cfg.get("plan_review") or "codex") if is_map(cfg) else "codex",
                  (cfg.get("final_review") or "in-session") if is_map(cfg) else "in-session"))

sys.stdout.write("\n".join(out) + "\n")
sys.exit(0 if ok else 1)
PY

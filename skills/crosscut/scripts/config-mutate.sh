#!/usr/bin/env bash
# config-mutate.sh — deterministic, atomic mutations of crosscut.config.yaml.
# Companion to lib/config.sh (the read side). Resolves the target via
# $CROSSCUT_CONFIG → $HOME/.crosscut/crosscut.config.yaml, creating a
# minimal skeleton if absent, then rewrites the whole file atomically (temp file in the
# same dir + os.replace) so a crash never leaves a partial config. Never source this —
# run it. Uses python3+PyYAML, same as config.sh.
set -euo pipefail

_usage() {
  cat >&2 <<'EOF'
usage: config-mutate.sh add-repo --name <name> [--path <p>] [--kind <k>]
                                 [--product <p>] [--test-cmd <c>] [--lint-cmd <c>]
                                 [--plans-dir <d>] [--venv-isolation true|false]

       config-mutate.sh set-global [--language <s>] [--executor ralphex|claude|codex]
                                   [--plan-review none|codex|claude]
                                   [--final-review in-session|claude|codex|none]
                                   [--merge-ff true|false] [--push-enabled true|false]
                                   [--executor-option KEY=VAL]...
                                   [--plan-review-option KEY=VAL]...
                                   [--final-review-option KEY=VAL]...
                                   [--kb-path <p>] [--kb-mcp <m>]
                                   [--max-parallel <n>]
                                   [--runs-dir <p>] [--runs-retention-days <n>]

       config-mutate.sh set-product <name> [--kb-path <p>] [--kb-mcp <m>]

add-repo merges the repo into repos[] by --name: updates it in place if present
(preserving every other key and every other repo), otherwise appends it. Only the
flags you pass are written; omitted fields keep their existing value on an update.

set-global sets top-level config scalars (language/executor/plan_review/final_review,
and max_parallel — a positive integer capping total concurrent executors, via
--max-parallel) and the git.* booleans (merge_ff/push_enabled, nested under a git:
mapping), plus optional executor_options.* / plan_review_options.* / final_review_options.*
pass-throughs (e.g. model, reasoning_effort) and
the top-level knowledge_base.{path,mcp} (via --kb-path/--kb-mcp). final_review is the
Phase 5b code review (in-session|claude|codex|none). The run-retention
settings executor_options.runs_dir and executor_options.runs_retention_days (a
non-negative integer; 0 = prune a plan's runs once it is done, >0 = keep runs that many
days) are set via --runs-dir / --runs-retention-days. Only the flags you pass are
written; every other key — including repos[] — is preserved.

set-product sets products.<name>.knowledge_base.{path,mcp} (via --kb-path/--kb-mcp);
at least one flag is required. Only the flags you pass are written; existing keys on
that product's knowledge_base, other products, repos[], and the rest of the config are
all preserved. Atomic (temp file + os.replace), like the other subcommands.
EOF
}

# Resolve the mutation target path (unlike config.sh, this may not exist yet).
_target_path() {
  if [ -n "${CROSSCUT_CONFIG:-}" ]; then
    printf '%s\n' "$CROSSCUT_CONFIG"
  else
    printf '%s\n' "$HOME/.crosscut/crosscut.config.yaml"
  fi
}

cmd_add_repo() {
  local -a provided=()
  # Each provided field's value travels to python in an CROSSCUT_F_<field> env var;
  # CROSSCUT_FIELDS names which fields were provided (so "" is distinct from "absent").
  while [ $# -gt 0 ]; do
    local flag="$1"
    case "$flag" in
      --name|--path|--kind|--product|--test-cmd|--lint-cmd|--plans-dir|--venv-isolation) ;;
      *) echo "config-mutate: unknown argument: $flag" >&2; _usage; exit 2;;
    esac
    [ $# -ge 2 ] || { echo "config-mutate: $flag requires a value" >&2; exit 2; }
    local field="${flag#--}"; field="${field//-/_}"   # --test-cmd → test_cmd
    export "CROSSCUT_F_$field=$2"
    provided+=("$field")
    shift 2
  done

  CROSSCUT_TARGET="$(_target_path)" CROSSCUT_FIELDS="${provided[*]:-}" python3 - <<'PY'
import os, sys, tempfile
try:
    import yaml
except ImportError:
    sys.stderr.write("config-mutate: PyYAML required (pip install pyyaml)\n")
    sys.exit(3)

target = os.environ["CROSSCUT_TARGET"]
fields = os.environ.get("CROSSCUT_FIELDS", "").split()
vals = {f: os.environ["CROSSCUT_F_" + f] for f in fields}

# --- validate input (before touching the target so a bad call is a no-op) ---
if not vals.get("name", "").strip():
    sys.stderr.write("config-mutate: add-repo requires a non-empty --name\n")
    sys.exit(2)
if "venv_isolation" in vals:
    v = vals["venv_isolation"].strip().lower()
    if v not in ("true", "false"):
        sys.stderr.write("config-mutate: --venv-isolation must be 'true' or 'false'\n")
        sys.exit(2)
    vals["venv_isolation"] = (v == "true")

# --- load existing config, or start from a minimal skeleton ---
if os.path.exists(target):
    with open(target) as fh:
        cfg = yaml.safe_load(fh) or {}
    if not isinstance(cfg, dict):
        sys.stderr.write("config-mutate: config root is not a YAML mapping: %s\n" % target)
        sys.exit(2)
else:
    cfg = {
        "version": 1,
        "workspace_root": "~/.crosscut",
        "roadmap": "ROADMAP.md",
        "repos": [],
    }

repos = cfg.get("repos")
if repos is None:
    repos = cfg["repos"] = []
if not isinstance(repos, list):
    sys.stderr.write("config-mutate: 'repos' is not a list\n")
    sys.exit(2)

# --- merge by name: update in place, else append ---
name = vals["name"]
ORDER = ["name", "path", "kind", "product", "test_cmd", "lint_cmd",
         "plans_dir", "venv_isolation"]

existing = next((r for r in repos
                 if isinstance(r, dict) and r.get("name") == name), None)
if existing is not None:
    for f in ORDER:
        if f in vals:
            existing[f] = vals[f]          # overwrite only provided fields
else:
    newr = {"name": name}
    for f in ORDER[1:]:
        if f in vals:
            newr[f] = vals[f]
    repos.append(newr)

# --- atomic write: temp file in the same dir, then os.replace over the target ---
d = os.path.dirname(os.path.abspath(target)) or "."
os.makedirs(d, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=d, prefix=".orch-cfg.", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as out:
        yaml.safe_dump(cfg, out, sort_keys=False, default_flow_style=False,
                       allow_unicode=True)
    os.replace(tmp, target)
except BaseException:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
}

cmd_set_global() {
  local -a provided=()
  local -a exec_opts=() review_opts=() final_opts=()
  # Scalar flags travel to python like add-repo (CROSSCUT_F_<field> + CROSSCUT_FIELDS names
  # which were provided). Repeatable KEY=VAL pass-throughs go via numbered env vars.
  while [ $# -gt 0 ]; do
    local flag="$1"
    case "$flag" in
      --language|--executor|--plan-review|--final-review|--merge-ff|--push-enabled|--kb-path|--kb-mcp|--max-parallel|--runs-dir|--runs-retention-days)
        [ $# -ge 2 ] || { echo "config-mutate: $flag requires a value" >&2; exit 2; }
        local field="${flag#--}"; field="${field//-/_}"   # --plan-review → plan_review
        export "CROSSCUT_F_$field=$2"
        provided+=("$field")
        shift 2;;
      --executor-option)
        [ $# -ge 2 ] || { echo "config-mutate: $flag requires a value" >&2; exit 2; }
        exec_opts+=("$2"); shift 2;;
      --plan-review-option)
        [ $# -ge 2 ] || { echo "config-mutate: $flag requires a value" >&2; exit 2; }
        review_opts+=("$2"); shift 2;;
      --final-review-option)
        [ $# -ge 2 ] || { echo "config-mutate: $flag requires a value" >&2; exit 2; }
        final_opts+=("$2"); shift 2;;
      *) echo "config-mutate: unknown argument: $flag" >&2; _usage; exit 2;;
    esac
  done

  local i
  export CROSSCUT_EO_COUNT="${#exec_opts[@]}"
  for ((i = 0; i < ${#exec_opts[@]}; i++)); do export "CROSSCUT_EO_$i=${exec_opts[$i]}"; done
  export CROSSCUT_RO_COUNT="${#review_opts[@]}"
  for ((i = 0; i < ${#review_opts[@]}; i++)); do export "CROSSCUT_RO_$i=${review_opts[$i]}"; done
  export CROSSCUT_FO_COUNT="${#final_opts[@]}"
  for ((i = 0; i < ${#final_opts[@]}; i++)); do export "CROSSCUT_FO_$i=${final_opts[$i]}"; done

  CROSSCUT_TARGET="$(_target_path)" CROSSCUT_FIELDS="${provided[*]:-}" python3 - <<'PY'
import os, sys, tempfile
try:
    import yaml
except ImportError:
    sys.stderr.write("config-mutate: PyYAML required (pip install pyyaml)\n")
    sys.exit(3)

target = os.environ["CROSSCUT_TARGET"]
fields = os.environ.get("CROSSCUT_FIELDS", "").split()
vals = {f: os.environ["CROSSCUT_F_" + f] for f in fields}

def read_opts(prefix):
    out = {}
    n = int(os.environ.get(prefix + "_COUNT", "0"))
    for i in range(n):
        kv = os.environ[prefix + "_" + str(i)]
        if "=" not in kv:
            sys.stderr.write("config-mutate: option must be KEY=VAL: %s\n" % kv)
            sys.exit(2)
        k, v = kv.split("=", 1)
        k = k.strip()
        if not k:
            sys.stderr.write("config-mutate: option KEY must be non-empty: %s\n" % kv)
            sys.exit(2)
        out[k] = v
    return out

exec_opts = read_opts("CROSSCUT_EO")
review_opts = read_opts("CROSSCUT_RO")
final_opts = read_opts("CROSSCUT_FO")

# --- validate input (before touching the target so a bad call is a no-op) ---
if not fields and not exec_opts and not review_opts and not final_opts:
    sys.stderr.write("config-mutate: set-global requires at least one flag\n")
    sys.exit(2)
if "executor" in vals and vals["executor"] not in ("ralphex", "claude", "codex"):
    sys.stderr.write("config-mutate: --executor must be one of: ralphex, claude, codex\n")
    sys.exit(2)
if "plan_review" in vals and vals["plan_review"] not in ("none", "codex", "claude"):
    sys.stderr.write("config-mutate: --plan-review must be one of: none, codex, claude\n")
    sys.exit(2)
if "final_review" in vals and vals["final_review"] not in ("in-session", "claude", "codex", "none"):
    sys.stderr.write("config-mutate: --final-review must be one of: in-session, claude, codex, none\n")
    sys.exit(2)
for bf, flagname in (("merge_ff", "--merge-ff"), ("push_enabled", "--push-enabled")):
    if bf in vals:
        v = vals[bf].strip().lower()
        if v not in ("true", "false"):
            sys.stderr.write("config-mutate: %s must be 'true' or 'false'\n" % flagname)
            sys.exit(2)
        vals[bf] = (v == "true")
if "max_parallel" in vals:
    v = vals["max_parallel"].strip()
    # a positive integer only: reject 0, negatives, and any non-numeric input
    if not v.isdigit() or int(v) < 1:
        sys.stderr.write("config-mutate: --max-parallel must be a positive integer\n")
        sys.exit(2)
    vals["max_parallel"] = int(v)   # write a real YAML int, not a quoted string
if "runs_retention_days" in vals:
    v = vals["runs_retention_days"].strip()
    # a NON-negative integer: 0 is valid (0 = prune on done), unlike --max-parallel.
    # str.isdigit() is false for negatives ('-1') and any non-numeric input.
    if not v.isdigit():
        sys.stderr.write("config-mutate: --runs-retention-days must be a non-negative integer\n")
        sys.exit(2)
    vals["runs_retention_days"] = int(v)   # write a real YAML int, not a quoted string
if "runs_dir" in vals and not vals["runs_dir"].strip():
    sys.stderr.write("config-mutate: --runs-dir must be a non-empty path\n")
    sys.exit(2)

# --- load existing config, or start from a minimal skeleton ---
if os.path.exists(target):
    with open(target) as fh:
        cfg = yaml.safe_load(fh) or {}
    if not isinstance(cfg, dict):
        sys.stderr.write("config-mutate: config root is not a YAML mapping: %s\n" % target)
        sys.exit(2)
else:
    cfg = {
        "version": 1,
        "workspace_root": "~/.crosscut",
        "roadmap": "ROADMAP.md",
        "repos": [],
    }

# --- apply top-level scalars (only the provided ones) ---
for f in ("language", "executor", "plan_review", "final_review", "max_parallel"):
    if f in vals:
        cfg[f] = vals[f]

# --- apply git.* booleans, nested under a git: mapping (created if absent) ---
git_fields = [f for f in ("merge_ff", "push_enabled") if f in vals]
if git_fields:
    git = cfg.get("git")
    if git is None:
        git = cfg["git"] = {}
    if not isinstance(git, dict):
        sys.stderr.write("config-mutate: 'git' is not a YAML mapping\n")
        sys.exit(2)
    for f in git_fields:
        git[f] = vals[f]

# --- apply top-level knowledge_base.{path,mcp}, nested under a knowledge_base: mapping ---
kb_fields = [(f, k) for f, k in (("kb_path", "path"), ("kb_mcp", "mcp")) if f in vals]
if kb_fields:
    kb = cfg.get("knowledge_base")
    if kb is None:
        kb = cfg["knowledge_base"] = {}
    if not isinstance(kb, dict):
        sys.stderr.write("config-mutate: 'knowledge_base' is not a YAML mapping\n")
        sys.exit(2)
    for f, k in kb_fields:
        kb[k] = vals[f]

# --- merge executor_options.* / plan_review_options.* / final_review_options.* pass-throughs ---
def merge_opts(key, opts):
    if not opts:
        return
    node = cfg.get(key)
    if node is None:
        node = cfg[key] = {}
    if not isinstance(node, dict):
        sys.stderr.write("config-mutate: '%s' is not a YAML mapping\n" % key)
        sys.exit(2)
    node.update(opts)

merge_opts("executor_options", exec_opts)
merge_opts("plan_review_options", review_opts)
merge_opts("final_review_options", final_opts)

# --- apply first-class executor_options scalars (runs_dir / runs_retention_days) ---
# Nested like git.*/knowledge_base.*; applied AFTER the --executor-option pass-through so
# a first-class flag wins over a colliding KEY=VAL. A pre-existing non-mapping is an error.
eo_scalars = [f for f in ("runs_dir", "runs_retention_days") if f in vals]
if eo_scalars:
    eo = cfg.get("executor_options")
    if eo is None:
        eo = cfg["executor_options"] = {}
    if not isinstance(eo, dict):
        sys.stderr.write("config-mutate: 'executor_options' is not a YAML mapping\n")
        sys.exit(2)
    for f in eo_scalars:
        eo[f] = vals[f]

# --- atomic write: temp file in the same dir, then os.replace over the target ---
d = os.path.dirname(os.path.abspath(target)) or "."
os.makedirs(d, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=d, prefix=".orch-cfg.", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as out:
        yaml.safe_dump(cfg, out, sort_keys=False, default_flow_style=False,
                       allow_unicode=True)
    os.replace(tmp, target)
except BaseException:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
}

cmd_set_product() {
  local -a provided=()
  local name="" have_name=0
  # First positional arg is the product name (anything not starting with --).
  if [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; then
    name="$1"; have_name=1; shift
  fi
  # Only knowledge_base flags travel to python (CROSSCUT_F_<field> + CROSSCUT_FIELDS names them).
  while [ $# -gt 0 ]; do
    local flag="$1"
    case "$flag" in
      --kb-path|--kb-mcp)
        [ $# -ge 2 ] || { echo "config-mutate: $flag requires a value" >&2; exit 2; }
        local field="${flag#--}"; field="${field//-/_}"   # --kb-path → kb_path
        export "CROSSCUT_F_$field=$2"
        provided+=("$field")
        shift 2;;
      *) echo "config-mutate: unknown argument: $flag" >&2; _usage; exit 2;;
    esac
  done

  CROSSCUT_TARGET="$(_target_path)" CROSSCUT_PRODUCT="$name" CROSSCUT_HAVE_NAME="$have_name" \
    CROSSCUT_FIELDS="${provided[*]:-}" python3 - <<'PY'
import os, sys, tempfile
try:
    import yaml
except ImportError:
    sys.stderr.write("config-mutate: PyYAML required (pip install pyyaml)\n")
    sys.exit(3)

target = os.environ["CROSSCUT_TARGET"]
fields = os.environ.get("CROSSCUT_FIELDS", "").split()
vals = {f: os.environ["CROSSCUT_F_" + f] for f in fields}
name = os.environ.get("CROSSCUT_PRODUCT", "")
have_name = os.environ.get("CROSSCUT_HAVE_NAME", "0") == "1"

# --- validate input (before touching the target so a bad call is a no-op) ---
if not have_name or not name.strip():
    sys.stderr.write("config-mutate: set-product requires a non-empty <name>\n")
    sys.exit(2)
if not fields:
    sys.stderr.write("config-mutate: set-product requires at least one flag "
                     "(--kb-path/--kb-mcp)\n")
    sys.exit(2)

# --- load existing config, or start from a minimal skeleton ---
if os.path.exists(target):
    with open(target) as fh:
        cfg = yaml.safe_load(fh) or {}
    if not isinstance(cfg, dict):
        sys.stderr.write("config-mutate: config root is not a YAML mapping: %s\n" % target)
        sys.exit(2)
else:
    cfg = {
        "version": 1,
        "workspace_root": "~/.crosscut",
        "roadmap": "ROADMAP.md",
        "repos": [],
    }

# --- descend products.<name>.knowledge_base, creating mappings as needed but never
# --- silently overwriting a non-mapping node (that's an error) ---
products = cfg.get("products")
if products is None:
    products = cfg["products"] = {}
if not isinstance(products, dict):
    sys.stderr.write("config-mutate: 'products' is not a YAML mapping\n")
    sys.exit(2)

prod = products.get(name)
if prod is None:
    prod = products[name] = {}
if not isinstance(prod, dict):
    sys.stderr.write("config-mutate: 'products.%s' is not a YAML mapping\n" % name)
    sys.exit(2)

kb = prod.get("knowledge_base")
if kb is None:
    kb = prod["knowledge_base"] = {}
if not isinstance(kb, dict):
    sys.stderr.write("config-mutate: 'products.%s.knowledge_base' is not a YAML mapping\n"
                     % name)
    sys.exit(2)

for f, k in (("kb_path", "path"), ("kb_mcp", "mcp")):
    if f in vals:
        kb[k] = vals[f]          # write only provided flags; preserve the rest

# --- atomic write: temp file in the same dir, then os.replace over the target ---
d = os.path.dirname(os.path.abspath(target)) or "."
os.makedirs(d, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=d, prefix=".orch-cfg.", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as out:
        yaml.safe_dump(cfg, out, sort_keys=False, default_flow_style=False,
                       allow_unicode=True)
    os.replace(tmp, target)
except BaseException:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
}

sub="${1:-}"
[ $# -gt 0 ] && shift || true
case "$sub" in
  add-repo)        cmd_add_repo "$@";;
  set-global)      cmd_set_global "$@";;
  set-product)     cmd_set_product "$@";;
  -h|--help|help)  _usage; exit 0;;
  "")              echo "config-mutate: missing subcommand" >&2; _usage; exit 2;;
  *)               echo "config-mutate: unknown subcommand: $sub" >&2; _usage; exit 2;;
esac

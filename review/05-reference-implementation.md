# 5. Reference implementation of Tier 1, and test results

This is a working implementation of most of Tier 1
([04-proposals.md](04-proposals.md)), written during the review and
exercised end to end in a mock Slurm. It keeps today's topology (a step
hands off to a controller at its end) and today's file layout, so it can
replace `inst/templates/` and the two R functions with no other change to
the package.

**Implemented:**
- P1: run ID, per-run fencing, refusing an accidental second start, `-f` and `-p`, idempotent and retried submission
- P2: array dependency, and the `SLURM*` environment stripped from nested `sbatch` (F28)
- P3: per-task result markers, checked by the next controller
- P4: the bash half, plus the R half in §5.4
- P5: child shell, private `mktemp -d`, SIGTERM trap
- P6: items 2–4
- P7: recorded working directory, `--chdir` for controllers, start-time path check
- P8: journal, log headers, `%j` names, status and stop scripts, step-number validation
- P9: the whole of it

**Not implemented:**
- P6.1 (map offset as a job argument)
- P7's `$SWF__CUR_DIR` paths (an R change)
- P8's hop cap and `-o`
- P10, P11 and P12

**Interface changes**, internal to a workflow directory:

| Script | Before | After |
|---|---|---|
| `controller.sh` | `ROOT STEP [OPTS-STRING]` | `ROOT STEP RUN_ID HOP [OPT …]`, one option per argument |
| `job.sh` | `ROOT STEP` | `ROOT STEP RUN_ID HOP` |
| `start_workflow.sh` | `-s -d -h` | `-s -d -h -f -p -t`, and positional arguments are refused |
| new | | `stop_workflow.sh [-r run]`, `status_workflow.sh`, `SWF/runs/`, `log/events.tsv` |

`change_next_workflow_step()` keeps its environment-variable protocol.
It writes one option per line, which old workflow directories still
word-split correctly, and the new bash still reads the old single-line
format (`swf_read_opts`).

## 5.1 Results: current templates vs reference implementation

Every scenario generates a real workflow with the package's R code, runs
it end to end in the mock Slurm of §5.2, and checks the executed jobs, the
logs and the journal. Both variants run with the `SLURM*` leak of F28
modelled.

| Scenario | Current templates (0.1.0) | Reference implementation |
|---|---|---|
| s1 linear, 3 steps | ✓ 1, 2, 3, done | ✓ same; journal `run-start`, 3× `step-submitted`, `workflow-done` |
| s2 loop (step 2 → 1, twice) | ✓ `1\|2\|1\|2\|1\|2\|3` | ✓ same |
| s3 map, 7 items, `max_array_size = 3` | ✓ slices `0-2`/1, `0-2`/4, `0-0`/7; each item once | ✓ same |
| s4 `start_workflow.sh` twice | ✗ **two chains**: every step runs twice, done ×2 (F1) | ✓ second start refused (exit 1, lists the queued controller); one chain |
| s4f second start with `-f` | ✗ `-f` unknown | ✓ old run's jobs cancelled, `run-superseded` journaled; one chain |
| s4p second start with `-p` (on purpose) | – `-p` unknown. A plain second start gives the same two chains (s4), with nothing to tell them apart | ✓ two runs, each step once per run; every journal line carries its run, and the second `run-start` records `next_to=<first run>`; each run ends `workflow-done` |
| s5 `exit 0` in step 2 | ✗ **chain stops silently**, every rc 0 (F5) | ✓ continues; done |
| s6 `cd /tmp` in step 1 | ✗ step 2 runs in `/tmp`: `cannot open file 'workflows/wf/SWF/steps/2/script.R'` (F6) | ✓ no effect; done |
| s7c array, tasks started in index order | ✓ task MAX inherits the array ID, so whole-array wait | ✓ |
| s7 array, task MAX started first | ✗ **race**: step 2 ran after 1 of 3 tasks; the rest of the workflow finished before tasks 1 and 0 (F2) | ✓ dependency on the array ID, step 2 sees 3 of 3 |
| s8 map slicing + user `change_next_workflow_step(4)` | ✗ step 4 ran **as a 3-task array with the slice's offset**; items 4–7 never processed; ends "All steps are done" (F4) | ✓ the user call errors ("next step was already set"), then `workflow-failed: 2/3 tasks succeeded; task 2 exited with 1` |
| s9 step 2 requeued after its hand-off | ✗ **two chains** from step 2 on, done ×2 (F1) | ✓ second hand-off skipped (`already-submitted key=ctrl.3`); one chain |
| s10 non-last array task fails | ✗ failure ignored, next step runs on partial results (F3) | ✓ `workflow-failed: 2/3 tasks succeeded; task 1 exited with 1` |
| s11 last array task fails | ✗ stops silently (F3) | ✓ hands off anyway, then `workflow-failed … task 2 exited with 1` |
| s12 last task hard-killed (SIGKILL) | ✗ stops silently | ◐ stops; `status_workflow.sh` prints "STOPPED UNEXPECTEDLY". The remaining Tier 1 gap, closed by P12 |
| s12t last task SIGTERM (time limit, `scancel`) | ✗ stops silently | ✓ trap → `task 2 exited with 143` → `workflow-failed` |
| s13 `set -u` in instructions | ✗ `SLURM_ARRAY_TASK_ID: unbound variable`, chain stops (F7) | ✓ no effect |
| s14 next-step option with a space | ✗ `sbatch: error: Unable to open file world`, chain dead (F12) | ✓ one argv element, merged after the `swf:` tag |
| s15 jump to step 99 of 3 | ✗ "All steps are done", a silent false success (F10) | ✓ `workflow-failed: invalid step '99' (the workflow has 3 steps)` |
| s16 bad start arguments | ✗ `-s abc`/`-s 0` submitted; `3` loops forever; bare `-s` silent; sourcing leaves `set -e` in the caller (F14) | ✓ each exits 1 with a message, nothing submitted; caller's flags unchanged |
| s17 `stop_workflow.sh` while step 2 is pending | – (no stop tool) | ✓ job cancelled, `run-stopped` journaled |
| s17p two runs (`-p`), then `stop_workflow.sh -r <first run>` | – (no stop tool) | ✓ only the first run's pending controller cancelled and `run-stopped` journaled for it; the second run completes |
| x3 stop while step 2 is running | – | ✓ the running step finishes, sees `stale-run` and does not hand off |
| s18 hand-off `sbatch` accepted but reports "Socket timed out" | ✗ step marked failed although its successor exists | ✓ tagged job found via `squeue`, no resubmission, one chain |
| s19 non-array step after an array step | ✗ step 3 sees `SLURM_ARRAY_TASK_ID=2`, `TASK_MAX=2`, `TASK_COUNT=3`, `SLURM_MEM_PER_CPU=500` from upstream (F28) | ✓ no leaked array or memory variables; `hop.3: expected=1 task.0.rc=0` |
| s20 `sbatch` warning on stderr | ✓ | ✓ warning logged, kept out of the job ID |
| x1 `-t` preflight | – | ✓ every step checked with `sbatch --test-only` |
| x2 started from the wrong directory | ✗ accepted; fails at the first R step | ✓ refused: `Not found from …/workflows/wf: workflows/wf/SWF/steps/2/script.R` |
| x4 every controller requeued once | ✗ chains double at every hop: "All steps are done" ×16 | ✓ `already-submitted` at every hop; each step runs once; the requeued last controller sees its run has ended |
| x5 `-d <project root>` | ✓ | ✓ |

**Counterfactual for F28:** the reference implementation with plain
`sbatch` instead of `swf__clean_sbatch` fails s19. Step 3 inherits the
array's variables, records `expected=3`, and the run ends with a false
`workflow-failed: 1/3 tasks succeeded`. This is why stripping `SLURM*`
before every nested submission is part of P2/P3 and not an optional
extra.

**Bugs the harness found in the first draft of the reference
implementation (all fixed in the listings below):**
1. `fix_crlf_files` exited 123 under `set -o pipefail` when no file had a
   CR, so **every** start died silently.
2. `sbatch` warnings on stderr were captured into the job ID and broke the
   journal's TSV lines.
3. A user's `--comment` was looked for in the script's *arguments* too,
   so it was merged into the wrong job's tag.
4. A requeued controller journaled its hop twice, and `-f` left no end
   event for the run it replaced.

**Known limits that remain:**
- A hard-killed hand-off task (s12) is detected only by
  `status_workflow.sh`. P12 closes this.
- Runs started with `-p` share `log/events.tsv` and the controller's
  log. Over NFS, two lines appended at the same moment can collide.
- The hand-off retries with 30 s, 60 s, … between attempts. After a
  SIGTERM, the delay drops to 1 s so the retries fit in Slurm's
  `KillWait`.
- Two *simultaneous* executions of the same job could both pass the
  `mkdir` marker before either records a job ID. Slurm never runs two
  instances of one job ID at once, so this would need a bug elsewhere.

## 5.2 The mock Slurm used for these results

About 600 lines: `mockslurm.py`, scenario generators in R, and two shell
drivers. They were written for this review and live in the session's
scratch directory. They are described here so they can be rebuilt as
`tests/runtime/` (proposal "Testing the runtime" in 04).

| Piece | Role |
|---|---|
| `bin/sbatch` → `mockslurm.py sbatch` | Parses command-line options and `#SBATCH` lines (the command line wins; the last `#SBATCH` wins; directives stop at the first command). Supports `--parsable`, `--dependency=afterany:…`, `--array=a-b[%n]`, `--output` with `%x %j %A %a` (with `%a` = 4294967294 outside arrays), `--job-name`, `--export=NONE\|ALL\|VAR=…`, `--chdir`, `--comment`, `--test-only` |
| `bin/squeue`, `bin/scancel` | `-h -u -o` with `%i %j %T %k %A %u`. Cancelled jobs never run and count as finished for `afterany` |
| `bin/run_queue` | Runs runnable jobs one at a time until the queue is empty, with `SLURM_JOB_ID`, `SLURM_ARRAY_*`, `SLURM_RESTART_COUNT`, … set as Slurm sets them |
| array ID rule | Tasks start in a chosen order (`MOCKSLURM_TASK_ORDER=asc\|desc\|maxfirst`). Each gets a new job ID except the last one started, which inherits the array ID, as `job_array_split()` does. `afterany:<array id>` waits for all tasks, `afterany:<task id>` for that task only |
| environment | `NONE` or a list: clean env + login env file + `SLURM*` + listed variables. **Leak model:** the submitter's `SLURM*` variables are copied into every job, and only the variables Slurm sets for that job are overwritten |
| fault injection | `MOCKSLURM_FAIL` (hard kill before the job runs), `MOCKSLURM_TERM` (SIGTERM to the process group, SIGKILL 10 s later), `MOCKSLURM_REQUEUE` (rerun a finished job with `SLURM_RESTART_COUNT=1`), `ambiguous_at` (accept a submission but exit 1 with "Socket timed out"), `sbatch_warn` |
| `gen.R` + `run_scenarios.sh` | One generator per scenario (real `create_workflow()`/`add_workflow_step()`), run against an installed variant of the package; prints the executed (job, step, task, cwd, rc), the trace written by the steps, and the journal |

Running all scenarios takes about 90 s, mostly R start-up. Two
simplifications matter when reading the results. Resources are infinite
and jobs execute one at a time, so real concurrency (two chains writing
at the same instant, NFS visibility delays) is not exercised. The login
environment is a static file, so its failure modes (F8) can't be tested
either. A single-node Slurm in Docker in CI would cover both.

## 5.3 The scripts

Complete files, as tested. The `###SBATCH_OPTIONS###` lines are
the placeholders that R fills in, as today.

### 5.3.1 `inst/templates/workflow/start_workflow.sh` (147 lines)

```bash
#!/bin/bash
# Start a workflow created by the slurmworkflow R package.

# Refuse to be sourced. Checked before anything changes the caller's shell.
if (return 0 2> /dev/null); then
  echo "This file must be executed, not sourced:" 1>&2
  echo "    ./<path to workflow>/start_workflow.sh" 1>&2
  return 1
fi

set -euo pipefail

SWF_ROOT="$(cd "$(dirname "$0")" && pwd -P)"

usage() {
  cat << EOF
$(basename "$0") [-h] [-s n] [-d path] [-f | -p] [-t] -- start a workflow created by slurmworkflow

    -h  show this help text
    -s  first step to run (default: 1)
    -d  working directory of the workflow (default: the current directory)
    -f  start even if jobs of this workflow are already queued: cancel the
        jobs of its previous runs, then start a new run
    -p  start a new run next to the runs already queued, which carry on.
        The runs share this workflow's directory and the project's files
    -t  check every step with 'sbatch --test-only' and exit
EOF
}

FIRST_STEP=1
FORCE=0
PARALLEL=0
TEST_ONLY=0
while getopts ":s:d:fpth" opt; do
  case "$opt" in
    s) FIRST_STEP="$OPTARG" ;;
    d) cd "$OPTARG" ;;
    f) FORCE=1 ;;
    p) PARALLEL=1 ;;
    t) TEST_ONLY=1 ;;
    h) usage; exit 0 ;;
    :) echo "Option -$OPTARG needs a value" 1>&2; usage 1>&2; exit 1 ;;
    *) echo "Unknown option -$OPTARG" 1>&2; usage 1>&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))
if (( $# > 0 )); then
  echo "Unexpected argument(s): $* (did you mean -s $1?)" 1>&2
  usage 1>&2
  exit 1
fi
if (( FORCE && PARALLEL )); then
  echo "-f and -p can't be used together" 1>&2
  exit 1
fi

# source the common bash functions
source "$SWF_ROOT/SWF/lib.sh"
make_env_vars "$SWF_ROOT"
mkdir -p "$SWF_LOG_DIR" "$SWF__RUNS_DIR"

# Convert Windows CRLF endings to LF
fix_crlf_files "$SWF_ROOT"

if ! [[ "$FIRST_STEP" =~ ^[1-9][0-9]*$ ]] || (( FIRST_STEP > SWF__N_STEPS )); then
  echo "-s must be a step number between 1 and $SWF__N_STEPS" 1>&2
  exit 1
fi

# The generated `Rscript "<path>"` lines are relative to the project root
missing=0
while IFS= read -r path; do
  if [[ ! -f "$path" ]]; then
    echo "Not found from $(pwd): $path" 1>&2
    missing=1
  fi
done < <(sed -n 's/^Rscript "\([^"$]*\)".*/\1/p' "$SWF__STEPS_DIR"/*/instructions.sh)
if (( missing )); then
  echo "Run this script from the project root, or use -d <project root>." 1>&2
  exit 1
fi

if (( TEST_ONLY )); then
  status=0
  for (( i = 1; i <= SWF__N_STEPS; i++ )); do
    if out="$(sbatch --test-only "$SWF__STEPS_DIR/$i/job.sh" 2>&1)"; then
      echo "step $i: ok - $out"
    else
      echo "step $i: REJECTED - $out"
      status=1
    fi
  done
  exit "$status"
fi

active="$(swf_active_jobs || true)"
if [[ -n "$active" ]] && (( ! FORCE && ! PARALLEL )); then
  echo "Workflow '$SWF_NAME' already has jobs in the queue:" 1>&2
  echo "$active" 1>&2
  echo "Cancel them first, use -f to cancel them and start a new run," 1>&2
  echo "or -p to start a second run next to them." 1>&2
  exit 1
fi

sbatch_vars="$(compgen -e SBATCH_ || true)"
if [[ -n "$sbatch_vars" ]]; then
  echo "Warning: these variables override the workflow's #SBATCH lines:" $sbatch_vars 1>&2
fi

run_id="$(date '+%Y%m%d-%H%M%S')-$$"
others="$(swf_live_runs)"
if (( PARALLEL )); then
  if [[ -n "$others" ]]; then
    echo "Starting next to run(s)" $others "- the runs share this workflow's files." 1>&2
  fi
else
  # The new run replaces every older one. Fence them first, so that a job
  # of theirs starting meanwhile exits by itself, then cancel their jobs.
  for old in $others; do
    (make_env_run_vars "$old" - && swf_end_run "run-superseded" "by run $run_id") || true
  done
  own="$(swf_own_job_ids || true)"
  if [[ -n "$own" ]]; then
    echo "Cancelling the jobs of the previous run(s):" $own 1>&2
    scancel $own
  fi
fi

mkdir "$SWF__RUNS_DIR/$run_id"
pwd -P > "$SWF__RUNS_DIR/$run_id/workdir"
echo "$run_id" > "$SWF__RUNS_DIR/current.tmp"
mv "$SWF__RUNS_DIR/current.tmp" "$SWF__RUNS_DIR/current"
make_env_run_vars "$run_id" 1

ctrl_id="$(swf_sbatch "ctrl.1" \
  --export=NONE \
  --chdir="$SWF_WORKDIR" \
  --output="$SWF__CTRL_OUT" \
  --job-name="$SWF__CTRL_NAME" \
  "$SWF__CTRL_SCRIPT" "$SWF_ROOT" "$FIRST_STEP" "$SWF_RUN_ID" 1)"

details="first_step=$FIRST_STEP workdir=$SWF_WORKDIR controller=$ctrl_id"
if (( PARALLEL )) && [[ -n "$others" ]]; then
  details+=" next_to=$(echo $others | tr ' ' ',')"
fi
swf_event "run-start" "$details"
echo "Run $SWF_RUN_ID of '$SWF_NAME' started: controller job $ctrl_id"
```

### 5.3.2 `inst/templates/workflow/SWF/lib.sh` (235 lines)

```bash
#!/bin/bash
# Common functions of the slurmworkflow runtime. Always sourced, never executed.

# Paths derived from the workflow root ($1)
function make_env_vars {
  export SWF_ROOT="$1"
  export SWF_NAME="$(basename "$SWF_ROOT")"
  export SWF_SUMMARY="$SWF_ROOT/workflow.yaml"
  export SWF_LOG_DIR="$SWF_ROOT/log"

  # Environment variables for the workflow itself
  export SWF__DIR="$SWF_ROOT/SWF"
  export SWF__RUNS_DIR="$SWF__DIR/runs"
  export SWF__EVENTS="$SWF_LOG_DIR/events.tsv"
  # Related to the controller script
  export SWF__CTRL_SCRIPT="$SWF__DIR/controller.sh"
  export SWF__CTRL_NAME="${SWF_NAME}_controller"
  export SWF__CTRL_OUT="$SWF_LOG_DIR/%x.out"
  # Related to the steps
  export SWF__STEPS_DIR="$SWF__DIR/steps"
  export SWF__STEP_SCRIPT="$SWF__DIR/step.sh"
  export SWF__N_STEPS="$(swf_n_steps)"
}

# Paths of the current step ($1)
function make_env_cur_vars {
  export SWF_CUR="$1"
  export SWF__CUR_DIR="$SWF__STEPS_DIR/$SWF_CUR"
  export SWF__JOB_SCRIPT="$SWF__CUR_DIR/job.sh"
  export SWF__INSTRUCTIONS_SCRIPT="$SWF__CUR_DIR/instructions.sh"
}

# Identity of the run ($1) and position in the chain ($2, the hop number)
function make_env_run_vars {
  export SWF_RUN_ID="$1"
  export SWF__HOP="$2"
  export SWF__RUN_DIR="$SWF__RUNS_DIR/$SWF_RUN_ID"
  export SWF_WORKDIR="$(cat "$SWF__RUN_DIR/workdir" 2>/dev/null)"
}

# Steps are numbered 1..n without gaps
function swf_n_steps {
  local n=0
  while [[ -f "$SWF__STEPS_DIR/$((n + 1))/job.sh" ]]; do n=$((n + 1)); done
  echo "$n"
}

# One line in the job's own log
function swf_log {
  printf '[swf %s] %s %s\n' "$(date '+%F %T')" "$1" "${*:2}"
}

# One line in the job's log and in the workflow journal (log/events.tsv).
# Only called at points where a single job of the run is active, so the
# lines of one run never interleave.
function swf_event {
  local msg="${*:2}"
  msg="${msg//[$'\t\n']/ }"  # one event per line in the journal
  swf_log "$1" "$msg"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date '+%FT%T')" "${SWF_RUN_ID:--}" "${SWF__HOP:--}" "$1" \
    "${SWF_CUR:--}" "${SLURM_JOB_ID:--}" "$(hostname -s 2>/dev/null)" "$msg" \
    >> "$SWF__EVENTS"
}

# Fencing: has this job's run not ended (done, failed, stopped, superseded)?
function swf_run_is_live {
  [[ -n "${SWF_RUN_ID:-}" && -d "$SWF__RUN_DIR" && ! -e "$SWF__RUN_DIR/ended" ]]
}

# End the run with event $1 (details $2). From then on its jobs exit at
# their next check. Only the first end counts: a requeued job, or a stop
# after the end, can't end it again.
function swf_end_run {
  mkdir "$SWF__RUN_DIR/ended" 2> /dev/null || return 0
  echo "$1" > "$SWF__RUN_DIR/ended/event"
  swf_event "$@"
}

# Ids of the runs of this workflow directory that have not ended
function swf_live_runs {
  local d
  for d in "$SWF__RUNS_DIR"/*/; do
    [[ -d "$d" && ! -e "$d/ended" ]] && basename "$d"
  done
  return 0
}

# Queued or running jobs named like this workflow's jobs ("<id> <name> <state> <comment>").
# Another project with a workflow of the same name matches too.
function swf_active_jobs {
  command -v squeue > /dev/null || return 0
  squeue -h -u "$USER" -o '%i %j %T %k' 2> /dev/null |
    awk -v n="$SWF_NAME" '{
      p = n "_step"
      if ($2 == n "_controller" ||
          (index($2, p) == 1 && substr($2, length(p) + 1) ~ /^[0-9]+$/)) print
    }'
}

# Ids of the jobs that certainly belong to this workflow directory: their
# comment "swf:<run id>:<key>" names one of its runs (or run $1 if given)
function swf_own_job_ids {
  local id name state comment run
  while read -r id name state comment; do
    run="${comment#swf:}"
    run="${run%%:*}"
    [[ "$comment" == swf:* && -d "$SWF__RUNS_DIR/$run" ]] &&
      [[ -z "${1:-}" || "$run" == "$1" ]] && echo "$id"
  done < <(swf_active_jobs)
}

# swf_sbatch KEY [sbatch args...]
# Submit at most once per KEY and run: a requeued job that already submitted
# its successor does not submit it again. Retries transient failures, and
# before retrying checks whether the "failed" submission went through anyway.
# The job's --comment starts with the tag "swf:<run>:<key>" (a user comment
# is appended after it). Prints the job id.
function swf_sbatch {
  local key="$1"; shift
  local marker="$SWF__RUN_DIR/submit.$key"
  local tag="swf:$SWF_RUN_ID:$key"
  local out attempt arg in_opts=1 args=()
  for arg in "$@"; do
    # only sbatch's own options: the script and its arguments come unchanged
    if (( in_opts )) && [[ "$arg" == --comment=* ]]; then
      tag+=" ${arg#--comment=}"
    else
      [[ "$arg" == -* ]] || in_opts=0
      args+=("$arg")
    fi
  done
  set -- "${args[@]}"

  if ! mkdir "$marker" 2> /dev/null; then
    # Submitted before, by an earlier execution of this same job (requeue)
    if [[ -s "$marker/jobid" ]] || swf__find_tagged "$tag" "$marker"; then
      swf_log "already-submitted" "key=$key job=$(cat "$marker/jobid")" >&2
      cat "$marker/jobid"
      return 0
    fi
  fi
  for attempt in 1 2 3 4 5; do
    # stdout is only the job id with --parsable; warnings go to stderr
    if out="$(swf__clean_sbatch --parsable --comment="$tag" "$@" 2> "$marker/stderr")"; then
      [[ -s "$marker/stderr" ]] &&
        swf_log "sbatch-warning" "key=$key: $(tr '\n' ' ' < "$marker/stderr")" >&2
      echo "${out%%;*}" > "$marker/jobid"
      cat "$marker/jobid"
      return 0
    fi
    swf_log "sbatch-failed" "key=$key attempt=$attempt: $(tr '\n' ' ' < "$marker/stderr")" >&2
    sleep "$((attempt * ${SWF__RETRY_DELAY:-30}))"
    # A timed out submission may have gone through anyway
    if swf__find_tagged "$tag" "$marker"; then
      cat "$marker/jobid"
      return 0
    fi
  done
  return 1
}

# sbatch copies every SLURM* variable of its own environment into the job it
# submits, even with --export=NONE, and Slurm only overwrites the ones that
# apply to the new job. Without this, a controller submitted by an array task
# carries that task's SLURM_ARRAY_* values, and passes them on to every later
# step (and the controller's SLURM_MEM_PER_CPU to steps that use --mem).
function swf__clean_sbatch {
  local v unset_args=()
  for v in $(compgen -e); do
    [[ "$v" == SLURM* && "$v" != SLURM_CONF ]] && unset_args+=(-u "$v")
  done
  env "${unset_args[@]}" sbatch "$@"
}

# Look for a queued job whose comment starts with the tag in $1 (first word),
# record its id in $2/jobid
function swf__find_tagged {
  local found
  found="$(squeue -h -u "$USER" -o '%i %k' 2> /dev/null |
             awk -v t="${1%% *}" '$2 == t { print $1; exit }')"
  [[ -n "$found" ]] && echo "$found" > "$2/jobid"
}

# Read sbatch options written by `change_next_workflow_step()`, one per line,
# into the array SWF__OPTS. Older versions wrote them space-separated on one
# line, which is still accepted.
function swf_read_opts {
  local line words
  SWF__OPTS=()
  [[ -f "$1" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    if [[ "$line" == --*" --"* ]]; then
      read -r -a words <<< "$line"
      SWF__OPTS+=("${words[@]}")
    else
      SWF__OPTS+=("$line")
    fi
  done < "$1"
}

# Did every task of the step submitted at hop $1 finish with status 0?
# Sets SWF__CHECK_MSG.
function swf_check_tasks {
  local dir="$SWF__RUN_DIR/hop.$1" expected n_ok=0 f rc
  SWF__CHECK_MSG=""
  if [[ ! -f "$dir/expected" ]]; then
    SWF__CHECK_MSG="no task reported a result (killed before its end?)"
    return 1
  fi
  expected="$(cat "$dir/expected")"
  for f in "$dir"/task.*.rc; do
    [[ -e "$f" ]] || continue
    rc="$(cat "$f")"
    if [[ "$rc" == 0 ]]; then
      n_ok=$((n_ok + 1))
    else
      f="${f##*/task.}"
      SWF__CHECK_MSG+=" task ${f%.rc} exited with $rc;"
    fi
  done
  if (( n_ok != expected )); then
    SWF__CHECK_MSG="$n_ok/$expected tasks succeeded;$SWF__CHECK_MSG"
    return 1
  fi
}

# Convert CRLF to LF in the scripts R may have written on Windows.
function fix_crlf_files {
  find "$1/start_workflow.sh" "$1/SWF" -path "$1/SWF/runs" -prune -o \
       -type f \( -name '*.sh' -o -name '*.R' \) -print0 2> /dev/null |
    xargs -0 -r grep -lZ $'\r' 2> /dev/null |
    xargs -0 -r sed -i 's/\r$//' || true  # grep finds nothing: status 123
}
```

### 5.3.3 `inst/templates/workflow/SWF/controller.sh` (72 lines)

```bash
#!/bin/bash

# Mandatory Options
#SBATCH --open-mode=append
#SBATCH --time=10
#SBATCH --nodes=1
#SBATCH --cpus-per-task=1
#SBATCH --mem-per-cpu=500
#SBATCH --export=NONE

###SBATCH_OPTIONS###


# arguments: root, step to submit, run id, hop number, then sbatch options
SWF_ROOT="$1"
SWF_CUR="$2"
SWF_RUN_ID="$3"
SWF__HOP="$4"
shift 4 || exit 1
SWF__OPTS=("$@")

source "$SWF_ROOT/SWF/lib.sh" || exit 1
make_env_vars "$SWF_ROOT"
make_env_run_vars "$SWF_RUN_ID" "$SWF__HOP"
make_env_cur_vars "$SWF_CUR"

swf_log "controller" "run=$SWF_RUN_ID hop=$SWF__HOP step=$SWF_CUR job=$SLURM_JOB_ID restart=${SLURM_RESTART_COUNT:-0}"

if ! swf_run_is_live; then
  swf_log "stale-run" "run $SWF_RUN_ID has ended ($(cat "$SWF__RUN_DIR/ended/event" 2> /dev/null)), exiting"
  exit 0
fi

# Outcome of the previous step: stop loudly if any task failed or vanished
if (( SWF__HOP > 1 )) && ! swf_check_tasks "$((SWF__HOP - 1))"; then
  swf_end_run "workflow-failed" "previous step failed:$SWF__CHECK_MSG"
  exit 1
fi

if ! [[ "$SWF_CUR" =~ ^[1-9][0-9]*$ ]] || (( SWF_CUR > SWF__N_STEPS + 1 )); then
  swf_end_run "workflow-failed" "invalid step '$SWF_CUR' (the workflow has $SWF__N_STEPS steps)"
  exit 1
fi

if (( SWF_CUR == SWF__N_STEPS + 1 )); then
  swf_end_run "workflow-done" ""
  echo "All steps are done"
  exit 0
fi

# Array steps get one log per task, other steps one log per job
if grep -q '^#SBATCH --array' "$SWF__JOB_SCRIPT" ||
   [[ " ${SWF__OPTS[*]} " == *" --array"* ]]; then
  out="$SWF_LOG_DIR/%x_%A_%a.out"
else
  out="$SWF_LOG_DIR/%x_%j.out"
fi

event="step-submitted"
[[ -s "$SWF__RUN_DIR/submit.step.$SWF__HOP/jobid" ]] && event="already-submitted"
if ! step_id="$(swf_sbatch "step.$SWF__HOP" \
       --dependency=afterany:"$SLURM_JOB_ID" \
       --output="$out" \
       --job-name="${SWF_NAME}_step${SWF_CUR}" \
       "${SWF__OPTS[@]}" \
       "$SWF__JOB_SCRIPT" "$SWF_ROOT" "$SWF_CUR" "$SWF_RUN_ID" "$SWF__HOP")"; then
  swf_end_run "workflow-failed" "could not submit step $SWF_CUR"
  exit 1
fi

swf_event "$event" "job=$step_id opts=${SWF__OPTS[*]}"
echo "Step number $SWF_CUR has been submitted (job $step_id)"
```

### 5.3.4 `inst/templates/workflow/SWF/step.sh` (82 lines)

```bash
# Common body of every step, sourced by steps/<N>/job.sh after lib.sh.
#
# The user's instructions run in a child bash, so that `exit`, `cd`, `set -u`
# or variables defined there cannot change what this script does afterwards.
# Errors are checked explicitly here.
set +e

swf_log "step-start" "run=$SWF_RUN_ID hop=$SWF__HOP step=$SWF_CUR job=$SLURM_JOB_ID" \
  "array=${SLURM_ARRAY_JOB_ID:--}_${SLURM_ARRAY_TASK_ID:--} host=$(hostname -s)" \
  "restart=${SLURM_RESTART_COUNT:-0} cwd=$PWD"

if ! swf_run_is_live; then
  swf_log "stale-run" "run $SWF_RUN_ID has ended ($(cat "$SWF__RUN_DIR/ended/event" 2> /dev/null)), not running step $SWF_CUR"
  exit 0
fi

# Per task temporary directory for the next step files
export SWF_CUR_TMP="${SLURM_TMPDIR:-${TMPDIR:-${TMP:-/tmp}}}"
SWF__TASK_TMP="$(mktemp -d "$SWF_CUR_TMP/swf.XXXXXX")" || exit 1
trap 'rm -rf "$SWF__TASK_TMP"' EXIT
export SWF_NEXTSTEP_FILE="$SWF__TASK_TMP/nextstep"
export SWF_NEXTSTEP_OPTS_FILE="$SWF__TASK_TMP/nextstep_opts"

# On time limit or scancel Slurm sends SIGTERM to every process of the job.
# The child dies, this shell carries on and reports the failure. SIGKILL
# follows after KillWait (30 s by default): retry the hand-off quickly.
trap 'SWF__RETRY_DELAY=1; swf_log "signal" "SIGTERM received"' TERM

bash -e "$SWF__INSTRUCTIONS_SCRIPT"
SWF__RC=$?

# Result of this task, checked by the next controller
SWF__TASK_DIR="$SWF__RUN_DIR/hop.$SWF__HOP"
mkdir -p "$SWF__TASK_DIR"
echo "${SLURM_ARRAY_TASK_COUNT:-1}" > "$SWF__TASK_DIR/expected"

# Only one task hands over to the next controller: the highest index of an
# array, or the job itself
if [[ -n "${SLURM_ARRAY_TASK_ID:-}" &&
      "$SLURM_ARRAY_TASK_ID" != "${SLURM_ARRAY_TASK_MAX:-}" ]]; then
  if [[ -f "$SWF_NEXTSTEP_FILE" ]]; then
    swf_log "warning" "change_next_workflow_step() ignored: only the last array task decides"
  fi
  echo "$SWF__RC" > "$SWF__TASK_DIR/task.$SLURM_ARRAY_TASK_ID.rc"
  swf_log "step-end" "rc=$SWF__RC"
  exit "$SWF__RC"
fi

SWF__NEXT=$((SWF_CUR + 1))
SWF__OPTS=()
if (( SWF__RC == 0 )) && [[ -f "$SWF_NEXTSTEP_FILE" ]]; then
  SWF__NEXT="$(cat "$SWF_NEXTSTEP_FILE")"
  if [[ "$SWF__NEXT" =~ ^[1-9][0-9]*$ ]]; then
    swf_read_opts "$SWF_NEXTSTEP_OPTS_FILE"
  else
    swf_log "error" "malformed SWF_NEXTSTEP_FILE content: '$SWF__NEXT'"
    SWF__RC=1
  fi
fi
echo "$SWF__RC" > "$SWF__TASK_DIR/task.${SLURM_ARRAY_TASK_ID:-0}.rc"
swf_log "step-end" "rc=$SWF__RC next=$SWF__NEXT"

if ! swf_run_is_live; then
  swf_log "stale-run" "run $SWF_RUN_ID has ended ($(cat "$SWF__RUN_DIR/ended/event" 2> /dev/null)), not continuing"
  exit "$SWF__RC"
fi

# Hand over even after a failure: the controller checks the result of every
# task and stops the workflow with an explicit message.
# `afterany` on the array id waits for every task of an array.
if ! swf_sbatch "ctrl.$((SWF__HOP + 1))" \
       --dependency=afterany:"${SLURM_ARRAY_JOB_ID:-$SLURM_JOB_ID}" \
       --export=NONE \
       --chdir="$SWF_WORKDIR" \
       --output="$SWF__CTRL_OUT" \
       --job-name="$SWF__CTRL_NAME" \
       "$SWF__CTRL_SCRIPT" "$SWF_ROOT" "$SWF__NEXT" "$SWF_RUN_ID" \
       "$((SWF__HOP + 1))" "${SWF__OPTS[@]}" > /dev/null; then
  swf_end_run "workflow-failed" "could not submit the controller for step $SWF__NEXT"
  exit 1
fi
exit "$SWF__RC"
```

### 5.3.5 `inst/templates/step_dir/job.sh` (18 lines)

```bash
#!/bin/bash

# Mandatory Options
#SBATCH --export=NONE
#SBATCH --open-mode=append

###SBATCH_OPTIONS###

# srun inside this job inherits the job's environment, not --export=NONE
export SLURM_EXPORT_ENV=ALL

# arguments: root, step number, run id, hop number
source "$1/SWF/lib.sh" || exit 1
make_env_vars "$1"
make_env_cur_vars "$2"
make_env_run_vars "$3" "$4"

source "$SWF__STEP_SCRIPT"
```

### 5.3.6 `inst/templates/workflow/stop_workflow.sh` (34 lines)

```bash
#!/bin/bash
# Stop the runs of a workflow created by slurmworkflow: every run that has
# not ended, or only the one given with -r.
set -euo pipefail

SWF_ROOT="$(cd "$(dirname "$0")" && pwd -P)"
source "$SWF_ROOT/SWF/lib.sh"
make_env_vars "$SWF_ROOT"

only=""
while getopts ":r:" opt; do
  case "$opt" in
    r) only="$OPTARG" ;;
    *) echo "Usage: $(basename "$0") [-r run id]" 1>&2; exit 1 ;;
  esac
done

runs="$(swf_live_runs)"
if [[ -n "$only" ]]; then
  runs="$(grep -Fx -- "$only" <<< "$runs" || true)"
fi
if [[ -z "$runs" ]]; then
  echo "No run of '$SWF_NAME' is active${only:+ with id $only}."
fi
# Fence first: a job that is starting right now sees its run has ended and exits
for run in $runs; do
  (make_env_run_vars "$run" - && swf_end_run "run-stopped" "by $USER")
done

ids="$(swf_own_job_ids "$only" || true)"
if [[ -n "$ids" ]]; then
  echo "Cancelling:" $ids
  scancel $ids
fi
```

### 5.3.7 `inst/templates/workflow/status_workflow.sh` (37 lines)

```bash
#!/bin/bash
# Show where the runs of a workflow created by slurmworkflow are.
set -euo pipefail

SWF_ROOT="$(cd "$(dirname "$0")" && pwd -P)"
source "$SWF_ROOT/SWF/lib.sh"
make_env_vars "$SWF_ROOT"

echo "workflow: $SWF_NAME ($SWF__N_STEPS steps)"
# The runs that have not ended, or else the last one started
runs="$(swf_live_runs)"
if [[ -z "$runs" ]]; then
  runs="$(cat "$SWF__RUNS_DIR/current" 2> /dev/null || true)"
fi
for run in $runs; do
  echo
  if [[ -e "$SWF__RUNS_DIR/$run/ended" ]]; then
    echo "run $run: ended ($(cat "$SWF__RUNS_DIR/$run/ended/event" 2> /dev/null))"
  elif [[ -n "$(swf_own_job_ids "$run" || true)" ]]; then
    echo "run $run: active"
  else
    echo "run $run: nothing in the queue and no end event: the run STOPPED UNEXPECTEDLY"
    echo "  (job killed before its hand-off?). See the last step's log."
  fi
  if [[ -f "$SWF__EVENTS" ]]; then
    awk -F '\t' -v r="$run" '$2 == r' "$SWF__EVENTS" | tail -n 8 |
      awk -F '\t' '{ printf "  %s  hop %-4s %-16s step %-3s job %-10s %s\n", $1, $3, $4, $5, $6, $8 }'
  fi
done
echo
queued="$(swf_active_jobs || true)"
if [[ -n "$queued" ]]; then
  echo "in the queue:"
  echo "$queued" | sed 's/^/  /'
else
  echo "nothing in the queue"
fi
```

## 5.4 The R side

`R/workflow.R`, replacing `change_next_workflow_step()`:

```r
change_next_workflow_step <- function(next_step, sbatch_opts = NULL,
                                      overwrite = FALSE) {
  next_step_file <- Sys.getenv("SWF_NEXTSTEP_FILE")
  next_step_opts_file <- Sys.getenv("SWF_NEXTSTEP_OPTS_FILE")
  if (next_step_file == "") {
    stop(
      "The environment variable 'SWF_NEXTSTEP_FILE' is empty.\n",
      "Make sure you are in running workflow"
    )
  }

  next_step <- suppressWarnings(as.integer(next_step))
  if (length(next_step) != 1 || is.na(next_step) || next_step < 1) {
    stop("`next_step` must be a single positive integer")
  }

  task_id <- Sys.getenv("SLURM_ARRAY_TASK_ID")
  if (task_id != "" && task_id != Sys.getenv("SLURM_ARRAY_TASK_MAX")) {
    warning(
      "Only the highest index task of an array sets the next step.\n",
      "This call has no effect."
    )
  }

  if (fs::file_exists(next_step_file) && !overwrite) {
    stop(
      "The next step was already set in this job (to ",
      readLines(next_step_file), ").\n",
      "Two pieces of code are choosing the next step (e.g. `step_tmpl_map` ",
      "slicing and the mapped function).\n",
      "Use `overwrite = TRUE` if this is intended."
    )
  }

  # Both files are replaced together: options never outlive their decision
  unlink(c(next_step_file, next_step_opts_file))
  if (!is.null(sbatch_opts)) {
    writeLines(make_sbatch_opt_lines(sbatch_opts), next_step_opts_file)
  }

  writeLines(as.character(next_step), next_step_file)
  message("The next workflow step was changed to ", next_step)
  invisible(next_step)
}
```

`R/sbatch_options.R`, new helper used above:

```r
make_sbatch_opt_lines <- function(sbatch_opts) {
  unname(mapply(
    function(opt, val) paste0("--", opt, "=", val),
    names(sbatch_opts), sbatch_opts
  ))
}
```

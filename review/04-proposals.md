# 4. Proposed corrections

The proposals come in three tiers:

- **Now** (no code change): operational advice for current users.
- **Tier 1** (P1–P11): hardening that keeps today's topology (the step
  hands off to a controller at its end). Each item is small and can be
  merged on its own. Together they close every High finding
  except the "job killed outright" case of F9.
- **Tier 2** (P12): one structural change. The controller is queued
  *before* the step runs, so the chain survives the step being killed and
  failure handling stops depending on the step reaching its last line.

A working, tested implementation of Tier 1 is in
[05-reference-implementation.md](05-reference-implementation.md).

| P | Fixes | Change | Effort | Priority |
|---|---|---|---|---|
| [P1](#p1) | F1, F10, F13 | run ID, fencing, no accidental second run (`-f` replaces, `-p` runs alongside), idempotent retried `sbatch` | M | **P0** |
| [P2](#p2) | F2, F28 | depend on `SLURM_ARRAY_JOB_ID`; stop `SLURM_*` leaking into submitted jobs | XS | **P0** |
| [P3](#p3) | F3, F9 | per-task result markers, checked by the next controller | S | **P0** |
| [P4](#p4) | F4, F12 | next-step protocol: one option per line, both files replaced together, conflicts refused | S | **P0** |
| [P5](#p5) | F5, F6, F7, F24 | run instructions in a child `bash -e`; per-task `mktemp -d`; SIGTERM trap | S | **P0** |
| [P6](#p6) | F8 | keep `--export=NONE` everywhere; `SLURM_EXPORT_ENV=ALL`; warn on `SBATCH_*` | S | P1 |
| [P7](#p7) | F17 | `$SWF__CUR_DIR` paths, recorded working directory, `--chdir`, start-time path check | S | P1 |
| [P8](#p8) | F9, F10, F11, F19, F20 | journal, log headers, `%j` names, `status`/`stop` scripts, hop cap, `-o` | M | P1 |
| [P9](#p9) | F14, F21, F25, F16 | `start_workflow.sh` rewrite: guard, `getopts`, validation, scoped CRLF fix, `--test-only` preflight | S | **P0** |
| [P10](#p10) | F15 | configurable controller options, mail on failure | S | P1 |
| [P11](#p11) | F21, F22, F23, F26, F27 | R side: LF output, functions by name and version check, template hygiene, option deny-list, no scientific notation | M | P2 |
| [P12](#p12) | F9, F11, F18, F3 | pre-submitted controller; slicing and failure policy move into the controller | L | P2 |

---

## Now: operational advice before any code change

1. **`merck_calib2`:** treat its calibration history and merged outputs
   as suspect (see [02 §2.2](02-log-analysis.md#22-finding-l1-the-whole-workflow-ran-twice-at-the-same-time-on-the-same-state)).
   Re-run it with one chain, or check that the merged tibble comes from a
   single consistent set of batches.
2. **Before every start**, check nothing is queued:
   `squeue -u $USER -o '%i %j %T' | grep -E '<wf>_(controller|step[0-9]+)'`.
   To stop a run, cancel *both* the pending controller and the step.
   **To run two at once on purpose,** give each run its own workflow
   directory (another name in `create_workflow()`) and its own swfcalib
   directory, so that they share no files. Two chains on one swfcalib
   state interfere ([02 §2.2](02-log-analysis.md#22-finding-l1-the-whole-workflow-ran-twice-at-the-same-time-on-the-same-state)).
   If the aim is more simulations in flight, one run with more batches per
   wave keeps as many tasks running, without two chains writing to one
   state.
3. In step instructions, **never use `exit 0` or `cd`**. Use `return 0`
   (allowed at the top level of a sourced file) or a subshell:
   `( cd data && make )`.
4. Give every step `mail-type=FAIL`, and the last step `END`, as the
   vignette does. It is the only failure signal today.
5. Set `max_array_size` explicitly (≤ the site's `MaxArraySize - 1`; Slurm's
   default is 1000).
6. For array steps whose results feed the next step, check in the next
   step that every expected output exists (F3).
7. **Shared nodes (F24, security):** if your cluster runs several users'
   jobs on one node without a private per-job `/tmp`, patch `SWF/step.sh`
   of each workflow before running it. Each workflow directory has its
   own copy, so this works without a package release. Apply the
   `mktemp -d` part of [P5](#p5) and the three-line [P2](#p2), at least
   for workflows that call `change_next_workflow_step()` (all swfcalib
   workflows do).
8. Write large memory values as strings (`mem = "100G"`, not
   `mem = 100000`), which avoids F27's `1e+05`.

---

## Tier 1: hardening within the current topology

<a id="p1"></a>
### P1: Run identity, fencing, explicit second runs, idempotent submissions (F1, F10, F13)

**State.** A new directory `SWF/runs/`:

```
SWF/runs/
├── current                  id of the last run started (for status_workflow.sh)
└── <run id>/                e.g. 20261029-161905-12345
    ├── workdir              working directory recorded at start
    ├── submit.ctrl.<h>/jobid    one marker per submission (h = hop number)
    ├── submit.step.<h>/jobid
    ├── hop.<h>/             per-task results of the step of hop h (P3)
    └── ended/event          how the run ended, once it has
```

**Run ID passed down the chain.** `controller.sh ROOT STEP RUN HOP [opts…]`
and `job.sh ROOT STEP RUN HOP`. Every job checks that its run has not
ended (`SWF/runs/RUN/ended` absent) when it starts and again before it
hands off. If the run has ended, the job logs `stale-run` and exits 0. A
run ends exactly once, through `mkdir ended` in `swf_end_run`, which
also journals how: the last controller (`workflow-done`), a failure
(`workflow-failed`), `stop_workflow.sh` (`run-stopped`), or a newer run
(`run-superseded`). A stopped or superseded run therefore stops at its
next hop. A run forked by a requeue
keeps its run ID, so fencing can't stop it. The submission markers below
stop it instead.

**No accidental second run.** `start_workflow.sh` looks for queued jobs
named `<wf>_controller` or `<wf>_step<N>` and refuses to start while any
exist. Two flags state the intent:
- `-f` ends the existing runs (`run-superseded`), then cancels the jobs
  that provably belong to this directory (their `--comment` carries
  `swf:<run id>:…` for a run in `SWF/runs/`), then starts a new run.
- `-p` starts a new run *next to* the existing ones, which carry on. Its
  `run-start` event records `next_to=<run ids>`. Every job, log header
  and journal line carries its own run ID, and `stop_workflow.sh -r <run
  id>` stops one run without touching the other.

Without `-p`, a new run also ends every older run that has not ended. So
if `squeue` fails and shows nothing, an older run that is still alive
stops at its next hop anyway.

With `-p`, the runs share `log/events.tsv` and the controller's log. Two
jobs of different runs can append a line at the same moment. On a local
disk each `>>` line is written atomically, but NFS only emulates
`O_APPEND`, so appends from two nodes at once can corrupt the file
(open(2)). Whether the runs may share the
*project's* files is a question for the step code (02 §2.2).

**Idempotent, retried submission.** Every `sbatch` goes through
`swf_sbatch KEY …`:

```bash
# Submit at most once per KEY and run, retry transient failures, and
# before retrying check whether the "failed" submission went through.
function swf_sbatch {
  local key="$1"; shift
  local marker="$SWF__RUN_DIR/submit.$key" tag="swf:$SWF_RUN_ID:$key" out attempt
  if ! mkdir "$marker" 2> /dev/null; then          # requeued job: already done?
    if [[ -s "$marker/jobid" ]] || swf__find_tagged "$tag" "$marker"; then
      cat "$marker/jobid"; return 0
    fi
  fi
  for attempt in 1 2 3 4 5; do
    # stderr kept apart: an sbatch warning must not end up in the job id
    if out="$(swf__clean_sbatch --parsable --comment="$tag" "$@" 2> "$marker/stderr")"; then
      echo "${out%%;*}" > "$marker/jobid"; cat "$marker/jobid"; return 0
    fi
    swf_log "sbatch-failed" "key=$key attempt=$attempt: $(cat "$marker/stderr")" >&2
    sleep "$((attempt * ${SWF__RETRY_DELAY:-30}))"
    swf__find_tagged "$tag" "$marker" && { cat "$marker/jobid"; return 0; }
  done
  return 1
}
```

This is simplified. The tested version in
[05 §5.3.2](05-reference-implementation.md#532-insttemplatesworkflowswflibsh-235-lines)
also folds a user's `--comment` in after the tag, and `swf__clean_sbatch`
removes this job's `SLURM*` variables from the submission's environment
(F28).

`mkdir` is atomic on NFS, GPFS and Lustre, which is why it is used as
the "already submitted" marker instead of a file test. The job comment is
the idempotency key that `squeue -o '%k'` can find after an ambiguous
failure.

**What this changes for `merck_calib2`.** The second start would have
needed `-p`, and its jobs, log lines and journal entries would have
carried its own run ID. An accidental second start would have been
refused. A requeued first controller would have found the `step.1`
marker and not submitted again. P1 can't make two runs safe on one
swfcalib state. That needs support in swfcalib, or separate state per
run.

<a id="p2"></a>
### P2: Wait for the whole array (F2)

The minimal diff against today's `step.sh`:

```diff
-# Common job id var
-SWF__JOB_ID=${SLURM_JOB_ID:-$SLURM_ARRAY_JOB_ID}
+# Files are per task, but the hand-off must wait for every task of an array:
+# `afterany:<array job id>` covers the whole array (Slurm job_array docs)
+SWF__JOB_ID=$SLURM_JOB_ID
+SWF__DEP_ID=${SLURM_ARRAY_JOB_ID:-$SLURM_JOB_ID}
@@
+    # sbatch copies this job's SLURM* variables into the controller (F28):
+    # don't hand our array variables down the chain
+    unset "${!SLURM_ARRAY_@}"
-    sbatch --dependency=afterany:"$SWF__JOB_ID" \
+    sbatch --dependency=afterany:"$SWF__DEP_ID" \
```

**The `unset` is part of the fix, not an extra.** Without it, every
non-array step after the first array step inherits a stale
`SLURM_ARRAY_JOB_ID` from the controller (F28). It would then depend on
an old, finished array. `afterany` on a finished or purged job is
satisfied at once, so the controller could start before the step's job
has finished. With the `unset`, `SLURM_ARRAY_*` in a step are always
genuine.

This is a three-line change and should ship on its own, immediately. It
can also be applied by hand to the `SWF/step.sh` of existing workflow
directories. The complete fix for F28 also strips the memory and
`ntasks` variables that the controller hands to each step. The reference
implementation does it in one place (`swf__clean_sbatch`: `env -u` every
`SLURM*` variable except `SLURM_CONF`, for every nested `sbatch`).

<a id="p3"></a>
### P3: Every task reports, and the next controller checks (F3, F9)

At its end, every task (including the hand-off task) writes
`SWF/runs/<run>/hop.<h>/task.<i>.rc` and
`hop.<h>/expected = ${SLURM_ARRAY_TASK_COUNT:-1}`. The hand-off task
**always** hands off, even when its own instructions failed. The
controller of the next hop then checks the results *before* doing
anything else:

```bash
if (( SWF__HOP > 1 )) && ! swf_check_tasks "$((SWF__HOP - 1))"; then
  swf_end_run "workflow-failed" "previous step failed:$SWF__CHECK_MSG"
  exit 1                     # → Slurm FAIL mail on the controller (P10)
fi
```

`swf_check_tasks` passes only if `expected` tasks wrote `rc = 0`. A task
that was killed writes nothing, so it is counted as failed. Because P2
makes the controller wait for the whole array, all markers are final when
it looks.

Result: a failure in **any** task stops the workflow with a message in
the controller log and in `log/events.tsv`, and a FAIL mail if
configured. The remaining blind spot, the hand-off task itself being
killed before its tail, is narrowed by P5's SIGTERM trap and closed by
P12.

<a id="p4"></a>
### P4: Next-step decision protocol (F4, F12)

R side (`R/workflow.R`):

```r
change_next_workflow_step <- function(next_step, sbatch_opts = NULL,
                                      overwrite = FALSE) {
  next_step_file <- Sys.getenv("SWF_NEXTSTEP_FILE")
  opts_file <- Sys.getenv("SWF_NEXTSTEP_OPTS_FILE")
  if (next_step_file == "") {
    stop("The environment variable 'SWF_NEXTSTEP_FILE' is empty.\n",
         "Make sure you are in a running workflow")
  }
  next_step <- suppressWarnings(as.integer(next_step))
  if (length(next_step) != 1 || is.na(next_step) || next_step < 1) {
    stop("`next_step` must be a single positive integer")
  }
  task <- Sys.getenv("SLURM_ARRAY_TASK_ID")
  if (task != "" && task != Sys.getenv("SLURM_ARRAY_TASK_MAX")) {
    warning("Only the highest index task of an array sets the next step; ",
            "this call has no effect")
  }
  if (file.exists(next_step_file) && !overwrite) {
    stop("The next step was already set in this job (to ",
         readLines(next_step_file), "). Two pieces of code are choosing the ",
         "next step, e.g. `step_tmpl_map` slicing and the mapped function. ",
         "Use `overwrite = TRUE` if this is intended.")
  }
  # Both files are replaced together: options never outlive their decision
  unlink(c(next_step_file, opts_file))
  if (!is.null(sbatch_opts)) {
    writeLines(make_sbatch_opt_lines(sbatch_opts), opts_file)   # one per line
  }
  writeLines(as.character(next_step), next_step_file)
  message("The next workflow step was changed to ", next_step)
  invisible(next_step)
}
```

`make_sbatch_opt_lines()` is `make_sbatch_statement()` without the
`paste(collapse = " ")`.

Bash side: read the file line by line into an array, and pass the array
as separate arguments down to the controller (`"$@"` after the four fixed
arguments) and on to `sbatch` (`"${SWF__OPTS[@]}"`). Values with spaces
then survive. A tolerant reader keeps accepting the legacy single-line
format; see `swf_read_opts` in 05.

**Compatibility, in both directions.** The file is written by the
`slurmworkflow` installed on the HPC and read by the bash of the workflow
directory, and the two can come from different versions. One option per
line is still correctly word-split by the *old* bash (`$(cat …)` unquoted
splits on newlines too). The *new* bash still accepts the old
single-line format.

<a id="p5"></a>
### P5: Run the instructions in a child shell (F5, F6, F7, F24)

```diff
-source "$SWF__INSTRUCTIONS_SCRIPT"
+set +e                                   # the framework checks errors itself
+export SWF_CUR_TMP="${SLURM_TMPDIR:-${TMPDIR:-${TMP:-/tmp}}}"
+SWF__TASK_TMP="$(mktemp -d "$SWF_CUR_TMP/swf.XXXXXX")" || exit 1
+trap 'rm -rf "$SWF__TASK_TMP"' EXIT
+export SWF_NEXTSTEP_FILE="$SWF__TASK_TMP/nextstep"
+export SWF_NEXTSTEP_OPTS_FILE="$SWF__TASK_TMP/nextstep_opts"
+trap 'SWF__RETRY_DELAY=1; swf_log "signal" "SIGTERM received"' TERM
+bash -e "$SWF__INSTRUCTIONS_SCRIPT"     # same errexit semantics as before
+SWF__RC=$?
```

- `exit N` in the instructions now ends only the child. `exit 0` means
  "step succeeded" and the workflow continues; `exit 1` is a failure,
  reported by P3.
- `cd`, `set -u`, `set +e`, traps, variables and `PATH` changes
  (`module purge`) stay in the child. The hand-off runs in a known state
  and still finds `sbatch`.
- Exported `SWF_*` variables are still visible, since they are inherited.
  Nothing documented depends on sourcing.
- **SIGTERM** (time limit, `scancel`, preemption) reaches every process
  of the job. The child dies, and this shell runs its trap and then the
  tail, which records `rc = 143` and hands off within Slurm's `KillWait`
  (30 s by default). A time-limit failure becomes a reported failure
  instead of a silent stop. An OOM kill hits the R process, not the batch
  shell, so it is reported too.
- The per-task `mktemp -d` directory is created with mode 0700 under an
  unguessable name, so another user can no longer plant a next-step
  options file. This closes F24's injection. It is removed at exit and
  prefers `TMPDIR`, as R and sites do.
- **A subshell is an equivalent alternative to `bash -e`.** It is closer
  to today's semantics, because non-exported variables and functions stay
  visible:
  ```bash
  set +e; ( set -e; source "$SWF__INSTRUCTIONS_SCRIPT" ); SWF__RC=$?
  ```
  Never write `( … ) || handler` or `if ( … )`: bash disables `errexit`
  inside a command whose status is being tested, so failing instructions
  would keep running. The reference implementation uses `bash -e`, which
  makes the contract explicit: instructions see exported variables only,
  and that covers every documented `SWF_*` variable.

<a id="p6"></a>
### P6: One environment policy for every step (F8)

1. **Map slice offset as a job argument, not via `--export`.**
   `job.sh ROOT STEP RUN HOP [OFFSET]`, where `job.sh` exports
   `SWF__ARRAY_OFFSET=${5:-1}`. The map template stops emitting
   `export=…`, and its slicing passes the offset through the next-step
   protocol (P12 moves it into the controller). Every step then runs with
   the `--export=NONE` from its `#SBATCH` header, and a user's own
   `export`/`array` options are no longer overwritten (merge them, or
   error if they conflict).
2. **`export SLURM_EXPORT_ENV=ALL`** in `job.sh` after the `#SBATCH`
   block, as SchedMD recommends for `--export=NONE` jobs, so `srun`
   inside a step sees the step's environment.
3. **Pass `--export=NONE` on the command line** for every controller
   submission. The command line wins over an `SBATCH_EXPORT` that a step
   or a profile may set. (`SLURM_EXPORT_ENV` is not read by sbatch, only
   by srun.)
4. **Warn at start** when `SBATCH_*` variables are set (`compgen -e SBATCH_`):
   they override every `#SBATCH` line of every step. `SBATCH_EXPORT=ALL`
   breaks map steps outright (F8).
5. **Document the login-environment dependency.** Both `NONE` and a
   variable list make slurmd load the user's login environment on the
   node. If that fails, Slurm ≥ 25.05 requeues and holds the job, and
   `status_workflow.sh` should report a held step. Earlier versions run
   it bare. Sites that want a truly clean environment can use
   `--export=NIL` (Slurm ≥ 23.02), at the price of setting `PATH`
   explicitly in `setup_lines`.

<a id="p7"></a>
### P7: Make the working directory explicit (F6, F17)

- R writes `Rscript "$SWF__CUR_DIR/script.R"` instead of the relative
  path baked at creation. The script is found from any directory.
- `start_workflow.sh` records `pwd -P` (after `-d`) in
  `SWF/runs/<run>/workdir`, and every controller is submitted with
  `--chdir="$SWF_WORKDIR"`. A step with its own `--chdir` only moves
  itself, and the chain comes back to the workflow directory at the next
  controller.
- Until all R templates use `$SWF__CUR_DIR`, `start_workflow.sh` checks
  that every literal `Rscript "<path>"` in `steps/*/instructions.sh` exists
  from the current directory, and refuses to start otherwise ("run from
  the project root or use -d"). This turns F17's step-2 surprise into a
  refusal at start.

<a id="p8"></a>
### P8: Observability and operations (F9, F10, F11, F19, F20)

- **Journal `log/events.tsv`**, one line per run-level event, written
  only at points where one job of the run is active (start, controller,
  hand-off task), so the lines of one run never interleave:
  `time  run  hop  event  step  job  host  details`
  with events `run-start`, `step-submitted`, `already-submitted`,
  `workflow-done`, `workflow-failed`, `run-stopped`, `run-superseded`.
  `stale-run` goes to the job's log only.
- **Log headers.** Every controller and step prints one `[swf …]` line
  with run, hop, step, `SLURM_JOB_ID`, `SLURM_ARRAY_JOB_ID_TASK`, host,
  `SLURM_RESTART_COUNT` and working directory, plus a `step-end rc=… next=…`
  line. Bash steps get timestamps too.
- **Log names:** `%x_%j.out` for non-array steps and `%x_%A_%a.out` for
  arrays (the controller checks `job.sh` and the options for `--array`).
  No more `_4294967294`.
- **`status_workflow.sh`:** every run that has not ended (or else the
  last run started), each with its last journal events and its state:
  active, ended (and how), or an explicit *"nothing in the queue and no
  end event: the run stopped unexpectedly"*. Then the queued jobs.
- **`stop_workflow.sh [-r run]`:** ends every live run, or only the one
  given, with `run-stopped` first, so that a job starting meanwhile exits
  by itself. Then it cancels those runs' jobs.
- **Step-number validation in the controller:** `N + 1` means done.
  Anything else outside `1..N` is `workflow-failed: invalid step`.
- **Hop cap:** the controller refuses to go past hop `SWF_MAX_HOPS`
  (default 10,000, overridable in `workflow.yaml`). This catches runaway
  loops (F20).
- **`start_workflow.sh -o "<opts>"`**, one option per `-o`, applied to
  the first step: to restart a sliced map at slice `k`, or to raise a
  time limit for a re-run (F11).

<a id="p9"></a>
### P9: `start_workflow.sh` (F14, F16, F21, F25)

- The "sourced" guard comes **before** `set -e`, and returns 1.
- `getopts ":s:d:o:fth"`. A missing value, an unknown option, or a
  positional argument is an error with the usage text ("did you mean
  `-s 3`?"). No more infinite loop.
- `-s` must be in `1..n_steps`.
- `-t`: preflight with `sbatch --test-only` on every `job.sh` and the
  controller. This validates partitions, accounts, time limits, QOS and
  array sizes against the live configuration *before* a multi-day
  workflow is half done (`--test-only` submits nothing).
- CRLF repair limited to `start_workflow.sh` and `SWF/**/*.{sh,R}`
  (excluding `SWF/runs`), with NUL-delimited `find | xargs -0 grep -lZ $'\r' | xargs -0 sed -i 's/\r$//'`
  followed by `|| true`, because under `pipefail` "no file had a CR" exits
  123. The harness caught this: without it, every start died silently.
  No `file`/`perl` dependency, and logs are never touched.
- Quote every expansion (`"$(dirname "$0")"`, `basename "$SWF_ROOT"`).
- Document the site requirements of F16 in the vignette: submission from
  compute nodes, `sbatch` on the login `PATH`, identical mount paths.

<a id="p10"></a>
### P10: Controller options (F15)

```r
create_workflow(wf_name, default_sbatch_opts, wf_common_dir = "workflows",
                ctrl_sbatch_opts = NULL)
```

- The default copies `account`, `partition`, `qos`, `clusters` and
  `reservation` from `default_sbatch_opts`. If `mail-user` is set, it
  also adds `mail-user` and `mail-type = FAIL`, so a controller that stops
  the workflow (P3, P8) sends a mail.
- `ctrl_sbatch_opts` overrides or extends these (for example a "short" or
  "debug" partition, `--qos=express`, or `mem=1G` where `mem-per-cpu` is
  not allowed).
- The fixed `#SBATCH` lines stay as defaults and are emitted only when
  the user didn't set them.

<a id="p11"></a>
### P11: R-side changes that affect the runtime (F21, F22, F23)

- **Write LF on every OS.** Use `writeLines(x, con <- file(path, "wb"))`
  in `simple_brew()`, `helper_write_instructions()` and the YAML writer.
  On Windows, text-mode connections turn `\n` into `\r\n`, which is the
  only reason the CRLF fixer exists.
- **Functions by name:** `step_tmpl_do_call(what = "swfcalib::calibration_step1", …)`
  resolves `what` on the HPC with `getExportedValue()`. The HPC's
  installed code then runs, consistent with its own namespace.
- **Version check:** at creation, record the version of each package
  whose namespace a serialized closure refers to. The runtime R template
  compares them with the installed versions and warns, or with an option
  errors, on mismatch.
- `step_tmpl_map`: error when `n_iter == 0` or no `...` argument is given;
  default `max_array_size = 1000` (Slurm's default `MaxArraySize` is
  1001); don't overwrite user `array`/`export` options.
- Runtime templates: `file.path` instead of `fs::path`, `invisible(gc())`,
  print `SLURM_JOB_ID`/task at start, and inline the slicing so the map
  template no longer needs `slurmworkflow` on the HPC.
- `make_wf_vars()`: add the missing `/` in `SWF__STEPS_OUT`.
- Format numeric option values with
  `format(val, scientific = FALSE, trim = TRUE)` in `make_sbatch_lines()`
  and `make_sbatch_statement()`, so that `mem = 100000` stays `100000`
  rather than `1e+05` (F27).
- Map steps: save each item in its own file (`map/<i>.rds`) plus a small
  shared `MoreArgs.rds`, so a task reads only its own input (F23).
- `validate_sbatch_opts()`: reject `wait`, `test-only`, `help`, `usage`,
  `wrap`, `parsable` and `batch`, and warn that `output`, `job-name` and
  `dependency` (and `array`/`export` on map steps) are set by the runtime
  (F26).

---

## Tier 2: queue the controller before the step runs

<a id="p12"></a>
### P12: Pre-submitted controller (F3, F9, F11, F18)

Tier 1 still relies on the step reaching its last lines to hand off. A
step killed by `SIGKILL` (node failure, `KillWait` exceeded, an OOM that
takes out the batch shell) still ends the run silently, with only
`status_workflow.sh` to notice. The fix is to use `afterany` for what it
is good at:

```
 controller(h)                                   (decides, then submits two jobs)
   ├─ sbatch --parsable  step N          → S     (array or not)
   └─ sbatch --dependency=afterany:S  controller(h+1)
                                                 (S from --parsable is the array job id,
                                                  so this waits for every task)
 step N tasks: run instructions, write hop.<h>/task.<i>.rc and decision.<i>
 controller(h+1) runs whatever happened to S:
   1. results:  all tasks rc=0?          no → policy (stop + mail | retry k | rerun failed
                                              indices with --array=<list> | continue)
   2. decision: decision files agree?    no → error; none → N+1
   3. slicing:  map step with items left? → same step, next slice, offset as job argument
   4. submit the next step + controller(h+2)
```

What it buys:

- **Every way a step can end** (success, error, time limit, OOM, node
  failure, `scancel`) is followed by a controller that sees it and acts.
  This closes the last silent-stop path of F9.
- **Steps no longer call `sbatch`.** Compute nodes only need to run work.
  The instructions cannot break the hand-off, because there is no
  hand-off code in the step.
- **One place for flow logic.** Next-step decisions come from shared-FS
  files under `SWF/runs/<run>/hop.<h>/`, so any task may decide and
  conflicts are detected. Map slicing moves into the controller, which
  reads `steps/N/map.env` (`N_ITEMS`, `ARRAY_SIZE`) written by R. User
  decisions and slicing can no longer collide (F4).
- **Rerun only what failed.** The controller knows which indices failed
  and can resubmit `--array=3,17,29` (F11).
- **Throughput (F18).** The controller can queue slice `k+1` with
  `--dependency=after:<slice k>` (start, not end) and an `%N` throttle,
  removing the straggler barrier when the limit is `MaxArraySize` rather
  than `MaxSubmitJobs`.

What it costs:

- One extra pending job per hop while the step runs (the next
  controller, in state `Dependency`). This counts against
  `MaxSubmitJobs`, like today's hand-off controller does at the end of an
  array.
- The controller grows from about 40 lines to about 150. It is still
  bash, still idempotent through P1's markers, and still cheap.
- `stop_workflow.sh` must cancel the pending controller as well as the
  step. The `swf:` comment tags make that exact.

A cheaper alternative, if P12 is too big: submit, from the controller, a
tiny "watchdog" job with `--dependency=afternotok:S --kill-on-invalid-dep=yes`
that only writes `workflow-failed` to the journal and sends a mail. Slurm
removes it when S succeeds. It closes the silent-stop gap without moving
the flow logic.

---

## Testing the runtime

None of the bash runtime is tested today. The test suite only checks
that R creates files. A mock Slurm is enough to test almost everything
above in CI, with no cluster:

- `bin/sbatch` stub: parses CLI and `#SBATCH` options (CLI wins; the last
  `#SBATCH` wins), records the job, and supports `--parsable`,
  `--dependency=afterany`, `--array`, `--output` patterns, `--export`,
  `--chdir` and `--test-only`.
- `run_queue`: runs queued jobs whose dependencies are done, with
  `SLURM_*` variables set. It reproduces Slurm's array-ID rule (the last
  task started inherits the array ID) and can break it on purpose, and it
  can inject failures and requeues.
- Scenarios: linear chain, loop, sliced map, double start, deliberate
  parallel start, `exit 0`, `cd`, `set -u`, failing non-last task, failing
  last task, stale options, requeue after hand-off. Each asserts the sequence of executed (step,
  task) pairs and the final journal event.

The harness used for this review (≈600 lines, 30 scenarios, about 90 s
to run) is described with its results in
[05-reference-implementation.md](05-reference-implementation.md).
It could go to `tests/runtime/` and run from GitHub Actions next to
`R CMD check`. A real single-node Slurm in Docker is a useful
complement for the `--export`/`--get-user-env` behaviours that a mock
cannot reproduce.

## Rollout and compatibility

- **Workflow directories are self-contained.** Directories created by
  0.1.0 keep their scripts and are unaffected. The new behaviour applies
  to workflows created after the upgrade.
- **The one shared interface** is `change_next_workflow_step()` (R
  installed on the HPC) ↔ the step's bash (from the workflow directory).
  P4 keeps it compatible in both directions. Keep the variable names
  `SWF_NEXTSTEP_FILE`/`SWF_NEXTSTEP_OPTS_FILE`, which swfcalib and
  EpiModelHPC call through.
- **Behaviour changes users will notice** (NEWS entries): `exit 0` in a
  step now continues the workflow; a failing array task now stops the
  workflow; a second start is refused unless `-f` or `-p` is given;
  invalid jump targets are errors; non-array log names change from
  `_4294967294` to the job ID.
- Add `SWF/runs/` to the workflow `.gitignore` guidance, since it holds
  run state, not workflow definition.
- **Order of merge:** P2 (alone, now), then P9 + P5 + P4, then P1 + P3 +
  P8, then P6/P7/P10/P11, then P12.

# Dynamic steps: implementation spec (branch `feature/dynamic-steps`)

Status: agreed design, to implement. Backward compatibility is **not** a goal.
The mock in `design/swfcalib_mock/` shows the files for a real workflow; where
it and this spec disagree, this spec wins.

## Principles

1. The engine (everything that runs on the HPC outside a user payload) is
   **bash + coreutils + Slurm client commands only**. No R, Python or jq.
   Target bash 4.2: no `declare -n`, no `mapfile -d`, no `${x@Q}`, no negative
   array indices; guard empty arrays under `set -u` with
   `${a[@]+"${a[@]}"}`. Use `10#$n` for numbers.
2. Steps can be pure bash. Everything a job can do (change the next step,
   override a submission) is a **bash command (`swf`)**; R functions are thin
   wrappers that call it.
3. The controller never interprets the design: it submits from **resolved**
   `.swf` files (options already merged). Merging and validation happen in
   `swf override`, when the message is written, in the job that asks.
4. Overrides are **one-shot**: they apply to one submission, then the step
   reverts to its `step.swf`. Several writers **aggregate** (an override is
   merged on top of a pending one); keeping that consistent is the user's job.
5. `swf next` / `change_next_workflow_step()` are documented as **dangerous**
   (they can create infinite loops or skip work).

## The `.swf` format

- UTF-8 text, LF line endings (a trailing `\r` is stripped by readers).
- Line 1 is exactly `#!swf-v1`.
- Lines starting with `#` are comments; empty lines are ignored.
- Every other line is `key=value`. Key = text before the first `=`, must
  match `^[A-Za-z0-9_.-]+$`. Value = the rest of the line, verbatim (no
  quoting, escapes or trimming; may be empty, may contain `=`, spaces,
  quotes, `$`, `*`, `%`, `#`). Values never contain `\n` or `\r`; writers
  reject them.
- A key appears at most once per file; readers reject duplicates.
- Nothing ever `source`s or `eval`s a `.swf` file.
- Writers write a temp file in the same directory (`.<name>.tmp.<pid>`),
  then `mv`/`file.rename()` it into place.

Keys:

| Key | Where | Meaning |
|---|---|---|
| `opt.<option>` | step, override, workflow | one sbatch long option, passed as `--<option>=<value>` |
| `ctrl.opt.<option>` | `workflow.swf` | option of the controller job |
| `next` | step, override, `msg/next.swf` | **name** of the step to run after this one; absent = the step built after it; in a step file, empty = end the workflow after this step |
| `data.<key>` | step, override | template data, opaque to the engine (e.g. `data.map.total`) |
| `skip` | override | `1` = do not submit, go on to this file's `next` |
| `repeat` | override | `1` = run this step again right after it ends, before any `msg/next.swf` |
| `origin.step`, `origin.job` | override, next | provenance (writer step name, `$SLURM_JOB_ID` or `<array job>_<task>`) |
| `id`, `started`, `first_step`, `workdir`, `stopped` | `run/current.swf` | live run |
| `exclusive.<group>`, `valid`, `reserved` | `sbatch_rules.swf` | space-separated option-name lists |

Number formatting from R: integers without decimals (`180`, never `180.0`
or `1e+05`): `format(x, scientific = FALSE, trim = TRUE)`.

## Workflow directory

```
workflows/<wf>/
├── swf                                 executable, the only user/job entry point
├── swf.d/
│   ├── lib.sh                          bash library (sourced by swf, controller.sh, job.sh)
│   ├── controller.sh                   controller job (fixed #SBATCH lines only)
│   ├── job.sh                          generic step job (#SBATCH --export=NONE, --open-mode=append only)
│   ├── workflow.swf                    opt.* defaults, ctrl.opt.*
│   ├── sbatch_rules.swf                exclusive groups, valid options, reserved options
│   ├── steps/<N>_<name>/step.swf       resolved default submission
│   ├── steps/<N>_<name>/instructions.sh  payload (as today)
│   ├── steps/<N>_<name>/...            template files (script.R, do_call.rds, map.rds)
│   └── run/
│       ├── current.swf
│       └── <run_id>/
│           ├── history
│           ├── msg/next.swf
│           ├── msg/override/<name>.swf
│           ├── used/<ctrl_job>_next.swf, used/<ctrl_job>_override_<name>.swf
│           ├── failed/<job_id>             (content: exit code)
│           └── lock/                       (mkdir lock)
└── log/<run_id>/
    ├── controller.out
    └── <N>_<name>_<job>_<task>.out        (sbatch --output pattern %A_%a)
```

- `<N>` = build order, 1-based, not zero padded. `<name>` matches
  `^[A-Za-z][A-Za-z0-9_-]*$` (never numeric, safe as a file name), unique in
  the workflow, default `step_<N>`. The directory is the only place the name
  is stored. Resolution: list `swf.d/steps/*/`, split each base name at the
  **first** `_` → `(N, name)`. A name argument matches `name` exactly; an
  all-digit argument matches `N`. Anything else is an error.
- `run_id` = `$(date +%Y%m%d-%H%M%S)-$$` (created by `swf start`).
- `history`: one event per line, space-separated `key=value` fields whose
  values never contain spaces. Fields always start with `time=<ISO-8601>
  event=<start|submit|claim|skip|end|stop|error>`; others by event:
  - `start first=<N>_<name> ctrl=<id>`
  - `submit step=<N>_<name> job=<id> ctrl=<next ctrl id> by=<this ctrl id or start> from=<path relative to swf.d/>`
  - `claim file=<used/...> by=<ctrl id>`
  - `skip step=<N>_<name> by=<ctrl id>`
  - `end by=<ctrl id>` (no step left)
  - `stop cancelled=<id,id,...>` (may be empty)
  - `error by=<ctrl id> reason=<word_without_spaces>`

## Environment of a running step (exported by `job.sh` for the payload)

`SWF_ROOT` (absolute), `SWF_NAME` (basename of root), `SWF_RUN_ID`,
`SWF_RUN_DIR`, `SWF_LOG_DIR`, `SWF_CMD` (absolute path to `swf`),
`SWF_CUR` (step number), `SWF_CUR_NAME`, `SWF__CUR_DIR` (step directory),
`SWF__INSTRUCTIONS_SCRIPT`, `SWF_SUBMISSION` (absolute path of the `.swf`
file this submission was made from: the step's `step.swf` or a claimed
`used/...` file). Removed: `SWF_SUMMARY`, `SWF_NEXTSTEP_FILE`,
`SWF_NEXTSTEP_OPTS_FILE`, `SWF_CUR_TMP`, `SWF__ARRAY_OFFSET`.

## `swf` command

`swf <command> [args]`, `swf help`, `swf <command> --help`. `SWF_ROOT` =
`realpath` of the script's directory. Must refuse to run when sourced. Every
error goes to stderr with a non-zero exit.

User commands (login node):

- `swf start [-s <step>] [-d <dir>] [--force]`
  - `-s`: first step, name or number (default: step 1). `-d`: `cd` there
    first; jobs run from the directory `swf start` runs in (as today:
    sbatch inherits it).
  - Refuse if `run/current.swf` exists, has no `stopped=`, and any job id
    from its history is still in `squeue`; `--force` runs `swf stop` first.
  - Check `sbatch` is on `PATH`; convert CRLF files under the workflow
    (existing `fix_crlf_files`).
  - Create `run/<id>/{msg/override,used,failed}`, `log/<id>/`, write
    `run/current.swf` (`id`, `started`, `first_step=<name>`, `workdir`),
    submit the first controller (`--parsable`, `--output=log/<id>/controller.out`,
    `--job-name=<wf>_ctrl`, `ctrl.opt.*`) with args
    `<root> <run_id> first <N>_<name>`, append `event=start`, print the run id.
- `swf stop`: add `stopped=<time>` to `current.swf` (atomic rewrite),
  `scancel` every job id (`job=` and `ctrl=` fields, controllers first) from
  the run's history, ignoring errors for finished jobs; append `event=stop`.
- `swf status`: run id, start, stop, workdir; the last `submit` (step, job
  id) and its queue state (`squeue -h -j <id> -o %T`, summarised as counts
  per state, "not in queue" when empty); pending messages under `msg/`;
  number of `failed/` markers with their job ids; last 5 history lines.
  `sacct` must not be required.
- `swf log [-s <step>] [-t <task>] [-r <run_id>] [-n <lines>] [-f] [--path]`:
  without `-s`, the controller log; with `-s`, the logs of the **last job of
  that step** in the run (from history). `-t` picks an array task (default:
  all of that job's files). `--path` prints paths only; `-f` runs `tail -f`;
  default `tail -n 50` (`-n`). Default run: current.
- `swf steps`: one line per step: number, name, `next` (or `-`).
- `swf runs`: list run ids, newest last, marking the current one.

Job commands (also usable on the login node; the run = `$SWF_RUN_ID` if set,
else `current.swf`'s `id`):

- `swf next <step>`: write `msg/next.swf` (`next=<name>`, `origin.*`).
  Last writer wins. Validates that the step exists.
- `swf override <step> [--opt k=v]... [--unset-opt k]... [--data k=v]...
  [--skip] [--repeat] [--from <file>] [--reset]`
  - Base: `--from <file>` if given, else the pending
    `msg/override/<name>.swf` if any (aggregation), else the step's
    `step.swf`; `--reset` ignores the pending override. `skip`, `repeat`
    and `origin.*` of the base are dropped.
  - `--opt k=v` (k without leading `--`): validate `k` is in `valid` and not
    in `reserved`; remove the other members of `k`'s exclusive group; set.
    `--unset-opt k` removes it. `--data k=v` sets `data.k`. Values must not
    contain newlines.
  - Writes the full resolved file under the lock, prints its path.
- Locking: `mkdir run/<id>/lock` with retries (sleep 0.1–1 s, give up after
  ~60 s with an error); removed with a trap. Used by `next`, `override` and
  by the controller's claim.

## Controller (`SWF/controller.sh`)

Args: `<root> <run_id> first <N>_<name>` or
`<root> <run_id> after <N>_<name> <submission path>`.
`#SBATCH`: `--open-mode=append --time=10 --nodes=1 --cpus-per-task=1
--mem-per-cpu=500 --export=NONE` (fixed). Logs every decision to stdout
(the controller log), including the full `sbatch` argument list.

1. If `current.swf`'s `id` is not this run, or it has `stopped=`, log and
   exit 0.
2. `after` mode, finished step S, submitted from file F:
   a. under the lock, if `msg/override/<S>.swf` exists with `repeat=1`,
      claim it (move to `used/<ctrl>_override_<S>.swf`, event `claim`) →
      target T = S, file = claimed file; go to 4.
   b. else, if `msg/next.swf` exists, claim it; T = its `next`.
   c. else T = F's `next` if the key exists (empty → end), else the step
      numbered N+1 (none → end).
   `first` mode: T = the given step.
3. Choose the file for T: claim `msg/override/<T>.swf` if it exists, else
   `steps/<N>_<T>/step.swf`. If T does not resolve: event `error`, exit 1.
4. If the file has `skip=1`: event `skip`, T = its `next` / the following
   step as in 2c, back to 3. At most (number of steps + 1) skips, then
   `error reason=skip_loop`.
5. End: event `end`, exit 0.
6. Submit T: `sbatch --parsable --job-name=<wf>_<N>_<name>
   --output=<log dir>/<N>_<name>_%A_%a.out <opt args...> swf.d/job.sh <root>
   <run_id> <N>_<name> <absolute file path>`. Strip `;cluster` from the id.
   Then submit the next controller: `sbatch --parsable
   --dependency=afterany:<job id> --job-name=<wf>_ctrl
   --output=<log dir>/controller.out <ctrl opt args...> SWF/controller.sh
   <root> <run_id> after <N>_<name> <file>`. Append `submit`.
   If `sbatch` fails for the step: event `error reason=sbatch_failed`, exit 1.
7. Re-read `current.swf`: if it now has `stopped=`, `scancel` both new jobs.

Arguments are built in a bash array from the `opt.*` lines, one element per
option, never re-split.

## `job.sh`

`#SBATCH --export=NONE` and `#SBATCH --open-mode=append` only. Args
`<root> <run_id> <N>_<name> <submission>`. Sources `lib.sh`, exports the
environment above, runs the payload in a child shell:
`bash -e "$SWF__INSTRUCTIONS_SCRIPT"`. On a non-zero exit, writes
`run/<id>/failed/<id>` (`<SLURM_ARRAY_JOB_ID>_<SLURM_ARRAY_TASK_ID>` for
arrays, else `SLURM_JOB_ID`) containing the exit code, and exits with it.
No hand-off: `job.sh` never calls `sbatch`.

## R side

- Drop `yaml` from Imports. Base-R `read_swf(path)` (named character
  vector, order kept, validates as above) and `write_swf(x, path)` (atomic).
  Unexported but tested.
- Summary object: `list(name, root, default_sbatch_opts, steps)` where each
  step is `list(number, name, next, sbatch_opts, data)`. Rebuilt from the
  files by `load_workflow()`; never stored elsewhere.
- `create_workflow(wf_name, default_sbatch_opts, wf_common_dir = "workflows")`:
  copy `inst/templates/workflow`, make `swf` executable, write
  `workflow.swf` (`opt.*` = defaults; `ctrl.opt.partition` and
  `ctrl.opt.account` when present in the defaults) and `sbatch_rules.swf`
  (from `get_exclusive_sbatch_opts()`, `get_sbatch_opts_list()`, reserved =
  `dependency job-name output parsable`). Reserved options are also refused
  in `default_sbatch_opts` / `sbatch_opts`.
- `add_workflow_step(wf_summary, step_tmpl, sbatch_opts = NULL,
  step_name = NULL, next_step = NULL)`: name default `step_<N>`, validated
  (regex, unique). `next_step`: a name (validated by regex only, it may be
  added later) or a number of an existing step (converted to its name), or
  `NA`/`""` meaning "end after this step". Creates `steps/<N>_<name>/`,
  calls the template, writes `step.swf` (`next`, merged `opt.*`, `data.*`).
- Template contract: `function(instructions_script, wf_vars, wf_summary,
  sbatch_opts, ...)`; returns `NULL`, `list()`, or
  `list(sbatch_opts = <named list>, data = <named list>)` (data names are
  flat, e.g. `"map.n_items"`, written as `data.map.n_items`).
- Runtime helpers (exported):
  - `get_workflow_root()`, `get_current_workflow_step()` (number),
    `get_current_workflow_step_name()`, `get_workflow_submission()`
    (`read_swf(Sys.getenv("SWF_SUBMISSION"))`).
  - `change_next_workflow_step(next_step, sbatch_opts = NULL)`: `swf next`
    (+ `swf override` when `sbatch_opts`). Doc: dangerous.
  - `override_workflow_step(step, sbatch_opts = NULL, data = NULL,
    skip = FALSE, repeat_step = FALSE, unset_opts = NULL, from = NULL,
    reset = FALSE)`: `swf override`.
  - `set_map_size(step, n)`: for a `step_tmpl_map` step. Reads the step's
    `data.map.n_items`, `data.map.max_array_size` and the `%k` throttle of
    its `opt.array`. `n == 0` → override with `skip`. `n > n_items` → error.
    Else override `opt.array = 0-(min(n, max)-1)[%k]`, `data map.total = n`,
    `data map.offset = 0`.
  - Calls to `swf` use `system2(cmd, shQuote(args), stdout = TRUE,
    stderr = TRUE)` and turn a non-zero status into an R error with the
    output. The `swf` path is `Sys.getenv("SWF_CMD")`, else
    `<get_workflow_root()>/swf`.
- `step_tmpl_map(FUN, ..., MoreArgs, setup_lines, max_array_size = Inf)`:
  n = length of the iterators (error if 0). Returns
  `sbatch_opts = list(array = "0-<min(n, max)-1>")` and data `map.n_items`,
  `map.max_array_size` (finite: `min(max, n)`), `map.offset = 0`,
  `map.total = n`. No `--export`.
- `inst/templates/step_tmpl_map.R` (runtime): read the submission;
  `idx = offset + SLURM_ARRAY_TASK_ID + 1`; if `idx > total`, message and
  stop quietly. On the task with `SLURM_ARRAY_TASK_ID ==
  SLURM_ARRAY_TASK_MIN`, if `offset + slice < total` (slice = `min(max,
  total - offset)`), write the continuation:
  `override_workflow_step(<current name>, sbatch_opts = list(array =
  "0-<min(max, total - new_offset) - 1>[%k]"), data = list(map.offset =
  new_offset, map.total = total), repeat_step = TRUE, from =
  Sys.getenv("SWF_SUBMISSION"))`. Then call FUN with item `idx`.
- Removed: `make_sbatch_lines`, `make_sbatch_statement`, `simple_brew` use
  for `#SBATCH`, `workflow.yaml`, `start_workflow.sh`, `step.sh`,
  `archive_old_logs` (logs are per run now).
- Docs: README, vignette, NEWS (`slurmworkflow 0.2.0`), CLAUDE.md, roxygen
  (RoxygenNote stays 7.3.2: run roxygen through the project renv, which has
  roxygen2 7.3.2).

## Fake Slurm (`tests/fake_slurm/`)

Bash scripts `sbatch`, `squeue`, `scancel`, `fake_slurm_run`. State in
`$FAKE_SLURM_DIR` (required). Used by the bash engine tests and by testthat
end-to-end tests, and to run the tester project locally.

- `sbatch`: options from the command line and from `#SBATCH` lines of the
  script (command line wins). Supports `--parsable`, `--dependency=afterany:<id>[:<id>]`,
  `--array=<a>-<b>[%k]`, `--array=<n>`, `--array=<a>,<b>,...`, `--output`,
  `--job-name`, `--export` (`NONE`, `ALL`, or `NONE,K=V,...` / `K=V,...`),
  `--chdir`. Any other `--k=v` / `--k` is accepted and recorded. An invalid
  array spec (e.g. `0--1`, `3-1`) fails like sbatch (`sbatch: error: Invalid
  job array specification`, exit 1). Job ids from a counter starting at
  1000. Records the full argv (one element per line, NUL-safe if possible),
  the script path, the args after it, the submit cwd and a PENDING state.
  Prints `<id>` with `--parsable`, else `Submitted batch job <id>`.
- `squeue`: `-h`, `-j <id,...>`, `-o <fmt>` with `%i %T %j`; `-u`/`--me`
  ignored. Lists PENDING/RUNNING jobs only (array tasks as `<id>_<task>`).
- `scancel <id>...` (also `<id>_<task>`): PENDING/RUNNING → CANCELLED.
  Unknown/finished ids: message on stderr, exit 0 (like slurm, which only
  warns).
- `fake_slurm_run [--one] [--max-jobs N]`: repeatedly run the lowest-id
  PENDING job whose dependencies are all finished (COMPLETED, FAILED or
  CANCELLED). Array tasks run one after the other, each with its own new job
  id. Environment: with `--export=NONE`, `env -i` plus `HOME`, `PATH`,
  `USER`, `LANG` and the names listed in `$FAKE_SLURM_KEEP_ENV`
  (space-separated, e.g. `R_LIBS`), plus any `K=V` from `--export`; with
  `ALL`, the runner's environment. Slurm variables: `SLURM_JOB_ID`,
  `SLURM_JOB_NAME`, `SLURM_SUBMIT_DIR`, and for arrays
  `SLURM_ARRAY_JOB_ID`, `SLURM_ARRAY_TASK_ID`, `SLURM_ARRAY_TASK_MIN`,
  `SLURM_ARRAY_TASK_MAX`, `SLURM_ARRAY_TASK_COUNT`. Output appended to
  `--output` with `%x %j %A %a` substituted (`%a` = `4294967294` and
  `%A` = job id when not an array); default `slurm-%j.out` in cwd. State
  COMPLETED if every task exits 0, else FAILED. Stops when nothing is
  runnable, or after `--one` job / `--max-jobs` jobs (default 500, then exit
  2). Prints one line per job run.

## Tests

- `tests/runtime/test-engine.sh`: bash tests of `swf`, controller and job
  scripts on fixture workflows (hand-written `.swf` files, bash-only
  payloads), through the fake Slurm. Exit non-zero on failure; prints a
  summary. Must also pass under `BASH_COMPAT=4.2`.
- `tests/testthat/test-runtime.R`: runs `test-engine.sh` (skip on Windows /
  when bash is missing) and R end-to-end scenarios (workflows built with the
  R API, run through the fake Slurm, `FAKE_SLURM_KEEP_ENV=R_LIBS`,
  `R_LIBS` = `.libPaths()`; skip when slurmworkflow is not installed, i.e.
  `system.file(package = "slurmworkflow") == ""`).
- Scenarios to cover (bash and/or R): linear run to `end`; static `next`
  loop exited by `swf next`; override applies once then reverts; `--skip`;
  aggregation of two overrides; option values with spaces/quotes/`*`/`$`
  arrive as one sbatch argument; exclusive options (`mem` replaces
  `mem-per-cpu`); reserved/invalid options refused; failing task → `failed/`
  marker and the workflow continues; `swf stop` (controller does not submit,
  pending jobs cancelled); `swf start` refuses a live run, `--force` works;
  `swf log -s` finds the last job's files; `swf status` output; map with
  `set_map_size()` (smaller, equal, 0 → skip, > n_items → error); map slices
  with `max_array_size` smaller than the total (continuation with `repeat`,
  and a `swf next` written by FUN waits for the last slice).

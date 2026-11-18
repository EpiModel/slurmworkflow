# Fixes round 2: implementation spec

Implements `edge-case-review.md` sections A, B, C and the decision in E.
`wrapper-contract.md` describes the target behaviour: once this round is
done, remove its `[planned: ...]` tags and its `[decision: E]` tag, and
describe the behaviour plainly. Bash stays 4.2-compatible; R stays base R
plus `fs`.

## E. A failed step stops the workflow (default)

- New `step.swf` key `on_failure`: `stop` (default when absent) or
  `continue`. Any other value is an error (`swf check`, controller).
  Overrides keep the value of their base (it is a normal key, copied by the
  merge); `swf override` gains `--on-failure stop|continue`.
- `job.sh` writes a failure marker for every non-zero exit (see A3).
- The controller gets the finished job's ID as an extra argument:
  `<root> <run_id> after <N>_<name> <submission> <job_id>` (the previous
  controller knows it; update `controller.sh` usage, `swf`, the tests).
  In `after` mode, **before claiming any message**: if
  `failed/<job_id>` or `failed/<job_id>_*` exists and the submission's
  `on_failure` is not `continue`, append
  `event=error by=<ctrl> reason=step_failed:<N>_<name>` (with the marker
  count, e.g. `failed=3`), log the marker files, leave the messages
  pending, and exit 1.
- R: `add_workflow_step(..., on_failure = c("stop", "continue"))`, written
  only when `continue` (absent = stop). The summary carries it;
  `load_workflow()` reads it.
- R `create_workflow()`: when the defaults have `mail-user`, also write
  `ctrl.opt.mail-user` and `ctrl.opt.mail-type=FAIL`, so that a controller
  that stops the workflow mails the user.
- `swf status`: when the last event is an error, print it on its own line
  (`Workflow stopped on error: step_failed:3_work (failed=2)`), before the
  history.

## Engine (bash: `inst/templates/workflow/swf`, `swf.d/*.sh`, `tests/fake_slurm`, `tests/runtime`)

- **A1** `swf next` / `swf override`: accept an all-digit reference as a
  step number (resolve to the name, as `start` and `log` do). Print
  `swf: note: step <N> is <name>; prefer names` on stderr.
- **A3** `job.sh`: define `swf_fail <code>` (atomic marker
  `failed/<id>`, idempotent) and use it for every non-zero exit, including
  pre-flight failures (missing instructions, run directory, step, bad
  submission path). Install `trap` for TERM, INT and HUP **before** the
  payload starts: forward the signal to the payload's process group or
  child, write the marker (code 128+signal), then exit. Test: the fake Slurm
  gains `scancel --signal=TERM <id>` or a `fake_slurm_run` option that
  sends TERM to a running job after N seconds (`FAKE_SLURM_KILL_AFTER`),
  enough to test a time-limit kill.
- **A4** `run_is_live`: an `squeue` failure (non-zero exit) counts as
  live; print the squeue error and suggest `swf stop` / `--force`. Fake
  `squeue`: `FAKE_SLURM_SQUEUE_FAIL=1` makes it fail (for tests).
- **A5** `swf override`: when the pending override of the target has
  `repeat=1` and `--reset` is not given, keep `repeat=1` and its `data.map.*`
  / `opt.array` (the continuation's slice), merge the other options.
  Document it in the help.
- **A8** Controller: before submitting, check every `opt.*` key of the
  chosen file. The name must be in `valid`, not in `reserved`, and
  non-empty, and the value must not be empty unless the option takes no
  value (keep it simple: refuse empty values). On failure:
  `event=error reason=invalid_option:<k>`, exit 1. Validate `skip`,
  `repeat` and `on_failure` values the same way (`skip`/`repeat`: `1` or
  `0`). Read `sbatch_rules.swf` once.
- **A10** `swf next` / `swf override`: refuse a stopped run (`swf: run <id>
  is stopped`), and a run directory that does not exist.
- **A11/A12** New `swf check`, run by `swf start` (refuse to start on any
  error, list every problem, exit 1). Checks:
  - every entry of `swf.d/steps/` matches `<N>_<name>` (with the name
    rules);
  - numbers are exactly `1..N` and names are unique;
  - each step has `step.swf` and `instructions.sh`;
  - every `.swf` parses;
  - every static `next` (non-empty) resolves to an existing name;
  - `on_failure` values are valid;
  - `workflow.swf` and `sbatch_rules.swf` exist and parse;
  - every `opt.*` passes the A8 rules.
  `swf steps` also marks invalid entries instead of printing them as
  steps.
- **A14** `fix_crlf_files`: only `swf`, `swf.d/*.sh`, `swf.d/**/*.swf`
  and `swf.d/steps/*/instructions.sh`.
- **B1** Lock timeout: `controller_error lock_timeout`, and the message
  (stderr and controller log) says: "lock <path> held for 60 s: a job may
  have been killed while holding it; if no job of this run is running,
  remove it". Write the holder's `$$` and host into `lock/owner` on
  acquisition, and print it.
- **B2** Controller errors carry detail: `step_not_found:<value>`,
  `invalid_option:<key>`, `sbatch_failed:<N>_<name>`. Capture `sbatch`'s
  stderr and print it in the controller log.
- **B8**
  - `swf status` survives an `squeue` failure (prints "queue unknown:
    <error>") and still shows the failures.
  - `swf start` writes `current.swf` only after the first controller is
    accepted. If submission fails, remove the run directory and the log
    directory, and leave the previous `current.swf` untouched.
  - `swf stop` reports `scancel` failures (non-zero exit when any cancel
    fails, but still marks the run stopped).
- **B9** `swf next`: when a pending `next.swf` has a different value,
  append `event=replace old=<a> new=<b>` and warn on stderr.
- **B10** `swf start`: `mkdir swf.d/run/.start.lock` (no wait: refuse with
  "another swf start is running" if present; remove on exit).
- **A9** (engine side) The reserved check of A8 covers `export` and
  `export-file` once the rules file lists them (R writes them, see below).
  The engine test fixtures must list them too.

## R (`R/`, `inst/templates/step_tmpl_*.R`, `tests/testthat`, docs)

- **A6** `step_tmpl_map.R`: compute
  `expected = min(max_array_size, total - offset)` and compare with
  `SLURM_ARRAY_TASK_COUNT` and `SLURM_ARRAY_TASK_MIN == 0`. On a mismatch,
  `stop()` with both numbers, the array spec and the submission path. Use
  the 0-based convention internally (`pos = offset + task_id`;
  item `pos + 1` in R), matching `wrapper-contract.md`.
- **A7** `format_swf_value(value, key)`: accept only length-1,
  non-missing, atomic character, numeric or integer (finite, integral
  numbers written without decimals; non-integral numbers written with
  `format(digits = 15)`). Reject logical, factor, list, data.frame, Date,
  and empty strings for `opt.*` values, naming the key and the type.
  `clean_sbatch_opts`: reject duplicate names.
- **A9** Reserved options: `dependency job-name output parsable export
  export-file`.
- **A11** `add_workflow_step`: refuse a workflow whose step directories are
  not exactly `1..N` (message lists them). The new number is `N + 1`. The
  final `load_workflow()` stays inside the cleanup guard.
- **A13** `add_workflow_step`: if the template returns an `sbatch_opts`
  name the user also passed, error ("the template sets `array`; ..."),
  unless the values are equal. `step_tmpl_map(..., array_throttle = NULL)`
  appends `%k` (positive integer) to every `array` it writes, including
  continuations and `set_map_size()` (they already preserve a `%k`).
- **B3** `step_tmpl_map.R`: validate `data.map.offset`, `total` and
  `max_array_size` (present, integer, `0 <= offset < total`, `max >= 1`)
  with a message naming the step and the submission file.
- **B4** `run_swf`: if the command does not exist or is not executable,
  stop with "`swf` not found at <path>: set SWF_CMD, or run inside a
  workflow job".
- **B5** `load_workflow()` / `create_workflow()` on a directory containing
  `workflow.yaml` or `start_workflow.sh`: "this is a slurmworkflow 0.1.x
  workflow; delete it and rebuild it with 0.2.0".
- **B6** `step_tmpl_do_call` / `step_tmpl_map`: warn at build time when
  `environment(what/FUN)` is the global environment and the function body
  uses free variables that are defined in the global environment
  (`codetools::findGlobals(f, merge = FALSE)$variables`; codetools is a
  recommended package shipped with R: add it to Suggests and skip the check
  when `requireNamespace("codetools", quietly = TRUE)` fails; keep it a
  warning).
- **B7** `next_step` errors name `next_step`; names are capped at 64
  characters; `wf_name` follows `^[A-Za-z][A-Za-z0-9._-]*$`.
- **E** see above: `on_failure`, controller mail options.
- **Docs (C)**: README and vignette state:
  - the job name and log formats as public API;
  - every `swf start` is a new run (`run/<id>`, `log/<id>`);
  - overrides aggregate, and slices inherit the wave's override;
  - the bare environment (`--export=NONE`) and `$SWF_RUN_DIR` for run state;
  - `opt.*` in `workflow.swf` are builder defaults;
  - **a failed step stops the workflow unless `on_failure = "continue"`**
    (prominent; also in NEWS);
  - numbers are positions, prefer names;
  - `change_next_workflow_step()` / `override_workflow_step()` are
    dangerous.
  Link `design/wrapper-contract.md` from the README.

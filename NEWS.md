## slurmworkflow 0.2.0

### Dependencies

- Dropped the `fs` dependency: slurmworkflow now uses base R only, and the
  cluster-side R step templates no longer need `fs` installed.

### Platforms

- The engine needs bash 4.2 or later at `/bin/bash`. Older bash (the 3.2 of
  stock macOS) is refused with `swf: bash >= 4.2 is required`. Building a
  workflow in R works on any platform.
- `swf start` restores the executable bit of `swf` when it was lost (workflow
  built on Windows or copied without permissions); use `bash swf start` then.

### A failed step stops the workflow

- **A failed step stops the workflow unless `on_failure = "continue"`.** When
  any job or array task of a step exits non-zero, is killed, or cannot start,
  the next controller submits nothing, records
  `event=error reason=step_failed:<N>_<name>` in the run history, and fails
  (`swf status` shows the error). `add_workflow_step()` gained
  `on_failure = c("stop", "continue")`; `override_workflow_step()` and
  `swf override` gained `on_failure` / `--on-failure` for one submission.
  `load_workflow()` reports it for each step.
- When the defaults set `mail-user`, `create_workflow()` gives the controllers
  `mail-user` and `mail-type=FAIL`, so a stopped workflow mails the user.

### Dynamic steps and the `swf` command

- Replaced `start_workflow.sh`, the step-specific `job.sh` files, and the old
  hand-off scripts with a single executable `swf` command, a generic
  `swf.d/job.sh`, and a controller-driven run engine.
- Added `swf start`, `stop`, `status`, `log`, `steps`, `runs`, `next`, and
  `override`. Run state and logs are now separated by run identifier.
- `swf log` prints log paths, one per line, for `less "$(swf log ...)"` or
  `| xargs`. It selects an array task (`-t`), a map element across
  `max_array_size` slices (`-e`), earlier submissions (`-b`) or all of them
  (`-a`); every option has a long form (`--step`, `--task`, ...).
- Each step log starts with the node and the number of CPUs of the job
  (`SLURMD_NODENAME`, `SLURM_CPUS_ON_NODE`), and ends with a two-line table of
  the payload's exit code and time used, like `system.time()`: elapsed, user,
  system, CPUs, and the share of the allocated CPUs used.
- `swf start` reports the step it starts at (name and number) on stderr; stdout
  is still only the run id.
- Step directories are now `swf.d/steps/<N>_<name>/`. `add_workflow_step()` gained
  `step_name` semantics with generated `step_<N>` defaults and the new
  `next_step` argument for static branches, loops, and explicit endings.
- Runtime `next` and submission overrides are one-shot messages. Added
  `override_workflow_step()`, `get_current_workflow_step_name()`,
  `get_workflow_submission()`, and `set_map_size()`.
  `change_next_workflow_step()` now wraps `swf next` and optionally
  `swf override`; it is explicitly documented as dangerous.

### Files and options

- Removed `workflow.yaml` and the `yaml` dependency. Workflow summaries are
  rebuilt from resolved `.swf` files by `load_workflow()` and now include step
  names, successors, and template data.
- Removed baked `#SBATCH` generation and the obsolete `make_sbatch_lines()`,
  `make_sbatch_statement()`, and `simple_brew()` helpers. The engine reserves
  `dependency`, `job-name`, `output`, `parsable`, `export`, and `export-file`
  and refuses attempts to set them.
- Removed `archive_old_logs`; logs belong to individual runs.
- The step-running environment now provides `SWF_RUN_ID`, `SWF_CUR_NAME`,
  `SWF_CMD`, and `SWF_SUBMISSION`. The old `SWF_SUMMARY`,
  `SWF_NEXTSTEP_FILE`, `SWF_NEXTSTEP_OPTS_FILE`, `SWF_CUR_TMP`, and
  `SWF__ARRAY_OFFSET` variables were removed.

### Map templates

- Map bookkeeping moved from exported shell variables to `data.map.*` entries
  in the resolved submission. `step_tmpl_map()` follows the new template result
  contract: `list(sbatch_opts = ..., data = ...)` and no `--export` override.
- Map continuation uses one-shot repeating overrides based on
  `SWF_SUBMISSION`. Dynamic next messages wait until the final slice.
- Added dynamic resizing with `set_map_size()`, including `n = 0` to skip and a
  hard ceiling at the original item count.
- `step_tmpl_map()` and `step_tmpl_map_script()` gained `array_throttle`,
  appended as `%k` to every array of the step, continuations included. An
  `array` in `sbatch_opts` that differs from the template's is an error.
- Map tasks use 0-based positions (`pos = data.map.offset +
  SLURM_ARRAY_TASK_ID`, item `pos + 1`) and fail before running `FUN` when the
  `data.map.*` entries are invalid or the array does not cover exactly the
  expected slice.

### Validation and error messages

- `swf start` runs the new `swf check` and refuses a broken workflow (step
  numbering, names, missing files, invalid `.swf` files, unknown static
  `next`, invalid options). `add_workflow_step()` refuses a workflow whose steps
  are not numbered `1..N`.
- `.swf` values must be single character strings or numbers; logical values,
  factors, lists, dates, and empty option values are refused, naming the key.
  Duplicate sbatch option names are refused. `export` and `export-file` are
  reserved.
- Workflow names must match `^[A-Za-z][A-Za-z0-9._-]*$`; step names have at
  most 64 characters; `next_step` errors name `next_step`.
- `load_workflow()` and `create_workflow()` detect 0.1.x workflow
  directories and ask to rebuild them.
- A missing `swf` command (`SWF_CMD`) gives a clear error.
- `step_tmpl_do_call()` and `step_tmpl_map()` warn when a function defined in
  the global environment uses global objects, which do not exist at run time
  (needs the suggested `codetools` package).

These changes intentionally break compatibility with workflows generated by
0.1.0. Recreate workflow directories with 0.2.0 and use `swf` instead of the old
start script.

## slurmworkflow 0.1.0

First stable release.

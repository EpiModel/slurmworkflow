# slurmworkflow

<!-- badges: start -->
[![Lifecycle: stable](https://img.shields.io/badge/lifecycle-stable-brightgreen.svg)](https://lifecycle.r-lib.org/articles/stages.html#stable)
[![R-CMD-check](https://github.com/EpiModel/slurmworkflow/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/EpiModel/slurmworkflow/actions/workflows/R-CMD-check.yaml)
<!-- badges: end -->

**slurmworkflow** builds multi-step workflows for
[Slurm](https://slurm.schedmd.com/)-equipped high-performance computing (HPC)
clusters. Define the steps locally in R, copy the workflow directory to the
cluster, and use its executable `swf` command to start and inspect a run. A
lightweight controller chain means no daemon or persistent SSH session is
needed.

## Installation

```r
# install.packages("remotes")
remotes::install_github("EpiModel/slurmworkflow")
```

## Build a workflow

```r
library(slurmworkflow)

wf <- create_workflow(
  wf_name = "my_analysis",
  default_sbatch_opts = list(
    partition = "compute",
    account = "my_project",
    `mail-type` = "FAIL",
    `mail-user` = "user@university.edu"
  )
)

wf <- add_workflow_step(
  wf,
  step_tmpl_bash_lines(c(
    "module load R/4.3.0",
    "Rscript R/prepare.R"
  )),
  sbatch_opts = list(mem = "16G", `cpus-per-task` = 4, time = 120),
  step_name = "prepare"
)

wf <- add_workflow_step(
  wf,
  step_tmpl_map(
    function(scenario, n_reps) run_scenario(scenario, n_reps),
    scenario = 1:1000,
    MoreArgs = list(n_reps = 32),
    max_array_size = 100,
    array_throttle = 50 # at most 50 tasks at once
  ),
  sbatch_opts = list(`mem-per-cpu` = "4G", `cpus-per-task` = 8),
  step_name = "simulate"
)

wf <- add_workflow_step(
  wf,
  step_tmpl_do_call_script(
    "R/summarise.R",
    args = list(input = "results"),
    setup_lines = "module load R/4.3.0"
  ),
  step_name = "summarise",
  next_step = NA # end the workflow after this step
)
```

Every step is stored as `swf.d/steps/<N>_<name>/`. Names are unique, match
`^[A-Za-z][A-Za-z0-9_-]*$`, and have at most 64 characters; the default is
`step_<N>`. Workflow names match `^[A-Za-z][A-Za-z0-9._-]*$`. Steps run in build order
unless `next_step` selects another successor. `next_step` can be a name (even one
added later), the number of an existing step, or `NA`/`""` for the end of the
workflow. This makes static branches and loops part of the workflow definition.

Step numbers are positions in build order, not identities: refer to steps by
name wherever possible.

The returned summary is rebuilt from `workflow.swf` and each `step.swf`; there is
no separately serialized `workflow.yaml` state to become stale. Workflows built
with slurmworkflow 0.1.x (`workflow.yaml`, `start_workflow.sh`) are refused:
delete them and rebuild them with 0.2.0.

### A failed step stops the workflow

**A step fails when any of its jobs or array tasks exits with a non-zero
status, is killed (time limit, `scancel`), or cannot start. By default, a failed
step stops the workflow: the next step is not submitted.** The controller that
finds the failure records `event=error reason=step_failed:<N>_<name>` in the run
history, prints it in `swf status`, and exits with an error, so that Slurm mails
the user when `mail-user` is set (`create_workflow()` then sets
`mail-type=FAIL` on the controllers).

Use `on_failure = "continue"` for a step whose failures must not stop the run,
for example a map where some tasks may fail:

```r
wf <- add_workflow_step(wf, step_tmpl_map(fit_one, 1:100),
                        step_name = "fit", on_failure = "continue")
```

The failure is still recorded (`swf status` lists it), and the next step runs.

### Step templates

| Template | Purpose |
|---|---|
| `step_tmpl_bash_lines()` | Run bash statements |
| `step_tmpl_bash_script()` | Copy and run a bash script |
| `step_tmpl_rscript()` | Copy and run an R script |
| `step_tmpl_do_call()` | Run a serialized function and argument list |
| `step_tmpl_do_call_script()` | Source an R script with arguments |
| `step_tmpl_map()` | Map a function over arguments as a Slurm array |
| `step_tmpl_map_script()` | Source an R script for each array element |

Custom templates have the signature
`function(instructions_script, wf_vars, wf_summary, sbatch_opts, ...)`. They
write the payload into `wf_vars$SWF__CUR_DIR` and return `NULL`, `list()`, or a
list containing named `sbatch_opts` and `data` lists. A data element named
`map.total`, for example, is saved as `data.map.total` in `step.swf`.

## Run and inspect on the HPC

Copy the complete workflow directory to the project on the cluster, then use its
single executable entry point. The engine needs bash 4.2 or later at `/bin/bash`
(any Linux cluster; stock macOS has 3.2 and is refused with a clear message).
If `swf` lost its executable bit (workflow built on Windows, or copied without
permissions), run `bash ./workflows/my_analysis/swf start` once: `swf start`
restores the bit.

```bash
# Start at step 1, from the current project directory
./workflows/my_analysis/swf start

# Start by name or number, optionally choosing the submission working directory
./workflows/my_analysis/swf start -s simulate
./workflows/my_analysis/swf start -s 1 -d ~/projects/my_project

# Inspect definitions, runs, current status, and logs
./workflows/my_analysis/swf steps
./workflows/my_analysis/swf runs
./workflows/my_analysis/swf status
./workflows/my_analysis/swf log
./workflows/my_analysis/swf log -s simulate
./workflows/my_analysis/swf log -s simulate -t 0 -n 100

# Stop the current run (controllers are cancelled before step jobs)
./workflows/my_analysis/swf stop
```

Every `swf start` is a new run, with a fresh run directory
(`swf.d/run/<run_id>/`) and log directory (`log/<run_id>/`); `swf start -s`
does not resume an earlier run. `swf start` first checks the workflow layout
(`swf check`) and refuses to start a broken workflow. Each step submission uses
a resolved `.swf` file; the controller does not reinterpret templates or merge
workflow defaults. `swf help` and `swf <command> --help` provide command-line
help.

The following formats are public and stable, for tools that watch the queue or
read logs:

- job names: `<wf>_<N>_<name>` for steps and `<wf>_ctrl` for controllers;
- logs: `log/<run_id>/<N>_<name>_<job>_<task>.out` (and
  `log/<run_id>/controller.out`).

### The step environment

Jobs are submitted with `--export=NONE`: a step starts from a bare environment
and inherits nothing from the shell that ran `swf start`. Load modules and set
paths in the step itself (for example with `setup_lines`). The engine provides
`SWF_ROOT`, `SWF_RUN_ID`, `SWF_RUN_DIR`, `SWF_CMD`, `SWF_CUR`, `SWF_CUR_NAME`,
`SWF_SUBMISSION`, and the usual Slurm variables. State that belongs to one run
(counters, flags, intermediate files) goes in `$SWF_RUN_DIR`: a restart is a new
run and starts with an empty `$SWF_RUN_DIR`.

Functions given to `step_tmpl_do_call()` and `step_tmpl_map()` are serialized:
pass every object they need through `args` or `MoreArgs`. A function defined in
the global environment that uses global objects triggers a warning at build
time.

## Dynamic workflows

Runtime changes are **one-shot messages**, not edits to the workflow design.
They affect one controller decision or one submission, after which the step
reverts to its `step.swf`. Pending overrides from several writers are aggregated.

### Change the successor

From a shell (inside a payload or on the login node):

```bash
./workflows/my_analysis/swf next prepare
```

From R running in a step:

```r
slurmworkflow::change_next_workflow_step("prepare")
```

Step numbers are accepted too, but they are positions: adding a step shifts
them. Prefer names, and never compute a target as `SWF_CUR` plus or minus an
offset.

**DANGEROUS:** `swf next` and `change_next_workflow_step()` can create infinite
loops or skip required work. They should be deliberate, guarded transitions, not
a substitute for checking that the workflow is making progress. Prefer a static
`next_step` when the successor is known at build time. The last `next` written
before the controller runs wins; replacing a pending one is logged in the run
history. A stopped run refuses new messages.

### Override a submission

```bash
# Set options/data, remove an option, or skip the next submission
./workflows/my_analysis/swf override simulate --opt time=04:00:00
./workflows/my_analysis/swf override simulate --unset-opt mem-per-cpu
./workflows/my_analysis/swf override simulate --skip

# Repeat a step once after it ends, using an existing submission as merge base
./workflows/my_analysis/swf override simulate --repeat --from /path/to/submission.swf

# Let one submission continue the workflow even if it fails
./workflows/my_analysis/swf override simulate --on-failure continue
```

The R wrapper exposes all of these arguments:

```r
slurmworkflow::override_workflow_step(
  "simulate",
  sbatch_opts = list(time = "04:00:00"),
  data = list(map.total = 20),
  unset_opts = "mem-per-cpu",
  on_failure = "continue"
)
```

**Overrides aggregate**: several overrides of the same step written before its
next submission are merged (the last value of each key wins). Use
`--reset`/`reset = TRUE` to ignore a pending override and start again from
the step defaults. `override_workflow_step()` is **DANGEROUS** for the same reason
as explicit successor changes: an unchecked repetition can loop forever and a
skip can bypass essential computation.

### Dynamic map sizes and slices

A map has an immutable original item count, `data.map.n_items`, and a current
submission total, `data.map.total`. `set_map_size()` changes the next submission
without changing the original payload:

```r
# Run only 20 of the originally available items next time
slurmworkflow::set_map_size("simulate", 20)

# Skip the next map submission
slurmworkflow::set_map_size("simulate", 0)
```

A value larger than `data.map.n_items` is an error. When `max_array_size` is
smaller than the map total, the first array task writes a `repeat = TRUE`
continuation with a new `data.map.offset`. Slices of one wave inherit the
wave's override: a continuation is built from the submission of the slice that
wrote it. A successor requested by the mapped function waits until the final
slice has completed. `array_throttle = k` adds `%k` to the array, and the
throttle is preserved by map resizing and continuation.

Each array task checks that its array covers exactly the expected slice and
that the `data.map.*` entries are valid; otherwise every task fails with a
message naming the submission (for example after an `array` override that
does not match `data.map.total`).

## sbatch options

Use long-form option names in named lists. Workflow defaults are merged with
per-step options, then with options returned by the template. Setting an option
such as `mem-per-cpu` removes conflicting defaults such as `mem`; supplying two
members of an exclusive group in the same update is an error. `dependency`,
`job-name`, `output`, `parsable`, `export`, and `export-file` belong to the
engine and cannot be supplied by users. A `partition` default is required.
Option values are single character strings or numbers; logical values, factors,
lists, empty strings, and duplicate names are refused. An option that a template
sets (such as `array` for `step_tmpl_map()`) cannot also be set in
`sbatch_opts` with a different value.

The `opt.*` entries of `swf.d/workflow.swf` are builder defaults: they are
merged into each `step.swf` when the step is added, and editing them later
changes nothing at run time. Only the `ctrl.opt.*` entries (controller options)
are read at run time.

## Workflow layout

```text
workflows/my_analysis/
├── swf
├── swf.d/
│   ├── lib.sh
│   ├── controller.sh
│   ├── job.sh
│   ├── workflow.swf
│   ├── sbatch_rules.swf
│   ├── steps/
│   │   ├── 1_prepare/
│   │   │   ├── step.swf
│   │   │   └── instructions.sh
│   │   └── 2_simulate/
│   │       ├── step.swf
│   │       ├── instructions.sh
│   │       ├── script.R
│   │       └── map.rds
│   └── run/
└── log/
```

See the package vignette and reference manual for the complete API.
[`design/wrapper-contract.md`](https://github.com/EpiModel/slurmworkflow/blob/main/design/wrapper-contract.md) describes the files
and conventions the engine relies on, for anyone writing a wrapper in another
language or reading the workflow files directly. In the
EpiModel ecosystem, [EpiModelHPC](https://github.com/EpiModel/EpiModelHPC)
provides higher-level templates built on these primitives.

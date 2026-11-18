# slurmworkflow

<!-- badges: start -->
[![Lifecycle: stable](https://img.shields.io/badge/lifecycle-stable-brightgreen.svg)](https://lifecycle.r-lib.org/articles/stages.html#stable)
[![R-CMD-check](https://github.com/EpiModel/slurmworkflow/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/EpiModel/slurmworkflow/actions/workflows/R-CMD-check.yaml)
[![codecov](https://codecov.io/gh/EpiModel/slurmworkflow/branch/main/graph/badge.svg)](https://codecov.io/gh/EpiModel/slurmworkflow)
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
    max_array_size = 100
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

Every step is stored as `swf.d/steps/<N>_<name>/`. Names are unique and match
`^[A-Za-z][A-Za-z0-9_-]*$`; the default is `step_<N>`. Steps run in build order
unless `next_step` selects another successor. `next_step` can be a name (even one
added later), the number of an existing step, or `NA`/`""` for the end of the
workflow. This makes static branches and loops part of the workflow definition.

The returned summary is rebuilt from `workflow.swf` and each `step.swf`; there is
no separately serialized `workflow.yaml` state to become stale.

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
single executable entry point:

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

Logs are isolated by run under `log/<run_id>/`. Each step submission uses a
resolved `.swf` file; the controller does not reinterpret templates or merge
workflow defaults. `swf help` and `swf <command> --help` provide command-line
help.

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
# Names are preferred for readability.
slurmworkflow::change_next_workflow_step("prepare")

# Numbering also works when appropriate.
current <- slurmworkflow::get_current_workflow_step()
slurmworkflow::change_next_workflow_step(current - 1L)
```

**DANGEROUS:** `swf next` and `change_next_workflow_step()` can create infinite
loops or skip required work. They should be deliberate, guarded transitions, not
a substitute for checking that the workflow is making progress.

### Override a submission

```bash
# Set options/data, remove an option, or skip the next submission
./workflows/my_analysis/swf override simulate --opt time=04:00:00
./workflows/my_analysis/swf override simulate --unset-opt mem-per-cpu
./workflows/my_analysis/swf override simulate --skip

# Repeat a step once after it ends, using an existing submission as merge base
./workflows/my_analysis/swf override simulate --repeat --from /path/to/submission.swf
```

The R wrapper exposes all of these arguments:

```r
slurmworkflow::override_workflow_step(
  "simulate",
  sbatch_opts = list(time = "04:00:00"),
  data = list(map.total = 20),
  unset_opts = "mem-per-cpu"
)
```

Use `--reset`/`reset = TRUE` to ignore a pending override and start again from
the step defaults. Overrides and repetitions are dangerous for the same reason
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
continuation with a new `data.map.offset`. A successor requested by the mapped
function waits until the final slice has completed. Array throttles such as
`%20` are preserved by map resizing and continuation.

## sbatch options

Use long-form option names in named lists. Workflow defaults are merged with
per-step options, then with options returned by the template. Setting an option
such as `mem-per-cpu` removes conflicting defaults such as `mem`; supplying two
members of an exclusive group in the same update is an error. `dependency`,
`job-name`, `output`, and `parsable` belong to the engine and cannot be supplied
by users. A `partition` default is required.

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

See the package vignette and reference manual for the complete API. In the
EpiModel ecosystem, [EpiModelHPC](https://github.com/EpiModel/EpiModelHPC)
provides higher-level templates built on these primitives.

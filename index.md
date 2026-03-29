# slurmworkflow

**slurmworkflow** is an R package for building and running multi-step
computational workflows on [Slurm](https://slurm.schedmd.com/)-equipped
HPC clusters. Define your entire pipeline locally in R, transfer it to
the HPC, and launch it with a single command — no persistent SSH
sessions, no long-lived daemons, no manual job chaining.

## How It Works

A **workflow** is a sequence of **steps**, where each step is an
[`sbatch`](https://slurm.schedmd.com/sbatch.html) job submission. Under
the hood, slurmworkflow uses Slurm’s `--dependency=afterany` mechanism
to chain steps through a lightweight controller script:

    start_workflow.sh
        └─▶ controller.sh (step 1)
                └─▶ step 1 runs
                        └─▶ controller.sh (step 2)
                                └─▶ step 2 runs
                                        └─▶ ...continues until all steps complete

Each step can also **alter the execution flow** at runtime — enabling
loops, conditional branching, and dynamic multi-batch array job
submission.

## Installation

``` r
# install.packages("remotes")
remotes::install_github("EpiModel/slurmworkflow")
```

## Quick Start

### 1. Create a workflow

``` r
library(slurmworkflow)

wf <- create_workflow(
  wf_name = "my_analysis",
  default_sbatch_opts = list(
    "partition" = "my_partition",
    "mail-type" = "FAIL",
    "mail-user" = "user@university.edu"
  )
)
```

This creates a `workflows/my_analysis/` directory containing all the
shell scripts and metadata needed to run on the HPC.

### 2. Add steps

**Run bash commands:**

``` r
wf <- add_workflow_step(
  wf_summary = wf,
  step_tmpl = step_tmpl_bash_lines(c(
    "git pull",
    "module load R/4.3.0",
    "Rscript -e 'renv::restore()'"
  )),
  sbatch_opts = list("mem" = "16G", "cpus-per-task" = 4, "time" = 120)
)
```

**Run an R script with arguments:**

``` r
wf <- add_workflow_step(
  wf_summary = wf,
  step_tmpl = step_tmpl_do_call_script(
    r_script = "R/01-fit_model.R",
    args = list(n_sims = 100, seed = 42),
    setup_lines = c("module load R/4.3.0")
  ),
  sbatch_opts = list("cpus-per-task" = 8, "time" = "04:00:00", "mem" = "32G")
)
```

**Run parallel array jobs (like `Map`):**

``` r
wf <- add_workflow_step(
  wf_summary = wf,
  step_tmpl = step_tmpl_map_script(
    r_script = "R/02-run_scenario.R",
    scenario_id = 1:500,
    MoreArgs = list(n_reps = 32, n_cores = 8),
    setup_lines = c("module load R/4.3.0"),
    max_array_size = 500
  ),
  sbatch_opts = list(
    "cpus-per-task" = 8,
    "time" = "04:00:00",
    "mem-per-cpu" = "5G"
  )
)
```

### 3. Deploy and run

``` bash
# Copy to HPC
scp -r workflows/my_analysis user@hpc.university.edu:projects/my_project/workflows/

# SSH in and launch
ssh user@hpc.university.edu
cd ~/projects/my_project
./workflows/my_analysis/start_workflow.sh
```

Monitor with `squeue -u <user>`. Logs are in
`workflows/my_analysis/log/`.

## Step Templates

slurmworkflow provides seven step templates covering the most common HPC
patterns:

| Template                                                                                                       | Description                                                              |
|----------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------|
| [`step_tmpl_bash_lines()`](https://epimodel.github.io/slurmworkflow/reference/step_tmpl_bash_lines.md)         | Run a character vector of bash commands                                  |
| [`step_tmpl_bash_script()`](https://epimodel.github.io/slurmworkflow/reference/step_tmpl_bash_script.md)       | Run a bash script file                                                   |
| [`step_tmpl_rscript()`](https://epimodel.github.io/slurmworkflow/reference/step_tmpl_rscript.md)               | Copy and run an R script (script is embedded in the workflow)            |
| [`step_tmpl_do_call()`](https://epimodel.github.io/slurmworkflow/reference/step_tmpl_do_call.md)               | Serialize and run an R function with arguments (like `do.call`)          |
| [`step_tmpl_do_call_script()`](https://epimodel.github.io/slurmworkflow/reference/step_tmpl_do_call_script.md) | Run an R script on the HPC with injected variables                       |
| [`step_tmpl_map()`](https://epimodel.github.io/slurmworkflow/reference/step_tmpl_map.md)                       | Run an R function across argument sets as a Slurm array job (like `Map`) |
| [`step_tmpl_map_script()`](https://epimodel.github.io/slurmworkflow/reference/step_tmpl_map_script.md)         | Run an R script across argument sets as a Slurm array job                |

All R-based templates accept a `setup_lines` argument for loading
modules (R, Python, etc.) before execution.

### Writing Custom Step Templates

Step templates are [function
factories](https://adv-r.hadley.nz/function-factories.html). A template
returns a function that receives `instructions_script` and `wf_vars`,
writes the bash instructions to run, and optionally returns sbatch
option overrides. You can build higher-level templates by wrapping the
base ones — this is exactly what
[EpiModelHPC](https://github.com/EpiModel/EpiModelHPC) does.

## Controlling Execution Flow

A running step can alter which step runs next, enabling loops and
conditional branching:

``` r
# Inside a running R step on the HPC:
current <- slurmworkflow::get_current_workflow_step()

if (convergence_not_reached) {
  # Loop back to this step
  slurmworkflow::change_next_workflow_step(current)
} else {
  # Continue to the next step (default behavior, no call needed)
}
```

## Sbatch Options

Pass any valid `sbatch` long-form option as a named list. Options set in
[`create_workflow()`](https://epimodel.github.io/slurmworkflow/reference/create_workflow.md)
apply to all steps by default; per-step options in
[`add_workflow_step()`](https://epimodel.github.io/slurmworkflow/reference/add_workflow_step.md)
override them.

``` r
# Workflow-level defaults
default_sbatch_opts = list("partition" = "compute", "account" = "my_alloc")

# Step-level overrides
sbatch_opts = list("mem-per-cpu" = "4G", "cpus-per-task" = 16, "time" = "08:00:00")
```

Mutually exclusive options (e.g., `mem` vs. `mem-per-cpu`
vs. `mem-per-gpu`) are validated automatically. The `partition` option
is required.

## Array Jobs and `max_array_size`

Many HPC clusters limit the maximum Slurm array size (commonly 1,000).
[`step_tmpl_map()`](https://epimodel.github.io/slurmworkflow/reference/step_tmpl_map.md)
and
[`step_tmpl_map_script()`](https://epimodel.github.io/slurmworkflow/reference/step_tmpl_map_script.md)
accept a `max_array_size` argument that automatically chunks large
arrays into sequential batches:

``` r
# 10,000 scenarios, submitted in batches of 500
step_tmpl_map_script(
  r_script = "R/run_sim.R",
  scenario_id = 1:10000,
  max_array_size = 500,
  setup_lines = c("module load R/4.3.0")
)
```

slurmworkflow handles the batch sequencing internally — when one batch
of array jobs completes, the next batch is automatically submitted.

## Start Script Options

``` bash
# Launch the workflow
./workflows/my_analysis/start_workflow.sh

# Start at step 3 (skip steps 1-2)
./workflows/my_analysis/start_workflow.sh -s 3

# Run from a different working directory
./workflows/my_analysis/start_workflow.sh -d ~/projects/my_project
```

## Integration with the EpiModel Ecosystem

slurmworkflow is a foundational building block in the
[EpiModel](https://www.epimodel.org/) ecosystem for mathematical
modeling of infectious disease dynamics:

    EpiModel              Core network-based epidemic simulation engine
        └─▶ EpiModelHPC   HPC extensions with domain-specific step templates
                └─▶ slurmworkflow   Workflow orchestration on Slurm

### EpiModel

[EpiModel](https://github.com/EpiModel/EpiModel) provides tools for
simulating deterministic compartmental models, stochastic individual
contact models, and stochastic network models of infectious disease. It
uses exponential-family random graph models (ERGMs) from the Statnet
suite for network-based simulations.

### EpiModelHPC

[EpiModelHPC](https://github.com/EpiModel/EpiModelHPC) extends
slurmworkflow with higher-level, domain-specific step templates for
running EpiModel simulations at scale:

| EpiModelHPC Template                        | Wraps                  | Purpose                                                       |
|---------------------------------------------|------------------------|---------------------------------------------------------------|
| `step_tmpl_renv_restore()`                  | `step_tmpl_bash_lines` | Git pull + `renv::restore()` on HPC                           |
| `step_tmpl_netsim_scenarios()`              | `step_tmpl_map`        | Run network simulations across scenarios as array jobs        |
| `step_tmpl_merge_netsim_scenarios()`        | `step_tmpl_do_call`    | Merge per-batch simulation outputs into one file per scenario |
| `step_tmpl_merge_netsim_scenarios_tibble()` | `step_tmpl_do_call`    | Merge and convert results to tidy tibble format               |
| `step_tmpl_netsim_swfcalib_output()`        | `step_tmpl_map`        | Run simulations using calibrated parameters from swfcalib     |

EpiModelHPC also provides cluster configuration presets
(`swf_configs_rsph()`, `swf_configs_hyak()`) that return ready-made
sbatch options, renv settings, and module-loading lines for specific
HPCs.

### EpiModelHIV-Template Workflow Example

The
[EpiModelHIV-Template](https://github.com/EpiModel/EpiModelHIV-Template)
repo demonstrates how slurmworkflow is used in production HIV research
projects. Each major analysis phase has its own `workflow-*.R` file.
Here is a representative workflow for running intervention scenarios
end-to-end:

``` r
# R/F-intervention_scenarios/workflow-intervention.R (simplified)
library(slurmworkflow)
library(EpiModelHPC)

source("R/shared_variables.R")
source("R/hpc_configs.R")

# Step 1: Create workflow + automatic renv restore step
wf <- make_em_workflow("intervention")

# Step 2: Run intervention scenarios as a massive Slurm array job
wf <- add_workflow_step(
  wf_summary = wf,
  step_tmpl = step_tmpl_netsim_scenarios(
    path_to_est, param, init, control,
    scenarios_list = scenarios_list,
    output_dir = scenarios_dir,
    n_rep = 32,
    n_cores = max_cores,
    max_array_size = 500,
    setup_lines = hpc_node_setup
  ),
  sbatch_opts = list(
    "cpus-per-task" = max_cores,
    "time" = "04:00:00",
    "mem-per-cpu" = "5G"
  )
)

# Step 3: Merge distributed results into tidy tibbles
wf <- add_workflow_step(
  wf_summary = wf,
  step_tmpl = step_tmpl_merge_netsim_scenarios_tibble(
    sim_dir = scenarios_dir,
    output_dir = merged_dir,
    steps_to_keep = Inf,
    setup_lines = hpc_node_setup
  ),
  sbatch_opts = list("mem" = "0", "time" = "04:00:00")
)

# Step 4: Generate result tables
wf <- add_workflow_step(
  wf_summary = wf,
  step_tmpl = step_tmpl_do_call_script(
    r_script = "R/F-intervention_scenarios/4-tables.R",
    args = list(hpc_context = TRUE),
    setup_lines = hpc_node_setup
  ),
  sbatch_opts = list("mem" = "16G", "time" = "01:00:00")
)

# Step 5: Generate plots
wf <- add_workflow_step(
  wf_summary = wf,
  step_tmpl = step_tmpl_do_call_script(
    r_script = "R/F-intervention_scenarios/5-plots.R",
    args = list(hpc_context = TRUE),
    setup_lines = hpc_node_setup
  ),
  sbatch_opts = list("mem" = "16G", "time" = "01:00:00")
)
```

The `make_em_workflow()` helper (defined in the template project) wraps
[`create_workflow()`](https://epimodel.github.io/slurmworkflow/reference/create_workflow.md)
with project defaults and always adds an
`EpiModelHPC::step_tmpl_renv_restore()` as the first step. This pattern
supports two levels of parallelization: Slurm array jobs distribute
scenarios across nodes, while each node runs ~32 simulations in parallel
internally.

Typical workflow pipelines in EpiModelHIV projects:

| Pipeline                   | Steps                                                                              |
|----------------------------|------------------------------------------------------------------------------------|
| **Network estimation**     | renv restore, estimate, diagnostics                                                |
| **Scenario simulations**   | renv restore, netsim scenarios, merge results                                      |
| **Intervention analysis**  | renv restore, netsim scenarios, merge, tables, plots                               |
| **Calibration (swfcalib)** | renv restore, propose params, run batches, evaluate, update, simulate, merge, plot |

## Workflow Directory Structure

When you create a workflow, slurmworkflow generates this directory
structure:

    workflows/my_analysis/
        start_workflow.sh           Entry point — run this on the HPC
        workflow.yaml               Metadata: steps, sbatch options
        log/                        Job stdout/stderr logs
        SWF/
            controller.sh           Chains steps via sbatch dependencies
            step.sh                 Template for step execution
            lib.sh                  Shared bash functions
            steps/
                1/
                    job.sh          Sbatch script with #SBATCH directives
                    instructions.sh Actual commands for this step
                2/
                    ...

## Tested HPCs

- [Emory RSPH HPC](https://sph.emory.edu/research/labs/index.html)
- [UW HYAK HPC](https://hyak.uw.edu/)

Any Slurm-equipped cluster should work.

## Documentation

- [Package
  vignette](https://epimodel.github.io/slurmworkflow/articles/slurmworkflow.html)
  — walkthrough of a 4-step workflow with loops, array jobs, and direct
  function calls
- [Reference
  manual](https://epimodel.github.io/slurmworkflow/reference/) — full
  function documentation

## Related Packages

- [EpiModel](https://github.com/EpiModel/EpiModel) — Mathematical
  modeling of infectious disease dynamics
- [EpiModelHPC](https://github.com/EpiModel/EpiModelHPC) — HPC
  extensions for EpiModel (builds on slurmworkflow)
- [EpiModelHIV-Template](https://github.com/EpiModel/EpiModelHIV-Template)
  — Template for HIV research projects
- [swfcalib](https://github.com/EpiModel/swfcalib) — Automated
  calibration system built on slurmworkflow

## Citation

If you use slurmworkflow in your research, please cite the EpiModel
suite:

> Jenness SM, Goodreau SM, Morris M (2018). “EpiModel: An R Package for
> Mathematical Modeling of Infectious Disease over Networks.” *Journal
> of Statistical Software*, 84(8), 1-47. doi:
> [10.18637/jss.v084.i08](https://doi.org/10.18637/jss.v084.i08)

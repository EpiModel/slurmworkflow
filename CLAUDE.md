# CLAUDE.md — slurmworkflow

## Project Overview

**slurmworkflow** is an R package that builds and manages multi-step
computational workflows on Slurm-equipped HPC systems. It chains
`sbatch` jobs via `--dependency=afterany` so users don’t need persistent
SSH sessions or long-lived daemons.

- **Author:** Adrien Le Guillou
- **License:** MIT
- **Version:** 0.1.0
- **R requirement:** \>= 4.1.0
- **Hard dependencies:** `fs`, `yaml`
- **Docs site:** <https://epimodel.github.io/slurmworkflow/>

## Repository Structure

    R/                    # Package source
      workflow.R          # Core API: create_workflow, add_workflow_step, load_workflow, etc.
      step_templates.R    # All step_tmpl_* functions and helpers
      sbatch_options.R    # Sbatch option validation (150+ valid options)
      wf_summary.R        # Workflow YAML I/O
      dir.R               # Directory creation and template copying
      env-vars.R          # Environment variable mapping
      utils.R             # Template variable substitution (simple_brew)
    inst/
      templates/          # Bash/R template files copied into workflow directories
    tests/testthat/       # Comprehensive test suite
    vignettes/            # Main vignette: slurmworkflow.Rmd
    .github/workflows/    # CI: R-CMD-check, test-coverage, pkgdown

## Key Concepts

- **Workflow** — a named directory (`workflows/<name>/`) containing all
  scripts and metadata to run a sequence of Slurm jobs on an HPC.
- **Step** — a single `sbatch` submission within a workflow. Steps run
  sequentially by default via a controller job that chains them.
- **Step template** — a function factory that defines what a step does.
  The package exports 7 templates: `step_tmpl_bash_lines`,
  `step_tmpl_bash_script`, `step_tmpl_rscript`, `step_tmpl_do_call`,
  `step_tmpl_do_call_script`, `step_tmpl_map`, `step_tmpl_map_script`.
- **Workflow summary** — an in-memory list (serialized as
  `workflow.yaml`) that tracks steps, their sbatch options, and the
  workflow root path.

## Development Commands

``` bash
# Run tests
Rscript -e 'devtools::test()'

# Check package
Rscript -e 'devtools::check()'

# Build documentation
Rscript -e 'devtools::document()'

# Build pkgdown site locally
Rscript -e 'pkgdown::build_site()'
```

## Conventions

- Documentation uses roxygen2 with markdown support (RoxygenNote:
  7.3.2).
- Tests use testthat edition 3.
- Sbatch options use long-form only (e.g., `"job-name"` not `"-J"`).
- The `partition` option is mandatory in `default_sbatch_opts`.
- Step templates are function factories — they return a function that
  receives `instructions_script`, `wf_vars`, and `...`.
- Environment variables prefixed `SWF_` are used for communication
  between the controller and running steps (e.g., `SWF_ROOT`, `SWF_CUR`,
  `SWF_NEXTSTEP_FILE`).

## Ecosystem

This package is a building block in the EpiModel ecosystem: -
**EpiModel** — base package for mathematical modeling of infectious
disease dynamics - **EpiModelHPC** — provides higher-level step
templates (`step_tmpl_netsim_scenarios`,
`step_tmpl_merge_netsim_scenarios_tibble`, `step_tmpl_renv_restore`,
etc.) that wrap slurmworkflow’s base templates -
**EpiModelHIV-Template** — template repo for HIV research projects that
uses slurmworkflow workflows extensively - **swfcalib** — automated
calibration system built on slurmworkflow

# CLAUDE.md — slurmworkflow

## Project overview

**slurmworkflow** builds and controls multi-step computational workflows on
Slurm-equipped high-performance computing (HPC) systems. The R package resolves
workflow designs into `.swf` files; a bash controller chains submissions with
`sbatch --dependency=afterany`. Runtime control is available through the
executable `swf` command and thin R wrappers.

- **Author:** Adrien Le Guillou
- **License:** MIT
- **Version:** 0.2.0
- **R requirement:** >= 4.1.0
- **Hard dependency:** `fs`
- **Documentation:** https://epimodel.github.io/slurmworkflow/

Backward compatibility with 0.1.x workflow directories is intentionally not
supported on this redesign branch.

## Repository structure

```text
R/
  workflow.R          create_workflow, add_workflow_step, load_workflow
  runtime.R           swf wrappers and running-step environment helpers
  swf.R               base-R, atomic .swf reader/writer
  step_templates.R    built-in step template factories
  sbatch_options.R    option validation, reserved and exclusive options
  wf_summary.R        rebuild summaries from workflow/step files
  dir.R               workflow and step directory creation
  env-vars.R          variables supplied to templates at build time
inst/templates/
  workflow/           swf and the bash engine copied into every workflow
  step_tmpl_do_call.R runtime R payload for do-call steps
  step_tmpl_map.R     runtime R payload for array/map steps
tests/testthat/       R unit tests; runtime tests use fake Slurm when installed
design/               dynamic-step design specification and mock files
vignettes/            main user guide
```

## Workflow model

- Root `swf` is the only user and job command entry point. Commands include
  `start`, `stop`, `status`, `log`, `steps`, `runs`, `next`, and `override`.
- Steps are `swf.d/steps/<N>_<name>/`, where `N` is one-based build order and
  names match `^[A-Za-z][A-Za-z0-9_-]*$`.
- `step.swf` is a resolved submission. It contains merged `opt.*`, template
  `data.*`, and optional `next`. An absent `next` means build order; `next=`
  means end. Overrides are one-shot and are resolved by `swf override`.
- `swf.d/workflow.swf` holds defaults and `ctrl.opt.*` controller options.
  `swf.d/sbatch_rules.swf` records valid, exclusive, and reserved sbatch options.
- Summaries contain only `name`, `root`, `default_sbatch_opts`, and `steps`;
  they are rebuilt from files and are never serialized separately.
- Step payloads get `SWF_ROOT`, run/log locations, `SWF_CMD`, `SWF_CUR`,
  `SWF_CUR_NAME`, `SWF__CUR_DIR`, `SWF__INSTRUCTIONS_SCRIPT`, and the exact
  `SWF_SUBMISSION` used by sbatch.

## R conventions

- Keep RoxygenNote at **7.3.2**. Use this repository's renv; do not allow a newer
  global roxygen2 installation to rewrite DESCRIPTION.
- Tests use testthat edition 3.
- Sbatch options use long-form names. `partition` is required at workflow
  creation. `dependency`, `job-name`, `output`, and `parsable` are reserved.
- Templates implement `function(instructions_script, wf_vars, wf_summary,
  sbatch_opts, ...)` and return `NULL`, `list()`, or named `sbatch_opts`/`data`.
- `read_swf()` and `write_swf()` are base R and internal. Values are verbatim,
  not shell quoted; reject newlines, malformed keys, duplicate keys, and bad
  headers. Writers use a same-directory temporary file followed by rename.
- Write integral numbers without scientific notation. Runtime wrappers call
  `system2(cmd, shQuote(args), stdout = TRUE, stderr = TRUE)` and error on a
  non-zero status.
- Map runtime state comes from `data.map.*` in `SWF_SUBMISSION`; do not restore
  `SWF__ARRAY_OFFSET` or map-specific `--export` options.

## Development commands

From the workspace root, R is provided by pixi and the project renv supplies
roxygen2:

```bash
pixi run bash -c 'cd slurmworkflow && Rscript -e "devtools::document()"'
pixi run bash -c 'cd slurmworkflow && NOT_CRAN=true Rscript -e "devtools::test()"'
pixi run bash -c 'cd slurmworkflow && Rscript -e "devtools::check(document = FALSE, args = \"--no-manual\", error_on = \"never\")"'
pixi run bash -c 'cd slurmworkflow && Rscript -e "pkgdown::build_site()"'
```

Do not edit generated `NAMESPACE` or `man/*.Rd` by hand; regenerate them with
`devtools::document()`.

## Ecosystem

- **EpiModelHPC** provides higher-level templates wrapping these base templates.
- **EpiModelHIV-Template** builds production research workflows with this API.
- **swfcalib** uses static calibration loops and dynamic one-shot map overrides.

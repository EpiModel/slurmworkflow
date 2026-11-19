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
- **Hard dependencies:** none (base R only)
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
  `start`, `stop`, `status`, `log`, `steps`, `runs`, `next`, `override`, and
  `check` (run by `start`).
- Steps are `swf.d/steps/<N>_<name>/`, where `N` is one-based build order
  (exactly `1..N`) and names match `^[A-Za-z][A-Za-z0-9_-]*$` (at most 64
  characters). Workflow names match `^[A-Za-z][A-Za-z0-9._-]*$`.
- `step.swf` is a resolved submission. It contains merged `opt.*`, template
  `data.*`, optional `next`, and optional `on_failure=continue`. An absent `next` means build order; `next=`
  means end. Overrides are one-shot and are resolved by `swf override`.
- A failed step (any `failed/` marker of its job) stops the run with
  `event=error reason=step_failed:<N>_<name>` unless its submission has
  `on_failure=continue`.
- `swf.d/workflow.swf` holds builder defaults (`opt.*`, never read at run time)
  and `ctrl.opt.*` controller options (with `mail-user`, also
  `ctrl.opt.mail-type=FAIL`).
  `swf.d/sbatch_rules.swf` records valid, exclusive, and reserved sbatch options.
- Summaries contain only `name`, `root`, `default_sbatch_opts`, and `steps`
  (each with `number`, `name`, `next`, `sbatch_opts`, `data`, `on_failure`);
  they are rebuilt from files and are never serialized separately. 0.1.x
  directories (`workflow.yaml`, `start_workflow.sh`) are refused.
- Step payloads get `SWF_ROOT`, run/log locations, `SWF_CMD`, `SWF_CUR`,
  `SWF_CUR_NAME`, `SWF__CUR_DIR`, `SWF__INSTRUCTIONS_SCRIPT`, and the exact
  `SWF_SUBMISSION` used by sbatch.

## R conventions

- Keep RoxygenNote at **7.3.2**. Use this repository's renv; do not allow a newer
  global roxygen2 installation to rewrite DESCRIPTION.
- Tests use testthat edition 3.
- Sbatch options use long-form names. `partition` is required at workflow
  creation. `dependency`, `job-name`, `output`, `parsable`, `export`, and
  `export-file` are reserved. Duplicate names are refused. A template option
  that differs from a user option of the same name is an error.
- Templates implement `function(instructions_script, wf_vars, wf_summary,
  sbatch_opts, ...)` and return `NULL`, `list()`, or named `sbatch_opts`/`data`.
- `read_swf()` and `write_swf()` are base R and internal. Values are verbatim,
  not shell quoted; reject newlines, malformed keys, duplicate keys, and bad
  headers. Writers use a same-directory temporary file followed by rename.
- `format_swf_value(value, key)` accepts only length-1 non-missing character or
  numeric values (no logical, factor, list, Date); `opt.*` values must not be
  empty. Write integral numbers without scientific notation. Runtime wrappers call
  `system2(cmd, shQuote(args), stdout = TRUE, stderr = TRUE)` and error on a
  non-zero status.
- Map runtime state comes from `data.map.*` in `SWF_SUBMISSION`; do not restore
  `SWF__ARRAY_OFFSET` or map-specific `--export` options. Positions are 0-based
  (`pos = offset + SLURM_ARRAY_TASK_ID`, item `pos + 1`); the runtime validates
  the map data and the array against the expected slice before running `FUN`.
  `array_throttle` adds `%k` to every array of the step.
- `design/wrapper-contract.md` is the contract for wrappers and the engine;
  keep it in sync with behaviour changes.

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

### What is tested where

Building a workflow is pure R and runs everywhere. Only the engine (`swf`,
`swf.d/*.sh`) needs `/bin/bash` >= 4.2 (its shebang is `#!/bin/bash`; a bash
on the `PATH` does not help). Skip rules live in `tests/testthat/helper-platform.R`.

| Test group | Linux | macOS | Windows |
|---|---|---|---|
| R unit tests (builder, `.swf` files, sbatch options) | yes | yes | yes, minus checks that need Unix permissions (`skip_if_no_posix_perms()`) |
| Tests that run the engine (end-to-end, engine suite; `skip_if_no_engine_bash()`) | yes | only if `/bin/bash` >= 4.2 (never on stock macOS) | no |
| "Old bash is refused clearly" (`test-runtime-engine.R`) | no | yes (stock bash 3.2) | no |
| `tests/runtime/test-engine.sh`, plain and `BASH_COMPAT=4.2` (CI job `engine`) | yes | no | no |
| `tests/runtime/test-engine.sh` on a real bash 4.2 (CI job `engine-bash42`, Docker `bash:4.2`) | yes | no | no |

## Ecosystem

- **EpiModelHPC** provides higher-level templates wrapping these base templates.
- **EpiModelHIV-Template** builds production research workflows with this API.
- **swfcalib** uses static calibration loops and dynamic one-shot map overrides.

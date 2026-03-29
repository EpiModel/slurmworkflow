# Add a Step to an Existing Workflow

Add a Step to an Existing Workflow

## Usage

``` r
add_workflow_step(wf_summary, step_tmpl, sbatch_opts = NULL, step_name = NULL)
```

## Arguments

- wf_summary:

  The workflow summary object

- step_tmpl:

  A step template function, see the Step Template section for details.

- sbatch_opts:

  A named list of sbatch options to overwrite or complement the default
  ones (default = NULL). (see the SBATCH Options section for details).

- step_name:

  An optional name for the step

## Value

The updated workflow summary

## Step Template

A step template is a [function
factory](https://adv-r.hadley.nz/function-factories.html) used to
simplify the setup of a step. The `slurmworkflow` package provides
several simple ones like `step_tmpl_bash_script` that takes a bash
script to be run as argument or `step_tmpl_r_script` that takes an R
script to be run as argument with an optional `setup_script` to load the
required modules beforehand.

## SBATCH Options

The `sbatch_opts` named list accepts all existing arguments to sbatch.
It only works with the long form (e.g. "job-name" instead of "J"). The
full list of arguments is available in the [sbacth
documentation](https://slurm.schedmd.com/sbatch.html). Some arguments
like "mem", "mem-per-cpu" and "mem-per-gpu" are mutually exclusive,
providing multiple of them will result in an error. However, if one is
set at the creation of the workflow in `default_sbatch_opts` (e.g.
"mem") and another at the addition of a step in `sbatch_opts` (e.g.
"mem-per-gpu"), the second one will be used.

## Examples

``` r
if (FALSE) { # \dontrun{
wf <- add_workflow_step(
  step_tmpl_r_script(r_script = "R/abce-abc.R", setup_script = "loadR.sh"),
  sbatch_opts = list(
    "mem-per-cpu" = "4G",
    "cpus-per-task" = 28,
    "time" = 500
  ),
  step_name = "abc"
)
} # }
```

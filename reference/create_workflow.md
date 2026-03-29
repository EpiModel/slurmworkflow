# Create a New Workflow

Create a new workflow, set up it's directory and return its summary
object

## Usage

``` r
create_workflow(wf_name, default_sbatch_opts, wf_common_dir = "workflows")
```

## Arguments

- wf_name:

  Name of the new workflow

- default_sbatch_opts:

  A named list of default sbatch options for the workflow. The
  "partition" options is mandatory. (see the SBATCH Options section for
  details).

- wf_common_dir:

  Path to the directory where to store the workflows (default =
  "workflows").

## Value

The new workflow summary

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
wf <- create_workflow(
  wf_name = "dummy-workflow",
  default_sbatch_opts = list(
    "partition" = "dummy_part",
    "account" = "dummy_account"
  ),
  wf_common_dir = "workflows"
)
} # }
```

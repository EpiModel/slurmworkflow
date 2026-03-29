# Step Template to Run an R Function With a Set of Arguments

This step template uses a syntax similar to the
[`base::Map`](https://rdrr.io/r/base/funprog.html) /
[`base::mapply`](https://rdrr.io/r/base/mapply.html) functions to run a
function with a given set of arguments as a workflow step. You must make
sure that all variables required by the function are passed to it either
as one of its arguments or loaded later by the function itself.

## Usage

``` r
step_tmpl_map(
  FUN,
  ...,
  MoreArgs = NULL,
  setup_lines = NULL,
  max_array_size = Inf
)
```

## Arguments

- FUN:

  The R function to be run by the workflow step

- ...:

  arguments to vectorize over (vectors or lists of strictly positive
  length, or all of zero length). See also ‘Details’.

- MoreArgs:

  a `list` of arguments to the function call. The *names* attribute of
  `args` gives the argument names.

- setup_lines:

  (optional) a vector of bash lines to be run first. This can be used to
  load the required modules (like R, python, etc).

- max_array_size:

  maximum number of array jobs to be submitted at once. It should be
  strictly less than the maximum number of jobs you are allowed to
  submit to `slurm` on your HPC. If the number of jobs is greater than
  `max_array_size`, they will be submitted in multiple batches. The
  submission of the next batch is automatically handled by
  `slurmworkflow`.

## Value

a template function to be used by `add_workflow_step`

## Step Template

Step Templates are helper functions to be used within
`add_workflow_step`. Some basic ones are provided by the `slurmworkflow`
package. They instruct the workflow to run either a bash script, a set
of bash lines given as a character vector or an R script. Additional
Step Templates can be created to simplify specific tasks. The easiest
way to do so is as wrappers around existing templates.

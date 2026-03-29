# Step Template to Run an R Function

This step template uses a syntax similar to the
[`base::do.call`](https://rdrr.io/r/base/do.call.html) function to run a
function as a workflow step. You must make sure that all variables
required by the function are passed to it either as one of its arguments
or loaded later by the function itself.

## Usage

``` r
step_tmpl_do_call(what, args, setup_lines = NULL)
```

## Arguments

- what:

  The R function to be run by the workflow step

- args:

  a *list* of arguments to the function call. The `names` attribute of
  `args` gives the argument names.

- setup_lines:

  (optional) a vector of bash lines to be run first. This can be used to
  load the required modules (like R, python, etc).

## Value

a template function to be used by `add_workflow_step`

## Step Template

Step Templates are helper functions to be used within
`add_workflow_step`. Some basic ones are provided by the `slurmworkflow`
package. They instruct the workflow to run either a bash script, a set
of bash lines given as a character vector or an R script. Additional
Step Templates can be created to simplify specific tasks. The easiest
way to do so is as wrappers around existing templates.

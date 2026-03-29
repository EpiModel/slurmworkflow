# Step Template to Run an R Script With a Set of Arguments

Step Template to Run an R Script With a Set of Arguments

## Usage

``` r
step_tmpl_map_script(r_script, ..., MoreArgs = NULL, setup_lines = NULL)
```

## Arguments

- r_script:

  The R script to be run by the workflow step

- ...:

  arguments to vectorize over (vectors or lists of strictly positive
  length, or all of zero length). See also ‘Details’.

- MoreArgs:

  a `list` of arguments to the function call. The *names* attribute of
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

# Step Template to Run an R Script

Contrary to `step_tmpl_do_call_script`, this function copies the content
of the script to the workflow folder. Therefore, the script do not have
to exist on the HPC when using this template.

## Usage

``` r
step_tmpl_rscript(r_script, setup_lines = NULL)
```

## Arguments

- r_script:

  The R script to be run by the workflow step

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

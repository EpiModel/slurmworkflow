# Step Template to Run Bash Statements

Step Template to Run Bash Statements

## Usage

``` r
step_tmpl_bash_lines(bash_lines)
```

## Arguments

- bash_lines:

  Vector of bash lines to be run by the workflow step

## Value

a template function to be used by `add_workflow_step`

## Step Template

Step Templates are helper functions to be used within
`add_workflow_step`. Some basic ones are provided by the `slurmworkflow`
package. They instruct the workflow to run either a bash script, a set
of bash lines given as a character vector or an R script. Additional
Step Templates can be created to simplify specific tasks. The easiest
way to do so is as wrappers around existing templates.

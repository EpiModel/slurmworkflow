# Alter the Next Step of a Running Workflow

This function allows a running job to alter the workflow sequence by
choosing which step to run after the current one.

## Usage

``` r
change_next_workflow_step(next_step, sbatch_opts = NULL)
```

## Arguments

- next_step:

  A scalar number coercible to integer instructing the workflow system
  which step to run next

- sbatch_opts:

  an optional named list of sbatch parameters that would override the
  ones specified by the `next_step` for the next iteration

## Value

The `next_step` value (invisibly)

## Examples

``` r
if (FALSE) { # \dontrun{
 # Instruct the workflow to run the step 3 after this one
 change_next_workflow_step(3)

 # Instruct the workflow to run the previous step after this one
 change_next_workflow_step(get_current_workflow_step() - 1)
} # }
```

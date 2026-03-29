# Get the Root Directory of a Workflow

This function will get the path to the root directory of a workflow.
Either a local workflow or during the execution of a workflow on an HPC

## Usage

``` r
get_workflow_root(wf_summary = NULL)
```

## Arguments

- wf_summary:

  The workflow summary returned after it's creation or obtained with
  `swf_load_workflow`. If not provided, the function assumes that the
  workflow is running on an HPC and pulls the value using environment
  variables.

## Value

The path to the workflow root directory

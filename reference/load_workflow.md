# Load a Workflow Summary From a Workflow Folder or the Environment

Load a Workflow Summary From a Workflow Folder or the Environment

## Usage

``` r
load_workflow(wf_root = NULL)
```

## Arguments

- wf_root:

  Path to a workflow directory. If not provided, the function assumes
  that the workflow is running on an HPC and pulls the value using
  environment variables.

## Value

The workflow summary

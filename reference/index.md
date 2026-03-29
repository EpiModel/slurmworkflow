# Package index

## Workflow Creation

Functions to create and edit a workflow

- [`create_workflow()`](https://epimodel.github.io/slurmworkflow/reference/create_workflow.md)
  : Create a New Workflow
- [`add_workflow_step()`](https://epimodel.github.io/slurmworkflow/reference/add_workflow_step.md)
  : Add a Step to an Existing Workflow

## Step Templates

Functions governing what is run by a step.

- [`step_tmpl_bash_lines()`](https://epimodel.github.io/slurmworkflow/reference/step_tmpl_bash_lines.md)
  : Step Template to Run Bash Statements
- [`step_tmpl_bash_script()`](https://epimodel.github.io/slurmworkflow/reference/step_tmpl_bash_script.md)
  : Step Template to Run a Bash Script
- [`step_tmpl_do_call()`](https://epimodel.github.io/slurmworkflow/reference/step_tmpl_do_call.md)
  : Step Template to Run an R Function
- [`step_tmpl_do_call_script()`](https://epimodel.github.io/slurmworkflow/reference/step_tmpl_do_call_script.md)
  : Step Template to Run an R Script With a Set of Arguments
- [`step_tmpl_map()`](https://epimodel.github.io/slurmworkflow/reference/step_tmpl_map.md)
  : Step Template to Run an R Function With a Set of Arguments
- [`step_tmpl_map_script()`](https://epimodel.github.io/slurmworkflow/reference/step_tmpl_map_script.md)
  : Step Template to Run an R Script With a Set of Arguments
- [`step_tmpl_rscript()`](https://epimodel.github.io/slurmworkflow/reference/step_tmpl_rscript.md)
  : Step Template to Run an R Script

## Changing the Execution Order

Functions to query the currently running step and change the step to be
run next. These functions are to be used inside a workflow running on an
HPC. They allow conditional execution and loop like behavior.

- [`change_next_workflow_step()`](https://epimodel.github.io/slurmworkflow/reference/change_next_workflow_step.md)
  : Alter the Next Step of a Running Workflow
- [`get_current_workflow_step()`](https://epimodel.github.io/slurmworkflow/reference/get_current_workflow_step.md)
  : Get the Number of the Currently Running Step of a Workflow

## Utilities for Making Custom Step Templates

Functions used to create custom step templates from scratch. In most
case, a new step template can be created as a wrapper around one of the
existing templates.

- [`get_workflow_root()`](https://epimodel.github.io/slurmworkflow/reference/get_workflow_root.md)
  : Get the Root Directory of a Workflow
- [`load_workflow()`](https://epimodel.github.io/slurmworkflow/reference/load_workflow.md)
  : Load a Workflow Summary From a Workflow Folder or the Environment
- [`helper_use_setup_lines()`](https://epimodel.github.io/slurmworkflow/reference/helper_use_setup_lines.md)
  : Helper Function to Consistently Write Setup Lines
- [`helper_write_instructions()`](https://epimodel.github.io/slurmworkflow/reference/helper_write_instructions.md)
  : Helper Function to Consistently Write Instructions to the
  Instruction Script

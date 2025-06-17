#' Create a New Workflow
#'
#' Create a new workflow, set up it's directory and return its summary object
#'
#' @param wf_name Name of the new workflow
#' @param default_sbatch_opts A named list of default sbatch options for the
#'   workflow. The "partition" options is mandatory.
#'   (see the SBATCH Options section for details).
#' @param wf_common_dir Path to the directory where to store the workflows
#'   (default = "workflows").
#'
#' @return The new workflow summary
#'
#' @section SBATCH Options:
#' The `sbatch_opts` named list accepts all existing arguments to sbatch. It
#' only works with the long form (e.g. "job-name" instead of "J"). The full list
#' of arguments is available in the
#' [sbacth documentation](https://slurm.schedmd.com/sbatch.html). Some arguments
#' like "mem", "mem-per-cpu" and "mem-per-gpu" are mutually exclusive, providing
#' multiple of them will result in an error. However, if one is set at the
#' creation of the workflow in `default_sbatch_opts` (e.g. "mem") and another
#' at the addition of a step in `sbatch_opts` (e.g. "mem-per-gpu"), the second
#' one will be used.
#'
#' @examples
#' \dontrun{
#' wf <- create_workflow(
#'   wf_name = "dummy-workflow",
#'   default_sbatch_opts = list(
#'     "partition" = "dummy_part",
#'     "account" = "dummy_account"
#'   ),
#'   wf_common_dir = "workflows"
#' )
#' }
#'
#' @export
create_workflow <- function(wf_name, default_sbatch_opts,
                            wf_common_dir = "workflows") {
  sbatch_opts <- validate_sbatch_opts(default_sbatch_opts)
  if (!"partition" %in% sbatch_opts)
    stop("A `partition` option must be defined in `default_sbatch_opts`")
  wf_summary <- new_summary(fs::path(wf_common_dir, wf_name), sbatch_opts)
  create_wf_dir(wf_summary)
  wf_summary
}

#' Add a Step to an Existing Workflow
#'
#' @param wf_summary The workflow summary object
#' @param step_tmpl A step template function, see the Step Template section for
#'   details.
#' @param sbatch_opts A named list of sbatch options to overwrite or complement
#'   the default ones (default = NULL). (see the SBATCH Options section for
#'   details).
#' @param step_name An optional name for the step
#'
#' @return The updated workflow summary
#'
#' @section Step Template:
#' A step template is a
#' [function factory](https://adv-r.hadley.nz/function-factories.html) used to
#' simplify the setup of a step. The `slurmworkflow` package provides several
#' simple ones like `step_tmpl_bash_script` that takes a bash script to be run
#' as argument or `step_tmpl_r_script` that takes an R script to be run as
#' argument with an optional `setup_script` to load the required modules
#' beforehand.
#'
#' @inheritSection create_workflow SBATCH Options
#'
#' @examples
#' \dontrun{
#' wf <- add_workflow_step(
#'   step_tmpl_r_script(r_script = "R/abce-abc.R", setup_script = "loadR.sh"),
#'   sbatch_opts = list(
#'     "mem-per-cpu" = "4G",
#'     "cpus-per-task" = 28,
#'     "time" = 500
#'   ),
#'   step_name = "abc"
#' )
#' }
#'
#' @export
add_workflow_step <- function(wf_summary, step_tmpl,
                              sbatch_opts = NULL, step_name = NULL) {
  wf_summary <- load_workflow(wf_summary[["root"]])
  sbatch_opts <- update_sbatch_opts(
    wf_summary[["default_sbatch_opts"]],
    sbatch_opts
  )
  wf_summary <- add_summary_step(wf_summary, sbatch_opts, step_name)
  create_step_dir(wf_summary, step_tmpl)
  wf_summary
}

#' Load a Workflow Summary From a Workflow Folder or the Environment
#'
#' @param wf_root Path to a workflow directory. If not provided, the function
#'   assumes that the workflow is running on an HPC and pulls the value using
#'   environment variables.
#'
#' @return The workflow summary
#'
#' @export
load_workflow <- function(wf_root = NULL) {
  wf_root <- if (is.null(wf_root)) Sys.getenv("SWF_ROOT") else wf_root
  wf_summary_path <- fs::path(wf_root, "workflow.yaml")
  read_summary(wf_summary_path)
}

#' Get the Root Directory of a Workflow
#'
#' This function will get the path to the root directory of a workflow. Either
#' a local workflow or during the execution of a workflow on an HPC
#'
#' @param wf_summary The workflow summary returned after it's creation or
#'   obtained with `swf_load_workflow`. If not provided, the function assumes
#'   that the workflow is running on an HPC and pulls the value using
#'   environment variables.
#'
#' @return The path to the workflow root directory
#'
#' @export
get_workflow_root <- function(wf_summary = NULL) {
  if (is.null(wf_summary)) {
    wf_root <- Sys.getenv("SWF_ROOT")
    if (wf_root == "") {
      stop(
        "The environment variable 'SWF_ROOT' is empty.\n",
        "Make sure a workflow is currently running."
      )
    }
  } else {
    wf_root <- wf_summary[["root"]]
  }
  wf_root
}

#' Alter the Next Step of a Running Workflow
#'
#' This function allows a running job to alter the workflow sequence by choosing
#' which step to run after the current one.
#'
#' @param next_step A scalar number coercible to integer instructing the
#'   workflow system which step to run next
#'
#' @param sbatch_opts an optional named list of sbatch parameters that would
#' override the ones specified by the `next_step` for the next iteration
#'
#' @return The `next_step` value (invisibly)
#'
#' @examples
#' \dontrun{
#'  # Instruct the workflow to run the step 3 after this one
#'  change_next_workflow_step(3)
#'
#'  # Instruct the workflow to run the previous step after this one
#'  change_next_workflow_step(get_current_workflow_step() - 1)
#' }
#'
#' @export
change_next_workflow_step <- function(next_step, sbatch_opts = NULL) {
  next_step_file <- Sys.getenv("SWF_NEXTSTEP_FILE")
  if (next_step_file == "") {
    stop(
      "The environment variable 'SWF_NEXTSTEP_FILE' is empty.\n",
      "Make sure you are in running workflow"
    )
  }

  if (fs::file_exists(next_step_file)) {
    warning(
      "The nextstep file already exists.\n",
      "Deleting it and writting the new value: ", next_step
    )
    fs::file_delete(next_step_file)
  }

  next_step <- as.integer(next_step)
  if (is.na(next_step) || length(next_step) != 1) {
    stop("`next_step` must be an integer of length 1")
  }

  # Next step new options
  if (!is.null(sbatch_opts)) {
    next_step_opts_file <- Sys.getenv("SWF_NEXTSTEP_OPTS_FILE")
    if (fs::file_exists(next_step_opts_file)) {
      warning(
        "The nextstep options file already exists.\n",
        "Deleting it and writting the new values: \n ", sbatch_opts
      )
      fs::file_delete(next_step_opts_file)
    }
    next_step_opts <- make_sbatch_statement(sbatch_opts)
    writeLines(as.character(next_step_opts), next_step_opts_file)
  }

  writeLines(as.character(next_step), next_step_file)
  message("The next workflow step was changed to ", next_step)
  invisible(next_step)
}

#' Get the Number of the Currently Running Step of a Workflow
#'
#' @return The `current_step` value
#'
#' @export
get_current_workflow_step <- function() {
  as.numeric(Sys.getenv("SWF_CUR"))
}

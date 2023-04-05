# This file defines a set of step tmplate functions:
# req args: instructions_script, ...
# optional: wf_summary, wf_vars, sbatch_opts
#
# A template returns a list of `sbatch_opts` to change the ones set by the user.
# This allows the `map` template to work
#
# A template main role is to write the instructions into `instructions_script`.
# If other things are necessary, they should be added into the step folder
# `wf_vars[["SWF__CUR_DIR"]]`

#' Step Template to Run Bash Statements
#'
#' @param bash_lines Vector of bash lines to be run by the workflow step
#'
#' @return a template function to be used by `add_workflow_step`
#'
#' @section Step Template:
#' Step Templates are helper functions to be used within `add_workflow_step`.
#' Some basic ones are provided by the `slurmworkflow` package. They instruct
#' the workflow to run either a bash script, a set of bash lines given as a
#' character vector or an R script.
#' Additional Step Templates can be created to simplify specific tasks, see the
#' `vignette("making-a-custom-step-template")` for details.
#'
#' @export
step_tmpl_bash_lines <- function(bash_lines) {
  function(instructions_script, ...) {
    helper_write_instructions(bash_lines, instructions_script)
    list()
  }
}

#' Helper Function to Consistently Write Instructions to the Instruction Script
#'
#' @param instructions Vector of bash lines to be run by the workflow step
#' @param instructions_script Path to the instructions script
#'
#' @export
helper_write_instructions <- function(instructions, instructions_script) {
  writeLines(instructions, instructions_script, sep = "\n")
}

#' Step Template to Run a Bash Script
#'
#' @param bash_script Path to the script to be run by the workflow step
#'
#' @inherit step_tmpl_bash_lines return
#' @inheritSection step_tmpl_bash_lines Step Template
#'
#' @export
step_tmpl_bash_script <- function(bash_script) {
  step_tmpl_bash_lines(readLines(bash_script))
}

#' Step Template to Run an R Script
#'
#' Contrary to `step_tmpl_do_call_script`, this function copies the content of
#' the script to the workflow folder. Therefore, the script do not have to exist
#' on the HPC when using this template.
#'
#' @param r_script The R script to be run by the workflow step
#' @param setup_lines (optional) a vector of bash lines to be run first.
#'   This can be used to load the required modules (like R, python, etc).
#'
#' @inherit step_tmpl_bash_lines return
#' @inheritSection step_tmpl_bash_lines Step Template
#' @export
step_tmpl_rscript <- function(r_script, setup_lines = NULL) {
  function(instructions_script, wf_vars, ...) {
    step_dir <- wf_vars[["SWF__CUR_DIR"]]
    r_script <- fs::file_copy(r_script, fs::path(step_dir, "script.R"))
    instructions <- paste0("Rscript \"", r_script, "\"")
    instructions <- helper_use_setup_lines(instructions, setup_lines)
    helper_write_instructions(instructions, instructions_script)
    list()
  }
}

#' Helper Function to Consistently Write Setup Lines
#'
#' @param instructions Vector of bash lines to be run by the workflow step
#' @param setup_lines Vector of bash lines to be run before the rest of the
#'   step instructions.
#'
#'  @return The modified instructions
#'
#' @export
helper_use_setup_lines <- function(instructions, setup_lines) {
  if (!is.null(setup_lines))
    instructions <- c(setup_lines, instructions)
  instructions
}

#' Step Template to Run an R Function
#'
#' This step template uses a syntax similar to the `base::do.call` function to
#' run a function as a workflow step. You must make sure that all variables
#' required by the function are passed to it either as one of its arguments or
#' loaded later by the function itself.
#'
#' @param what The R function to be run by the workflow step
#' @param args a *list* of arguments to the function call. The `names`
#'    attribute of `args` gives the argument names.
#'
#' @inheritParams step_tmpl_rscript
#' @inherit step_tmpl_rscript return
#' @inheritSection step_tmpl_bash_lines Step Template
#' @export
step_tmpl_do_call <- function(what, args, setup_lines = NULL) {

  do_call_data <- list(what = what, args = args)

  function(instructions_script, wf_vars, ...) {
    step_dir <- wf_vars[["SWF__CUR_DIR"]]

    r_script <- fs::path(get_templates_dir(), "step_tmpl_do_call.R")
    r_script <- fs::file_copy(r_script, fs::path(step_dir, "script.R"))
    instructions <- paste0("Rscript \"", r_script, "\"")
    instructions <- helper_use_setup_lines(instructions, setup_lines)

    saveRDS(do_call_data, fs::path(step_dir, "do_call.rds"))

    helper_write_instructions(instructions, instructions_script)
    list()
  }
}

#' Step Template to Run an R Function With a Set of Arguments
#'
#' This step template uses a syntax similar to the `base::Map` / `base::mapply`
#' functions to run a function with a given set of arguments as a workflow step.
#' You must make sure that all variables required by the function are passed to
#' it either as one of its arguments or loaded later by the function itself.
#'
#' @param FUN The R function to be run by the workflow step
#' @param ... arguments to vectorize over (vectors or lists of strictly
#'   positive length, or all of zero length).  See also ‘Details’.
#' @param MoreArgs a `list` of arguments to the function call. The *names*
#'   attribute of `args` gives the argument names.
#' @param max_array_size maximum number of array jobs to be submitted at the
#'   same time. Should be strictly less than the maximum number of jobs you are
#'   allowed to submit to slurm on your HPC.
#'
#' @inheritParams step_tmpl_do_call
#' @inherit step_tmpl_rscript return
#' @inheritSection step_tmpl_bash_lines Step Template
#' @export
step_tmpl_map <- function(FUN, ..., MoreArgs = NULL, setup_lines = NULL,
                          max_array_size = Inf) {
  dots <- list(...)
  n_iter <- unique(vapply(dots, length, 0))
  if (length(n_iter) > 1)
    stop("All the vectors in `...` must be of the same length")
  array_size <- min(max_array_size, n_iter) - 1

  map_data <- list(
    FUN = FUN, dots = dots, MoreArgs = MoreArgs,
    array_size = array_size
  )

  function(instructions_script, wf_vars, ...) {
    step_dir <- wf_vars[["SWF__CUR_DIR"]]

    r_script <- fs::path(get_templates_dir(), "step_tmpl_map.R")
    r_script <- fs::file_copy(r_script, fs::path(step_dir, "script.R"))
    instructions <- paste0("Rscript \"", r_script, "\"")
    instructions <- helper_use_setup_lines(instructions, setup_lines)

    saveRDS(map_data, fs::path(step_dir, "map.rds"))

    helper_write_instructions(instructions, instructions_script)
    list(
      "array" = paste0("0-", array_size),
      "export" = "SWF__ARRAY_OFFSET=1"
    )
  }
}

#' Step Template to Run an R Script With a Set of Arguments
#'
#' @inheritParams step_tmpl_rscript
#' @inheritParams step_tmpl_do_call
#' @inherit step_tmpl_rscript return
#' @inheritSection step_tmpl_bash_lines Step Template
#' @export
step_tmpl_do_call_script <- function(r_script, args = list(),
                                     setup_lines = NULL) {
  f <- function(with_args)  with(with_args, source(r_script, local = TRUE))
  step_tmpl_do_call(
    what = f,
    args = list(with_args = args),
    setup_lines = setup_lines
  )
}

#' Step Template to Run an R Script With a Set of Arguments
#'
#' @inheritParams step_tmpl_rscript
#' @inheritParams step_tmpl_map
#' @inherit step_tmpl_rscript return
#' @inheritSection step_tmpl_bash_lines Step Template
#' @export
step_tmpl_map_script <- function(r_script, ..., MoreArgs = NULL,
                                 setup_lines = NULL) {
  f <- function(...)  with(list(...), source(r_script, local = TRUE))
  step_tmpl_map(FUN = f, ..., MoreArgs = MoreArgs, setup_lines = setup_lines)
}

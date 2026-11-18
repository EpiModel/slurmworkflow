#' Create a New Workflow
#'
#' Create a workflow directory containing the `swf` command, the bash engine,
#' and the resolved SWF configuration files.
#'
#' @param wf_name Name of the new workflow.
#' @param default_sbatch_opts A named list of default sbatch options for the
#'   workflow. The `partition` option is mandatory. Options `dependency`,
#'   `job-name`, `output`, and `parsable` are managed by the engine and refused.
#' @param wf_common_dir Path to the directory where workflows are stored.
#'
#' @return The new workflow summary, rebuilt from the generated files.
#'
#' @section SBATCH Options:
#' Use sbatch long option names (for example, `job-name`, not `J`). Options set
#' on a step replace workflow defaults. Setting one option in an exclusive group,
#' such as `mem-per-cpu`, removes the other options in that group from the
#' resolved submission. Values are written verbatim to the `.swf` files.
#'
#' @examples
#' \dontrun{
#' wf <- create_workflow(
#'   wf_name = "my-analysis",
#'   default_sbatch_opts = list(partition = "compute", account = "project")
#' )
#' }
#'
#' @export
create_workflow <- function(wf_name, default_sbatch_opts,
                            wf_common_dir = "workflows") {
  sbatch_opts <- validate_sbatch_opts(default_sbatch_opts)
  if (!"partition" %in% names(sbatch_opts)) {
    stop("A `partition` option must be defined in `default_sbatch_opts`",
         call. = FALSE)
  }

  wf_summary <- new_summary(fs::path(wf_common_dir, wf_name), sbatch_opts)
  create_wf_dir(wf_summary)
  swf_dir <- fs::path(wf_summary[["root"]], "swf.d")

  workflow_values <- list()
  workflow_values[names(sbatch_opts)] <- sbatch_opts
  names(workflow_values) <- paste0("opt.", names(sbatch_opts))
  controller_opts <- intersect(c("partition", "account"), names(sbatch_opts))
  for (option in controller_opts) {
    workflow_values[[paste0("ctrl.opt.", option)]] <- sbatch_opts[[option]]
  }
  write_swf(workflow_values, fs::path(swf_dir, "workflow.swf"))

  exclusive <- get_exclusive_sbatch_opts()
  rules <- stats::setNames(
    lapply(exclusive, paste, collapse = " "),
    paste0("exclusive.", names(exclusive))
  )
  rules[["valid"]] <- paste(get_sbatch_opts_list(), collapse = " ")
  rules[["reserved"]] <- paste(get_reserved_sbatch_opts(), collapse = " ")
  write_swf(rules, fs::path(swf_dir, "sbatch_rules.swf"))

  load_workflow(wf_summary[["root"]])
}

#' Add a Step to an Existing Workflow
#'
#' The step is stored as `swf.d/steps/<N>_<name>/`. Its `step.swf` contains the
#' fully resolved options, template data, and an optional static successor.
#'
#' @param wf_summary The workflow summary.
#' @param step_tmpl A step template function. See the Step Template section.
#' @param sbatch_opts A named list of sbatch options that replace or complement
#'   the workflow defaults.
#' @param step_name A unique step name matching
#'   `^[A-Za-z][A-Za-z0-9_-]*$`. Defaults to `step_<N>`.
#' @param next_step The step to run after this one: a step name (which may be
#'   added later), the number of an existing step, or `NA`/`""` to end the
#'   workflow. `NULL` (the default) uses the following step in build order.
#'
#' @return The updated workflow summary, rebuilt from files.
#'
#' @section Step Template:
#' A step template is a function with signature `function(instructions_script,
#' wf_vars, wf_summary, sbatch_opts, ...)`. It writes the files needed by the
#' step and returns `NULL`, `list()`, or a list containing optional named
#' `sbatch_opts` and `data` lists. Data names are flat; `map.total` is written
#' as `data.map.total` in `step.swf`.
#'
#' @inheritSection create_workflow SBATCH Options
#'
#' @examples
#' \dontrun{
#' wf <- add_workflow_step(
#'   wf,
#'   step_tmpl_bash_lines(c("module load R", "Rscript analysis.R")),
#'   sbatch_opts = list(mem = "8G", time = 60),
#'   step_name = "analysis",
#'   next_step = NA
#' )
#' }
#'
#' @export
add_workflow_step <- function(wf_summary, step_tmpl,
                              sbatch_opts = NULL, step_name = NULL,
                              next_step = NULL) {
  wf_summary <- load_workflow(wf_summary[["root"]])
  number <- length(wf_summary[["steps"]]) + 1L
  if (is.null(step_name)) {
    step_name <- paste0("step_", number)
  }
  validate_step_name(step_name)
  existing_names <- vapply(
    wf_summary[["steps"]], function(x) x[["name"]], character(1L)
  )
  if (step_name %in% existing_names) {
    stop("The step name is already used: ", step_name, call. = FALSE)
  }

  next_step <- resolve_next_step(next_step, wf_summary)
  sbatch_opts <- update_sbatch_opts(
    wf_summary[["default_sbatch_opts"]], sbatch_opts
  )
  step <- list(
    number = number,
    name = step_name,
    `next` = next_step,
    sbatch_opts = sbatch_opts,
    data = list()
  )
  wf_summary[["steps"]][[number]] <- step

  step_dir <- create_step_dir(wf_summary)
  step_complete <- FALSE
  on.exit({
    if (!step_complete && fs::dir_exists(step_dir)) {
      fs::dir_delete(step_dir)
    }
  }, add = TRUE)
  wf_vars <- make_wf_vars(wf_summary)
  template_result <- step_tmpl(
    instructions_script = wf_vars[["SWF__INSTRUCTIONS_SCRIPT"]],
    wf_vars = wf_vars,
    wf_summary = wf_summary,
    sbatch_opts = sbatch_opts
  )
  template_result <- validate_template_result(template_result)

  if (!is.null(template_result[["sbatch_opts"]])) {
    step[["sbatch_opts"]] <- update_sbatch_opts(
      step[["sbatch_opts"]], template_result[["sbatch_opts"]]
    )
  }
  if (!is.null(template_result[["data"]])) {
    step[["data"]] <- validate_template_data(template_result[["data"]])
  }

  contents <- list()
  if (!is.null(step[["next"]])) {
    contents[["next"]] <- step[["next"]]
  }
  if (length(step[["sbatch_opts"]]) > 0L) {
    contents[paste0("opt.", names(step[["sbatch_opts"]]))] <-
      step[["sbatch_opts"]]
  }
  if (length(step[["data"]]) > 0L) {
    contents[paste0("data.", names(step[["data"]]))] <- step[["data"]]
  }
  write_swf(
    contents,
    fs::path(wf_vars[["SWF__CUR_DIR"]], "step.swf")
  )
  step_complete <- TRUE

  load_workflow(wf_summary[["root"]])
}

#' @keywords internal
#' @noRd
validate_step_name <- function(step_name) {
  if (length(step_name) != 1L || is.na(step_name) ||
      !is.character(step_name) ||
      !grepl("^[A-Za-z][A-Za-z0-9_-]*$", step_name)) {
    stop(
      "`step_name` must match '^[A-Za-z][A-Za-z0-9_-]*$'.",
      call. = FALSE
    )
  }
  invisible(step_name)
}

#' @keywords internal
#' @noRd
resolve_next_step <- function(next_step, wf_summary) {
  if (is.null(next_step)) {
    return(NULL)
  }
  if (length(next_step) != 1L) {
    stop("`next_step` must have length one.", call. = FALSE)
  }
  if (is.na(next_step) || identical(next_step, "")) {
    return("")
  }
  if (is.numeric(next_step)) {
    if (!is.finite(next_step) || next_step < 1 || next_step != floor(next_step)) {
      stop("A numeric `next_step` must be a positive whole number.",
           call. = FALSE)
    }
    return(resolve_summary_step(wf_summary, as.integer(next_step))[["name"]])
  }
  validate_step_name(next_step)
  next_step
}

#' @keywords internal
#' @noRd
validate_template_result <- function(result) {
  if (is.null(result)) {
    return(list())
  }
  if (!is.list(result)) {
    stop("A step template must return NULL or a list.", call. = FALSE)
  }
  if (length(result) > 0L &&
      (is.null(names(result)) || any(!names(result) %in% c("sbatch_opts", "data")))) {
    stop("Template results may only contain `sbatch_opts` and `data`.",
         call. = FALSE)
  }
  result
}

#' @keywords internal
#' @noRd
validate_template_data <- function(data) {
  if (!is.list(data) || (length(data) > 0L &&
      (is.null(names(data)) || any(!nzchar(names(data)))))) {
    stop("Template `data` must be a named list.", call. = FALSE)
  }
  data
}

#' Load a Workflow Summary From Files or the Running Workflow Environment
#'
#' @param wf_root Path to a workflow directory. If omitted, `SWF_ROOT` is used.
#'
#' @return A list with `name`, `root`, `default_sbatch_opts`, and `steps`. Each
#'   step contains `number`, `name`, `next`, `sbatch_opts`, and `data`.
#'
#' @export
load_workflow <- function(wf_root = NULL) {
  if (is.null(wf_root)) {
    wf_root <- get_workflow_root()
  }
  summary_from_files(wf_root)
}

#' Get the Root Directory of a Workflow
#'
#' @param wf_summary A workflow summary. If omitted, `SWF_ROOT` is used.
#' @return The path to the workflow root directory.
#'
#' @export
get_workflow_root <- function(wf_summary = NULL) {
  if (!is.null(wf_summary)) {
    return(wf_summary[["root"]])
  }
  wf_root <- Sys.getenv("SWF_ROOT")
  if (!nzchar(wf_root)) {
    stop(
      "The environment variable 'SWF_ROOT' is empty.\n",
      "Make sure a workflow is currently running.",
      call. = FALSE
    )
  }
  wf_root
}

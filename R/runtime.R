#' Get the Number of the Currently Running Workflow Step
#'
#' @return The step number as an integer, from `SWF_CUR`.
#' @export
get_current_workflow_step <- function() {
  value <- Sys.getenv("SWF_CUR")
  if (!nzchar(value)) {
    stop("The environment variable 'SWF_CUR' is not set.", call. = FALSE)
  }
  as.integer(value)
}

#' Get the Name of the Currently Running Workflow Step
#'
#' @return The step name, from `SWF_CUR_NAME`.
#' @export
get_current_workflow_step_name <- function() {
  value <- Sys.getenv("SWF_CUR_NAME")
  if (!nzchar(value)) {
    stop("The environment variable 'SWF_CUR_NAME' is not set.", call. = FALSE)
  }
  value
}

#' Read the Submission Used for the Current Step
#'
#' @return A named character vector containing the resolved `.swf` submission.
#' @export
get_workflow_submission <- function() {
  path <- Sys.getenv("SWF_SUBMISSION")
  if (!nzchar(path)) {
    stop("The environment variable 'SWF_SUBMISSION' is not set.",
         call. = FALSE)
  }
  read_swf(path)
}

#' Change the Next Step of a Running Workflow
#'
#' **DANGEROUS:** this changes control flow for the current run and can create
#' infinite loops or skip required work. Prefer a static `next_step` when the
#' successor is known while building the workflow.
#'
#' This writes a one-shot `next` message using `swf next`. When `sbatch_opts` is
#' supplied, it also writes a one-shot override for the selected step.
#'
#' @param next_step Name or number of the step to run next.
#' @param sbatch_opts Optional named list of options for that step's next
#'   submission.
#'
#' @return `next_step`, invisibly. The command output is returned by lower-level
#'   wrappers but is not printed here.
#'
#' @examples
#' \dontrun{
#' change_next_workflow_step("fit")
#' change_next_workflow_step(2, list(time = 120))
#' }
#'
#' @export
change_next_workflow_step <- function(next_step, sbatch_opts = NULL) {
  run_swf(c("next", format_swf_value(next_step)))
  if (!is.null(sbatch_opts)) {
    override_workflow_step(next_step, sbatch_opts = sbatch_opts)
  }
  invisible(next_step)
}

#' Override One Submission of a Workflow Step
#'
#' Overrides are one-shot: after one submission the step reverts to `step.swf`.
#' Multiple writers aggregate with an existing pending override. This function
#' can skip work or repeat a step, so `skip` and `repeat_step` must be used with
#' care; a repeated step can form an infinite loop.
#'
#' @param step Name or number of the target step.
#' @param sbatch_opts Optional named list of sbatch options to set.
#' @param data Optional named list of flat data keys to set, for example
#'   `list(map.total = 20)`.
#' @param skip Skip this submission and follow the override's successor.
#' @param repeat_step Run this step again immediately after it finishes.
#' @param unset_opts Character vector of sbatch option names to remove.
#' @param from Optional submission file to use as the merge base.
#' @param reset Ignore a pending override and merge from the step defaults.
#'   Without `reset`, an override of a map step whose pending submission is a
#'   continuation (`repeat`) keeps the continuation's slice.
#' @param on_failure Optional `"stop"` or `"continue"`: what the workflow does
#'   if this submission fails. `NULL` keeps the value of the merge base.
#'
#' @return The captured `swf override` output, invisibly.
#' @export
override_workflow_step <- function(step, sbatch_opts = NULL, data = NULL,
                                   skip = FALSE, repeat_step = FALSE,
                                   unset_opts = NULL, from = NULL,
                                   reset = FALSE, on_failure = NULL) {
  args <- c("override", format_swf_value(step))
  if (!is.null(sbatch_opts)) {
    sbatch_opts <- validate_sbatch_opts(sbatch_opts)
    args <- c(args, named_swf_args(sbatch_opts, "--opt"))
  }
  if (!is.null(unset_opts)) {
    if (!is.character(unset_opts) || anyNA(unset_opts)) {
      stop("`unset_opts` must be a character vector without missing values.",
           call. = FALSE)
    }
    args <- c(args, interleave_after_flag("--unset-opt", unset_opts))
  }
  if (!is.null(data)) {
    if (!is.list(data)) {
      stop("`data` must be a named list.", call. = FALSE)
    }
    args <- c(args, named_swf_args(data, "--data"))
  }
  if (!is.null(on_failure)) {
    if (length(on_failure) != 1L || is.na(on_failure) ||
        !on_failure %in% c("stop", "continue")) {
      stop("`on_failure` must be NULL, \"stop\", or \"continue\".",
           call. = FALSE)
    }
    args <- c(args, "--on-failure", on_failure)
  }
  args <- c(
    args,
    if (isTRUE(skip)) "--skip",
    if (isTRUE(repeat_step)) "--repeat",
    if (!is.null(from)) c("--from", format_swf_value(from)),
    if (isTRUE(reset)) "--reset"
  )
  run_swf(args)
}

# Keep repeated flag/value pairs as consecutive system2 arguments.
#' @keywords internal
#' @noRd
interleave_after_flag <- function(flag, values) {
  values <- vapply(values, format_swf_value, character(1L))
  as.vector(rbind(rep(flag, length(values)), values))
}

#' @keywords internal
#' @noRd
named_swf_args <- function(x, flag) {
  if (length(x) == 0L) {
    return(character())
  }
  if (is.null(names(x)) || any(!nzchar(names(x))) || anyDuplicated(names(x))) {
    stop("Command values must have unique, non-empty names.", call. = FALSE)
  }
  prefix <- c("--opt" = "opt.", "--data" = "data.")[[flag]]
  values <- vapply(seq_along(x), function(i) {
    format_swf_value(x[[i]], paste0(prefix, names(x)[[i]]))
  }, character(1L))
  interleave_after_flag(flag, paste0(names(x), "=", values))
}

#' Change the Size of the Next Map Submission
#'
#' Read the original map metadata from `step.swf` and submit a one-shot override.
#' The original `data.map.n_items` is a hard ceiling. Setting `n = 0` skips the
#' next submission instead.
#'
#' @param step Name or number of a step built with `step_tmpl_map()`.
#' @param n Number of map items to process in the next submission.
#'
#' @return The captured `swf override` output, invisibly.
#' @export
set_map_size <- function(step, n) {
  if (length(n) != 1L || !is.numeric(n) || is.na(n) || !is.finite(n) ||
      n < 0 || n != floor(n)) {
    stop("`n` must be a non-negative whole number.", call. = FALSE)
  }
  wf_summary <- load_workflow()
  step_summary <- resolve_summary_step(wf_summary, step)
  data <- step_summary[["data"]]
  required <- c("map.n_items", "map.max_array_size")
  if (!all(required %in% names(data))) {
    stop("The target is not a map step with complete map metadata.",
         call. = FALSE)
  }
  if (n == 0) {
    return(override_workflow_step(step, skip = TRUE))
  }

  n_items <- as.numeric(data[["map.n_items"]])
  maximum <- as.numeric(data[["map.max_array_size"]])
  if (!is.finite(n_items) || !is.finite(maximum) || maximum < 1) {
    stop("The map step has invalid size metadata.", call. = FALSE)
  }
  if (n > n_items) {
    stop("`n` cannot exceed `data.map.n_items` (", n_items, ").",
         call. = FALSE)
  }

  array <- step_summary[["sbatch_opts"]][["array"]]
  if (is.null(array)) {
    stop("The map step has no array option.", call. = FALSE)
  }
  throttle <- regmatches(array, regexpr("%[0-9]+$", array))
  if (length(throttle) == 0L) {
    throttle <- ""
  }
  size <- min(n, maximum)
  override_workflow_step(
    step,
    sbatch_opts = list(
      array = paste0(
        "0-", format(size - 1, scientific = FALSE, trim = TRUE), throttle
      )
    ),
    data = list(map.total = n, map.offset = 0)
  )
}

#' @keywords internal
#' @noRd
swf_command <- function() {
  command <- Sys.getenv("SWF_CMD")
  if (nzchar(command)) {
    return(command)
  }
  file.path(get_workflow_root(), "swf")
}

#' @keywords internal
#' @noRd
run_swf <- function(args) {
  command <- swf_command()
  resolved <- if (grepl("/", command, fixed = TRUE)) {
    command
  } else {
    unname(Sys.which(command))
  }
  if (!nzchar(resolved) || !file.exists(resolved) ||
      dir.exists(resolved) || file.access(resolved, mode = 1L) != 0L) {
    stop(
      "`swf` not found at ", command, " (or not executable): set SWF_CMD, ",
      "or run inside a workflow job.",
      call. = FALSE
    )
  }
  output <- suppressWarnings(system2(
    command,
    shQuote(as.character(args)),
    stdout = TRUE,
    stderr = TRUE
  ))
  status <- attr(output, "status")
  if (is.null(status)) {
    status <- 0L
  }
  if (status != 0L) {
    stop(
      "`", command, " ", paste(args, collapse = " "), "` failed with status ",
      status, ":\n", paste(output, collapse = "\n"),
      call. = FALSE
    )
  }
  invisible(output)
}

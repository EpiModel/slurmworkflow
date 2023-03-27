#' Replace a Line in a File With New Lines
#'
#' This function is used to complete the templates provided by the package with
#' the user provided informations
#'
#' @param file_in the file to read from
#' @param placeholder_line the line to replace
#' @param file_out path to the new file (default to "file_in" if missing)
#' @param replacement_lines a character vector of lines to insert into the file
#'
#' @return path to the output file (invisibly)
simple_brew <- function(file_in, placeholder_line, replacement_lines,
                        file_out = NULL) {
  file_out <- if (is.null(file_out)) file_in else file_out
  file_lines <- readLines(file_in)
  placeholder_pos <- which(file_lines == placeholder_line)

  if (length(placeholder_pos) != 1)
    stop("`placeholder` must match exactly one line in `file_in`")

  new_lines <- c(
    file_lines[1:(placeholder_pos - 1)],
    replacement_lines,
    file_lines[(placeholder_pos + 1):length(file_lines)]
  )

  writeLines(new_lines, file_out, sep = "\n")
  invisible(file_out)
}

#' Brew the Controller Script Using the Information in the Workflow Summary
#'
#' @keywords internal
#' @noRd
create_ctrl_script <- function(wf_summary) {
  sbatch_opts <- wf_summary[["default_sbatch_opts"]]
  wf_vars <- make_wf_vars(wf_summary)

  relevant_opts <- intersect(names(sbatch_opts), c("account", "partition"))
  sbatch_opts <- validate_sbatch_opts(sbatch_opts[relevant_opts])
  simple_brew(
    file_in = wf_vars[["SWF__CTRL_SCRIPT"]],
    placeholder_line = "###SBATCH_OPTIONS###",
    replacement_lines = make_sbatch_lines(sbatch_opts)
  )
}

#' Brew the Job Script of a Step Using the Information in the Workflow Summary
#'
#' @keywords internal
#' @noRd
create_job_script <- function(wf_summary) {
  wf_vars <- make_wf_vars(wf_summary)
  sbatch_opts <- get_last_step_summary(wf_summary)[["sbatch_opts"]]

  simple_brew(
    file_in = wf_vars[["SWF__JOB_SCRIPT"]],
    placeholder_line = "###SBATCH_OPTIONS###",
    replacement_lines = make_sbatch_lines(sbatch_opts)
  )
}


# Helpers to create files and directories for workflows.

#' @keywords internal
#' @noRd
get_templates_dir <- function() system.file("templates", package = "slurmworkflow", mustWork = TRUE)

#' @keywords internal
#' @noRd
create_wf_dir <- function(wf_summary) {
  wf_root <- wf_summary[["root"]]
  if (dir.exists(wf_root)) {
    stop("The directory \"", wf_root, "\" already exists.", call. = FALSE)
  }
  wf_tmpl_dir <- file.path(get_templates_dir(), "workflow")
  dir.create(wf_root, recursive = TRUE)
  tmpl_files <- list.files(
    wf_tmpl_dir, all.files = TRUE, full.names = TRUE, no.. = TRUE
  )
  copied <- file.copy(tmpl_files, wf_root, recursive = TRUE)
  if (!all(copied)) {
    stop("Failed to copy the workflow template to \"", wf_root, "\".",
         call. = FALSE)
  }
  Sys.chmod(file.path(wf_root, "swf"), mode = "0755")
  dir.create(file.path(wf_root, "swf.d", "steps"), recursive = TRUE)
  invisible(wf_summary)
}

#' @keywords internal
#' @noRd
create_step_dir <- function(wf_summary) {
  step_dir <- make_wf_vars(wf_summary)[["SWF__CUR_DIR"]]
  dir.create(step_dir, recursive = TRUE, showWarnings = FALSE)
  step_dir
}

#' Copy an R script to `<step_dir>/script.R` and return the new path.
#' @keywords internal
#' @noRd
copy_step_script <- function(r_script, step_dir) {
  dest <- file.path(step_dir, "script.R")
  if (!file.copy(r_script, dest, overwrite = TRUE)) {
    stop("Failed to copy \"", r_script, "\" to \"", dest, "\".", call. = FALSE)
  }
  dest
}

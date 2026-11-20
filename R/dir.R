# Helpers to create files and directories for workflows.

#' @keywords internal
#' @noRd
get_templates_dir <- function() fs::path_package("slurmworkflow", "templates")

#' @keywords internal
#' @noRd
create_wf_dir <- function(wf_summary) {
  wf_root <- wf_summary[["root"]]
  if (fs::dir_exists(wf_root)) {
    stop("The directory \"", wf_root, "\" already exists.", call. = FALSE)
  }
  wf_tmpl_dir <- fs::path(get_templates_dir(), "workflow")
  fs::dir_copy(wf_tmpl_dir, wf_root)
  fs::file_chmod(fs::path(wf_root, "swf"), "+x")
  fs::dir_create(fs::path(wf_root, "swf.d", "steps"))
  invisible(wf_summary)
}

#' @keywords internal
#' @noRd
create_step_dir <- function(wf_summary) {
  step_dir <- make_wf_vars(wf_summary)[["SWF__CUR_DIR"]]
  fs::dir_create(step_dir)
  step_dir
}

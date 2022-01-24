# Helper function to create the files and directory for the workflows

#' @keywords internal
#' @noRd
get_templates_dir <- function() fs::path_package("slurmworkflow", "templates")

#' @keywords internal
#' @noRd
create_wf_dir <- function(wf_summary) {
  wf_root <- wf_summary[["root"]]
  if (fs::dir_exists(wf_root)) {
    stop("The directory \"", wf_root, "\" already exists.")
  }

  wf_tmpl_dir <- fs::path(get_templates_dir(), "workflow")
  fs::dir_copy(wf_tmpl_dir, wf_root)

  create_ctrl_script(wf_summary)
  write_wf_summary(wf_summary)

  invisible(wf_summary)
}

#' @keywords internal
#' @noRd
create_step_dir <- function(wf_summary, step_tmpl_fun) {
  wf_vars <- make_wf_vars(wf_summary)
  last_step_summary <- get_last_step_summary(wf_summary)

  step_tmpl_dir <- fs::path(get_templates_dir(), "step_dir")
  fs::dir_copy(step_tmpl_dir, wf_vars[["SWF__CUR_DIR"]])

  tmpl_sbatch_opts <- step_tmpl_fun(
    instructions_script = wf_vars[["SWF__INSTRUCTIONS_SCRIPT"]],
    wf_summary = wf_summary,
    wf_vars = wf_vars,
    sbatch_opts = last_step_summary[["sbatch_opts"]]
  )

  if (is.list(tmpl_sbatch_opts) && length(tmpl_sbatch_opts) > 0) {
    last_step_summary[["sbatch_opts"]] <- update_sbatch_opts(
      last_step_summary[["sbatch_opts"]],
      tmpl_sbatch_opts
    )
    wf_summary <- mutate_last_step_summary(wf_summary, last_step_summary)
  }

  create_job_script(wf_summary)
  write_wf_summary(wf_summary)

  invisible(wf_summary)
}


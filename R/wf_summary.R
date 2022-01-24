# Helper function to manipulate the worflow summaries, read and write them from
# a YAML file.

#' @keywords internal
#' @noRd
new_wf_summary <- function(wf_root, sbatch_opts) {
  list(
    name = fs::path_file(wf_root),
    root = wf_root,
    n_steps = 0,
    default_sbatch_opts = sbatch_opts,
    steps = list()
  )
}

#' @keywords internal
#' @noRd
add_summary_step <- function(wf_summary, sbatch_opts, step_name) {
  step_number <- wf_summary[["n_steps"]] + 1
  wf_summary[["steps"]][[step_number]] <- list(
    name = step_name,
    number = step_number,
    sbatch_opts = sbatch_opts
  )
  wf_summary[["n_steps"]] <- step_number
  wf_summary
}

#' @keywords internal
#' @noRd
write_wf_summary <- function(wf_summary) {
  wf_summary_orig <- wf_summary
  wf_summary_path <- fs::path(wf_summary[["root"]], "workflow.yaml")
  wf_summary[["root"]] <- NULL
  yaml::write_yaml(wf_summary, wf_summary_path)
  invisible(wf_summary_orig)
}

#' @keywords internal
#' @noRd
read_wf_summary <- function(wf_summary_path) {
  wf_summary <- yaml::read_yaml(wf_summary_path)
  wf_summary[["root"]] <- fs::path_dir(wf_summary_path)
  wf_summary
}

#' @keywords internal
#' @noRd
get_last_step_summary <- function(wf_summary) {
  n_step <- length(wf_summary[["steps"]])
  wf_summary[["steps"]][[n_step]]
}

#' @keywords internal
#' @noRd
mutate_last_step_summary <- function(wf_summary, last_step) {
  n_step <- length(wf_summary[["steps"]])
  wf_summary[["steps"]][[n_step]] <- last_step
  wf_summary
}

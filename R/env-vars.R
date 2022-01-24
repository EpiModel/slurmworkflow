#' Make a list of the environment variables as they are available in a running
#' workflow
#'
#' @keywords internal
#' @noRd
make_wf_vars <- function(wf_summary) {
  v <- list()
  v[["SWF_ROOT"]] <- wf_summary[["root"]]
  v[["SWF_NAME"]] <- wf_summary[["name"]]
  v[["SWF_SUMMARY"]] <- fs::path(v[["SWF_ROOT"]], "workflow.yaml")
  v[["SWF_LOG_DIR"]] <- fs::path(v[["SWF_ROOT"]], "log")

  v[["SWF__DIR"]] <- fs::path(v[["SWF_ROOT"]], "SWF")
  v[["SWF__CTRL_SCRIPT"]] <- fs::path(v[["SWF__DIR"]], "controller.sh")
  v[["SWF__CTRL_NAME"]] <- paste0(v[["SWF_NAME"]], "_controller")
  v[["SWF__CTRL_OUT"]] <- paste0(v[["SWF_LOG_DIR"]], "/%x.out")

  v[["SWF__STEPS_DIR"]] <- fs::path(v[["SWF__DIR"]], "steps")
  v[["SWF__STEP_SCRIPT"]] <- fs::path(v[["SWF__DIR"]], "step.sh")
  v[["SWF__STEPS_OUT"]] <- paste0(v[["SWF_LOG_DIR"]], "%x_%A_%a.out")

  if (wf_summary[["n_steps"]] > 0) {
    v[["SWF_CUR"]] <- wf_summary[["n_steps"]]

    v[["SWF__CUR_DIR"]] <- fs::path(v[["SWF__STEPS_DIR"]], v[["SWF_CUR"]])
    v[["SWF__JOB_SCRIPT"]] <- fs::path(v[["SWF__CUR_DIR"]], "job.sh")
    v[["SWF__INSTRUCTIONS_SCRIPT"]] <-
      fs::path(v[["SWF__CUR_DIR"]], "instructions.sh")
  }

  v
}

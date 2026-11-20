#' Make the template variables for the step currently being built
#'
#' @keywords internal
#' @noRd
make_wf_vars <- function(wf_summary) {
  v <- list()
  v[["SWF_ROOT"]] <- wf_summary[["root"]]
  v[["SWF_NAME"]] <- wf_summary[["name"]]
  v[["SWF__DIR"]] <- fs::path(v[["SWF_ROOT"]], "swf.d")
  v[["SWF__STEPS_DIR"]] <- fs::path(v[["SWF__DIR"]], "steps")

  n_steps <- length(wf_summary[["steps"]])
  if (n_steps > 0L) {
    step <- wf_summary[["steps"]][[n_steps]]
    directory <- paste0(step[["number"]], "_", step[["name"]])
    v[["SWF_CUR"]] <- step[["number"]]
    v[["SWF_CUR_NAME"]] <- step[["name"]]
    v[["SWF__CUR_DIR"]] <- fs::path(v[["SWF__STEPS_DIR"]], directory)
    v[["SWF__INSTRUCTIONS_SCRIPT"]] <- fs::path(
      v[["SWF__CUR_DIR"]], "instructions.sh"
    )
  }
  v
}

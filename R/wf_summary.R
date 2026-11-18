# Workflow summaries are views of the files on disk, never serialized state.

#' @keywords internal
#' @noRd
new_summary <- function(wf_root, sbatch_opts) {
  list(
    name = basename(wf_root),
    root = wf_root,
    default_sbatch_opts = sbatch_opts,
    steps = list()
  )
}

#' @keywords internal
#' @noRd
summary_from_files <- function(wf_root) {
  root <- fs::path(wf_root)
  workflow <- read_swf(fs::path(root, "swf.d", "workflow.swf"))
  steps_dir <- fs::path(root, "swf.d", "steps")
  step_dirs <- if (fs::dir_exists(steps_dir)) {
    fs::dir_ls(steps_dir, type = "directory")
  } else {
    character()
  }

  steps <- list()
  if (length(step_dirs) > 0L) {
    directories <- basename(step_dirs)
    pattern <- "^([0-9]+)_([A-Za-z][A-Za-z0-9_-]*)$"
    if (any(!grepl(pattern, directories))) {
      stop("Invalid step directory under ", steps_dir, call. = FALSE)
    }
    numbers <- as.integer(sub(pattern, "\\1", directories))
    names <- sub(pattern, "\\2", directories)
    if (anyDuplicated(numbers) || anyDuplicated(names)) {
      stop("Step numbers and names must be unique.", call. = FALSE)
    }

    steps <- lapply(order(numbers), function(i) {
      contents <- read_swf(fs::path(step_dirs[[i]], "step.swf"))
      list(
        number = numbers[[i]],
        name = names[[i]],
        `next` = if ("next" %in% base::names(contents)) {
          unname(contents[["next"]])
        },
        sbatch_opts = swf_prefixed_list(contents, "opt."),
        data = swf_prefixed_list(contents, "data.")
      )
    })
  }

  list(
    name = basename(root),
    root = root,
    default_sbatch_opts = swf_prefixed_list(workflow, "opt."),
    steps = steps
  )
}

#' @keywords internal
#' @noRd
swf_prefixed_list <- function(x, prefix) {
  keep <- startsWith(names(x), prefix)
  values <- as.list(unname(x[keep]))
  names(values) <- substring(names(x[keep]), nchar(prefix) + 1L)
  values
}

#' @keywords internal
#' @noRd
resolve_summary_step <- function(wf_summary, step) {
  if (length(step) != 1L || is.na(step)) {
    stop("`step` must identify exactly one step.", call. = FALSE)
  }
  steps <- wf_summary[["steps"]]
  if (is.numeric(step) || (is.character(step) && grepl("^[0-9]+$", step))) {
    number <- as.integer(step)
    matches <- which(vapply(steps, function(x) x[["number"]], integer(1L)) == number)
  } else {
    matches <- which(vapply(steps, function(x) x[["name"]], character(1L)) == step)
  }
  if (length(matches) != 1L) {
    stop("Unknown workflow step: ", step, call. = FALSE)
  }
  steps[[matches]]
}

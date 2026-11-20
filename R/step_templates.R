# Step template factories. Templates write the step payload and may return
# additional sbatch options and flat template data.

#' Step Template to Run Bash Statements
#'
#' @param bash_lines Vector of bash lines to be run by the workflow step.
#' @return A template function to be used by `add_workflow_step()`.
#'
#' @section Step Templates:
#' Step templates are function factories. The returned function writes the step
#' payload and may return a list with `sbatch_opts` and `data` elements.
#'
#' @export
step_tmpl_bash_lines <- function(bash_lines) {
  function(instructions_script, ...) {
    helper_write_instructions(bash_lines, instructions_script)
    list()
  }
}

#' Helper Function to Consistently Write the Instruction Script
#'
#' @param instructions Vector of bash lines to be run by the workflow step.
#' @param instructions_script Path to the instructions script.
#' @export
helper_write_instructions <- function(instructions, instructions_script) {
  writeLines(instructions, instructions_script, sep = "\n")
}

#' Step Template to Run a Bash Script
#'
#' @param bash_script Path to the script to be run by the workflow step.
#' @inherit step_tmpl_bash_lines return
#' @inheritSection step_tmpl_bash_lines Step Templates
#' @export
step_tmpl_bash_script <- function(bash_script) {
  step_tmpl_bash_lines(readLines(bash_script))
}

#' Step Template to Run an R Script
#'
#' The script is copied into the workflow, so the original file need not be
#' present on the HPC.
#'
#' @param r_script The R script to be run by the workflow step.
#' @param setup_lines Optional vector of bash lines to run first, typically to
#'   load the required modules.
#'
#' @inherit step_tmpl_bash_lines return
#' @inheritSection step_tmpl_bash_lines Step Templates
#' @export
step_tmpl_rscript <- function(r_script, setup_lines = NULL) {
  function(instructions_script, wf_vars, ...) {
    step_dir <- wf_vars[["SWF__CUR_DIR"]]
    r_script <- fs::file_copy(r_script, fs::path(step_dir, "script.R"))
    instructions <- paste0("Rscript \"", r_script, "\"")
    instructions <- helper_use_setup_lines(instructions, setup_lines)
    helper_write_instructions(instructions, instructions_script)
    list()
  }
}

#' Helper Function to Consistently Prepend Setup Lines
#'
#' @param instructions Vector of bash lines to be run by the workflow step.
#' @param setup_lines Vector of bash lines to run before the other instructions.
#' @return The modified instructions.
#' @export
helper_use_setup_lines <- function(instructions, setup_lines) {
  if (!is.null(setup_lines)) {
    instructions <- c(setup_lines, instructions)
  }
  instructions
}

#' Step Template to Run an R Function
#'
#' Serialize a function and arguments and run them with `do.call()` in a clean R
#' session on the HPC. Every value required by the function must be passed as an
#' argument or loaded by the function itself.
#'
#' A function defined in the global environment is serialized without that
#' environment: the objects it uses from there do not exist when the step runs.
#' A warning names them when the function is created at build time (requires
#' the `codetools` package).
#'
#' @param what The R function to be run by the workflow step.
#' @param args A list of arguments to the function call.
#' @inheritParams step_tmpl_rscript
#' @inherit step_tmpl_bash_lines return
#' @inheritSection step_tmpl_bash_lines Step Templates
#' @export
step_tmpl_do_call <- function(what, args, setup_lines = NULL) {
  warn_global_function(what, "what", "args")
  do_call_data <- list(what = what, args = args)

  function(instructions_script, wf_vars, ...) {
    step_dir <- wf_vars[["SWF__CUR_DIR"]]
    r_script <- fs::path(get_templates_dir(), "step_tmpl_do_call.R")
    r_script <- fs::file_copy(r_script, fs::path(step_dir, "script.R"))
    instructions <- paste0("Rscript \"", r_script, "\"")
    instructions <- helper_use_setup_lines(instructions, setup_lines)
    saveRDS(do_call_data, fs::path(step_dir, "do_call.rds"))
    helper_write_instructions(instructions, instructions_script)
    list()
  }
}

#' Step Template to Map an R Function Over Arguments
#'
#' Run a function as a Slurm array using semantics similar to `base::Map()`.
#' Large maps are split into sequential one-shot submissions. No environment is
#' exported through sbatch; map offsets and totals are read from the resolved
#' SWF submission.
#'
#' @param FUN The R function to be run by the workflow step.
#' @param ... Vectors or lists to iterate over. At least one iterator is
#'   required, all iterators must have the same non-zero length.
#' @param MoreArgs A list of fixed arguments passed to every function call.
#' @param max_array_size Maximum number of array jobs submitted at once. If the
#'   map is larger, the first array task writes a continuation for the next
#'   slice.
#' @param array_throttle Optional positive whole number `k`: at most `k` array
#'   tasks run simultaneously. Appended as `%k` to every `array` option of the
#'   step, including continuations and [set_map_size()] overrides. Do not set
#'   `array` in `sbatch_opts` for a map step: it conflicts with the template.
#'
#' @section Array tasks:
#' Each task maps its position `pos = data.map.offset + SLURM_ARRAY_TASK_ID`
#' (0-based) to item `pos + 1`. A task fails, before doing any work, when the
#' submission's `data.map.*` entries are invalid or when the array does not
#' cover exactly the expected slice (`0` to
#' `min(max_array_size, total - offset) - 1`), for example after an override of
#' `array` that is inconsistent with the map data.
#' @inheritParams step_tmpl_rscript
#' @inherit step_tmpl_bash_lines return
#' @inheritSection step_tmpl_bash_lines Step Templates
#' @export
step_tmpl_map <- function(FUN, ..., MoreArgs = NULL, setup_lines = NULL,
                          max_array_size = Inf, array_throttle = NULL) {
  warn_global_function(FUN, "FUN", "MoreArgs")
  dots <- list(...)
  if (length(dots) == 0L) {
    stop("`step_tmpl_map` requires at least one iterator.", call. = FALSE)
  }
  lengths <- vapply(dots, length, integer(1L))
  n_items <- unique(lengths)
  if (length(n_items) > 1L) {
    stop("All the vectors in `...` must be of the same length", call. = FALSE)
  }
  if (n_items == 0L) {
    stop("Map iterators must not be empty.", call. = FALSE)
  }
  if (length(max_array_size) != 1L || !is.numeric(max_array_size) ||
      is.na(max_array_size) || max_array_size < 1 ||
      (is.finite(max_array_size) && max_array_size != floor(max_array_size))) {
    stop("`max_array_size` must be a positive whole number or `Inf`.",
         call. = FALSE)
  }
  throttle <- ""
  if (!is.null(array_throttle)) {
    if (length(array_throttle) != 1L || !is.numeric(array_throttle) ||
        !is.finite(array_throttle) || array_throttle < 1 ||
        array_throttle != floor(array_throttle)) {
      stop("`array_throttle` must be NULL or a positive whole number.",
           call. = FALSE)
    }
    throttle <- paste0(
      "%", format(array_throttle, scientific = FALSE, trim = TRUE)
    )
  }
  maximum <- min(max_array_size, n_items)
  map_data <- list(FUN = FUN, dots = dots, MoreArgs = MoreArgs)

  function(instructions_script, wf_vars, ...) {
    step_dir <- wf_vars[["SWF__CUR_DIR"]]
    r_script <- fs::path(get_templates_dir(), "step_tmpl_map.R")
    r_script <- fs::file_copy(r_script, fs::path(step_dir, "script.R"))
    instructions <- paste0("Rscript \"", r_script, "\"")
    instructions <- helper_use_setup_lines(instructions, setup_lines)
    saveRDS(map_data, fs::path(step_dir, "map.rds"))
    helper_write_instructions(instructions, instructions_script)
    list(
      sbatch_opts = list(
        array = paste0(
          "0-", format(maximum - 1, scientific = FALSE, trim = TRUE),
          throttle
        )
      ),
      data = list(
        map.n_items = n_items,
        map.max_array_size = maximum,
        map.offset = 0,
        map.total = n_items
      )
    )
  }
}

#' Step Template to Run an R Script With Arguments
#'
#' @inheritParams step_tmpl_rscript
#' @inheritParams step_tmpl_do_call
#' @inherit step_tmpl_bash_lines return
#' @inheritSection step_tmpl_bash_lines Step Templates
#' @export
step_tmpl_do_call_script <- function(r_script, args = list(),
                                     setup_lines = NULL) {
  f <- function(with_args) with(with_args, source(r_script, local = TRUE))
  step_tmpl_do_call(
    what = f,
    args = list(with_args = args),
    setup_lines = setup_lines
  )
}

#' Step Template to Map an R Script Over Arguments
#'
#' @inheritParams step_tmpl_rscript
#' @inheritParams step_tmpl_map
#' @inherit step_tmpl_bash_lines return
#' @inheritSection step_tmpl_bash_lines Step Templates
#' @export
step_tmpl_map_script <- function(r_script, ..., MoreArgs = NULL,
                                 setup_lines = NULL, max_array_size = Inf,
                                 array_throttle = NULL) {
  f <- function(...) with(list(...), source(r_script, local = TRUE))
  step_tmpl_map(
    FUN = f,
    ...,
    MoreArgs = MoreArgs,
    setup_lines = setup_lines,
    max_array_size = max_array_size,
    array_throttle = array_throttle
  )
}

# Warn when a serialized function relies on objects of the global environment:
# they are not saved with it and do not exist in the step's R session.
#' @keywords internal
#' @noRd
warn_global_function <- function(f, argument, pass_through) {
  if (!is.function(f) || is.primitive(f) ||
      !identical(environment(f), globalenv()) ||
      !requireNamespace("codetools", quietly = TRUE)) {
    return(invisible(character()))
  }
  variables <- codetools::findGlobals(f, merge = FALSE)[["variables"]]
  used <- variables[vapply(
    variables, exists, logical(1L), envir = globalenv(), inherits = FALSE
  )]
  if (length(used) > 0L) {
    warning(
      "`", argument, "` is defined in the global environment and uses ",
      "objects defined there: ", paste0("`", used, "`", collapse = ", "),
      ". They will not exist when the step runs; pass them through `",
      pass_through, "`.",
      call. = FALSE
    )
  }
  invisible(used)
}

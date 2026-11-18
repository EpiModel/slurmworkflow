# Time Calculation --------------------------------------------------------------
swf__start_time <- Sys.time()
message(
  "\n###################\n",
  "Workflow step starting at:\n",
  format(swf__start_time), "\n"
)

# Read the payload and the exact submission used for this array task ------------
swf__step_dir <- Sys.getenv("SWF__CUR_DIR")
swf__tmpl_elts <- readRDS(fs::path(swf__step_dir, "map.rds"))
swf__submission_path <- Sys.getenv("SWF_SUBMISSION")
swf__submission <- slurmworkflow::get_workflow_submission()
swf__step_label <- paste0(Sys.getenv("SWF_CUR"), "_", Sys.getenv("SWF_CUR_NAME"))

# Non-negative whole numbers, from the submission or Slurm's environment.
swf__count <- function(value, what, where) {
  if (length(value) != 1L || is.na(value) || !grepl("^[0-9]+$", value)) {
    stop(
      "Map step ", swf__step_label, ": ", what, " must be a non-negative ",
      "integer, got \"", if (length(value) == 1L) value else "", "\" (",
      where, ").",
      call. = FALSE
    )
  }
  as.numeric(value)
}
swf__data <- function(key) {
  value <- if (key %in% names(swf__submission)) {
    unname(swf__submission[[key]])
  } else {
    NA_character_
  }
  if (is.na(value)) {
    stop("Map step ", swf__step_label, ": `", key, "` is missing from the ",
         "submission ", swf__submission_path, ".", call. = FALSE)
  }
  swf__count(value, paste0("`", key, "`"),
             paste0("submission ", swf__submission_path))
}
swf__slurm <- function(name) {
  swf__count(Sys.getenv(name, NA_character_), name, "Slurm environment")
}

swf__offset <- swf__data("data.map.offset")
swf__total <- swf__data("data.map.total")
swf__maximum <- swf__data("data.map.max_array_size")
if (swf__maximum < 1 || swf__offset >= swf__total) {
  stop(
    "Map step ", swf__step_label, ": invalid map data in the submission ",
    swf__submission_path, ": need 0 <= data.map.offset (", swf__offset,
    ") < data.map.total (", swf__total, ") and data.map.max_array_size (",
    swf__maximum, ") >= 1.",
    call. = FALSE
  )
}
swf__n_items <- length(swf__tmpl_elts[["dots"]][[1L]])
if (swf__total > swf__n_items) {
  stop(
    "Map step ", swf__step_label, ": data.map.total (", swf__total,
    ") exceeds the number of map items (", swf__n_items, ") in the ",
    "submission ", swf__submission_path, ".",
    call. = FALSE
  )
}

# The array must cover exactly this slice: task IDs 0 .. expected - 1.
swf__array <- if ("opt.array" %in% names(swf__submission)) {
  unname(swf__submission[["opt.array"]])
} else {
  ""
}
swf__expected <- min(swf__maximum, swf__total - swf__offset)
swf__task_id <- swf__slurm("SLURM_ARRAY_TASK_ID")
swf__task_count <- swf__slurm("SLURM_ARRAY_TASK_COUNT")
swf__task_min <- swf__slurm("SLURM_ARRAY_TASK_MIN")
swf__task_max <- swf__slurm("SLURM_ARRAY_TASK_MAX")
if (swf__task_count != swf__expected || swf__task_min != 0 ||
    swf__task_max != swf__expected - 1) {
  stop(
    "Map step ", swf__step_label, ": the array does not match the map slice. ",
    "Expected ", swf__expected, " tasks numbered 0-", swf__expected - 1,
    " (offset ", swf__offset, ", total ", swf__total, ", max_array_size ",
    swf__maximum, "); got ", swf__task_count, " tasks numbered ",
    swf__task_min, "-", swf__task_max, " from array \"", swf__array,
    "\" in the submission ", swf__submission_path, ".",
    call. = FALSE
  )
}

# 0-based position of this task among all the map items; R item is pos + 1.
swf__pos <- swf__offset + swf__task_id
swf__item <- swf__pos + 1

# The first task writes the next one-shot array slice before doing its own work.
if (swf__task_id == 0) {
  if (swf__offset + swf__expected < swf__total) {
    swf__new_offset <- swf__offset + swf__expected
    swf__next_size <- min(swf__maximum, swf__total - swf__new_offset)
    swf__throttle <- regmatches(
      swf__array,
      regexpr("%[0-9]+$", swf__array)
    )
    if (length(swf__throttle) == 0L) {
      swf__throttle <- ""
    }
    slurmworkflow::override_workflow_step(
      slurmworkflow::get_current_workflow_step_name(),
      sbatch_opts = list(
        array = paste0(
          "0-",
          format(swf__next_size - 1, scientific = FALSE, trim = TRUE),
          swf__throttle
        )
      ),
      data = list(map.offset = swf__new_offset, map.total = swf__total),
      repeat_step = TRUE,
      from = swf__submission_path
    )
  }
}

# Create the arguments for this array element ----------------------------------
swf__args <- c(
  lapply(swf__tmpl_elts[["dots"]], function(x) x[[swf__item]]),
  swf__tmpl_elts[["MoreArgs"]]
)
swf__FUN <- swf__tmpl_elts[["FUN"]]
rm(swf__tmpl_elts, swf__step_dir, swf__submission, swf__count, swf__data,
   swf__slurm)
gc()
message("###################\n")

do.call(what = swf__FUN, args = swf__args)

# Display warnings --------------------------------------------------------------
message("\n###################\n")
message(paste0(capture.output(summary(warnings())), collapse = "\n"))

# Time Calculation --------------------------------------------------------------
message(
  "\n###################\n",
  "Workflow ran for:\n",
  format(Sys.time() - swf__start_time),
  "\n###################\n"
)

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
swf__submission <- slurmworkflow::get_workflow_submission()
swf__offset <- as.numeric(swf__submission[["data.map.offset"]])
swf__total <- as.numeric(swf__submission[["data.map.total"]])
swf__maximum <- as.numeric(swf__submission[["data.map.max_array_size"]])
swf__task_id <- as.numeric(Sys.getenv("SLURM_ARRAY_TASK_ID"))
swf__task_min <- as.numeric(Sys.getenv("SLURM_ARRAY_TASK_MIN"))
swf__idx <- swf__offset + swf__task_id + 1

if (swf__idx > swf__total) {
  message("Map index ", swf__idx, " is beyond total ", swf__total,
          "; nothing to do.")
  quit(save = "no", status = 0)
}

# The first task writes the next one-shot array slice before doing its own work.
if (swf__task_id == swf__task_min) {
  swf__slice <- min(swf__maximum, swf__total - swf__offset)
  if (swf__offset + swf__slice < swf__total) {
    swf__new_offset <- swf__offset + swf__slice
    swf__next_size <- min(swf__maximum, swf__total - swf__new_offset)
    swf__array <- swf__submission[["opt.array"]]
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
      from = Sys.getenv("SWF_SUBMISSION")
    )
  }
}

# Create the arguments for this array element ----------------------------------
swf__args <- c(
  lapply(swf__tmpl_elts[["dots"]], function(x) x[[swf__idx]]),
  swf__tmpl_elts[["MoreArgs"]]
)
swf__FUN <- swf__tmpl_elts[["FUN"]]
rm(swf__tmpl_elts, swf__step_dir, swf__submission)
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

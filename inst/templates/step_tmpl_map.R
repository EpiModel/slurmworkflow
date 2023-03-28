# Time Calulation --------------------------------------------------------------
swf__start_time <- Sys.time()
message(
  "\n###################\n",
  "Workflow step starting at:\n",
  format(swf__start_time), "\n"
)

# Step Template ----------------------------------------------------------------
step_dir <- Sys.getenv("SWF__CUR_DIR")
swf__tmpl_elts <- readRDS(fs::path(step_dir, "map.rds"))
rm(step_dir)

array_id <- as.numeric(Sys.getenv("SLURM_ARRAY_TASK_ID"))
array_max <- as.numeric(Sys.getenv("SLURM_ARRAY_TASK_MAX"))
array_offset <- as.numeric(Sys.getenv("SWF__ARRAY_OFFSET"))
corrected_id <- array_id + array_offset

# On the last array element
if (array_id == array_max) {
  length_map <- max(vapply(swf__tmpl_elts[["dots"]], length, 0))
  # Start the next array slice if not finished
  if (corrected_id < length_map) {
    next_slice_end <- min(
      length_map - corrected_id - 1,
      swf__tmpl_elts[["array_size"]]
    )
    sbatch_opts <- list(
      "array" = paste0("0-", next_slice_end),
      "export" = paste0("ALL,SWF__ARRAY_OFFSET=", corrected_id + 1)
    )
    slurmworkflow::change_next_workflow_step(
      next_step = slurmworkflow::get_current_workflow_step(),
      sbatch_opts = sbatch_opts
    )
    rm(length_map, next_slice_end, sbatch_opts)
  }
}

# Create the
swf__tmpl_elts[["args"]] <- c(
  lapply(swf__tmpl_elts[["dots"]], function(x) x[[corrected_id]]),
  swf__tmpl_elts[["MoreArgs"]]
)
# Cleanup
rm(array_id, array_max, array_offset, corrected_id)
swf__tmpl_elts[["dots"]] <- NULL
swf__tmpl_elts[["MoreArgs"]] <- NULL
gc()
message("###################\n")

# The actual function call
do.call(
  what = swf__tmpl_elts[["FUN"]],
  args = swf__tmpl_elts[["args"]]
)

# Time Calulation --------------------------------------------------------------
message(
  "\n###################\n",
  "Workflow ran for:\n",
  format(Sys.time() - swf__start_time),
  "\n###################\n"
)

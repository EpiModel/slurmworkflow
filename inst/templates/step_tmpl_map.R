step_dir <- Sys.getenv("SWF__CUR_DIR")
swf__tmpl_elts <- readRDS(fs::path(step_dir, "map.rds"))
rm(step_dir)

swf__array_id <- as.numeric(Sys.getenv("SLURM_ARRAY_TASK_ID"))
swf__array_max <- as.numeric(Sys.getenv("SLURM_ARRAY_TASK_MAX"))

if (swf__array_id == swf__array_max) {
  length_map <- max(vapply(swf__tmpl_elts[["dots"]], length, 0))
  if (swf__array_id < length_map) {
    next_slice_beg <- swf__array_id + 1
    next_slice_end <- min(
      swf__array_id + swf__tmpl_elts[["array_size"]],
      length_map
    )

    sbatch_opts <- list("array" = paste0(next_slice_beg, "-", next_slice_end))

    slurmworkflow::change_next_workflow_step(
      next_step = get_current_workflow_step(),
      sbatch_opts = sbatch_opts
    )

    rm(next_slice_beg, next_slice_end, swf__array_max, sbatch_opts)
  }
}

swf__tmpl_elts[["args"]] <- c(
  lapply(swf__tmpl_elts[["dots"]], function(x) x[[swf__array_id]]),
  swf__tmpl_elts[["MoreArgs"]]
)

swf__tmpl_elts[["dots"]] <- NULL
swf__tmpl_elts[["MoreArgs"]] <- NULL
rm(swf__array_id)
gc()

do.call(
  what = swf__tmpl_elts[["FUN"]],
  args = swf__tmpl_elts[["args"]]
)

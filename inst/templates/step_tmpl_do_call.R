# Time Calulation --------------------------------------------------------------
cat("Workflow step starting at:\n")
swf__start_time <- Sys.time()
cat(swf__start_time)
cat("\n          ##########          \n")

# Step Template ----------------------------------------------------------------
step_dir <- Sys.getenv("SWF__CUR_DIR")
swf__tmpl_elts <- readRDS(fs::path(step_dir, "do_call.rds"))
rm(step_dir)
gc()

do.call(
  what = swf__tmpl_elts[["what"]],
  args = swf__tmpl_elts[["args"]]
)

# Time Calulation --------------------------------------------------------------
cat("\n          ##########          \n")
cat("Workflow ran for:\n")
cat(Sys.time() - swf__start_time)
cat("\n")

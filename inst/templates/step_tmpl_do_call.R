# Time Calulation --------------------------------------------------------------
swf__start_time <- Sys.time()
message(
  "\n###################\n",
  "Workflow step starting at:\n",
  format(swf__start_time), "\n"
)

# Step Template ----------------------------------------------------------------
step_dir <- Sys.getenv("SWF__CUR_DIR")
swf__tmpl_elts <- readRDS(fs::path(step_dir, "do_call.rds"))
rm(step_dir)
gc()
message("\n###################\n")

do.call(
  what = swf__tmpl_elts[["what"]],
  args = swf__tmpl_elts[["args"]]
)

# Time Calulation --------------------------------------------------------------
message(
  "\n###################\n",
  "Workflow ran for:\n",
  format(Sys.time() - swf__start_time),
  "\n###################\n"
)

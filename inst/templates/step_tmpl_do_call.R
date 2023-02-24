# Time Calulation --------------------------------------------------------------
print("Workflow step starting at:")
swf__start_time <- Sys.time()
print(swf__start_time)
print("          ##########          ")

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
print("          ##########          ")
print("Workflow ran for:")
print(Sys.time() - swf__start_time)

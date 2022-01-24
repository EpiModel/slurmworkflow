step_dir <- Sys.getenv("SWF__CUR_DIR")
swf__tmpl_elts <- readRDS(fs::path(step_dir, "do_call.rds"))
rm(step_dir)
gc()

do.call(
  what = swf__tmpl_elts[["what"]],
  args = swf__tmpl_elts[["args"]]
)


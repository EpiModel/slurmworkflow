local_swf_stub <- function(env = parent.frame()) {
  skip_on_os("windows")
  directory <- withr::local_tempdir(.local_envir = env)
  command <- file.path(directory, "swf")
  log <- file.path(directory, "argv")
  writeLines(c(
    "#!/bin/sh",
    "if [ \"${SWF_TEST_FAIL:-0}\" = 1 ]; then",
    "  echo 'stub failure' >&2",
    "  exit 7",
    "fi",
    "{",
    "  printf 'CALL\\n'",
    "  for arg in \"$@\"; do printf '%s\\n' \"$arg\"; done",
    "} >> \"$SWF_TEST_ARGV\"",
    "printf 'stub ok\\n'"
  ), command)
  Sys.chmod(command, mode = "0755")
  withr::local_envvar(
    c(SWF_CMD = command, SWF_TEST_ARGV = log, SWF_TEST_FAIL = "0"),
    .local_envir = env
  )
  log
}

test_that("runtime getters use the submission environment", {
  directory <- withr::local_tempdir()
  submission <- file.path(directory, "submission.swf")
  write_swf(c(`data.map.offset` = "2", `data.map.total` = "5"), submission)
  withr::local_envvar(c(
    SWF_CUR = "3", SWF_CUR_NAME = "calibrate", SWF_SUBMISSION = submission
  ))
  expect_identical(get_current_workflow_step(), 3L)
  expect_identical(get_current_workflow_step_name(), "calibrate")
  expect_identical(
    get_workflow_submission(),
    c(`data.map.offset` = "2", `data.map.total` = "5")
  )
})

test_that("override_workflow_step builds exact argv", {
  log <- local_swf_stub()
  override_workflow_step(
    "calib",
    sbatch_opts = list(array = "0-19%4", comment = "two words '$HOME' *"),
    data = list(map.total = 20, map.note = "a=b # literal"),
    skip = TRUE,
    repeat_step = TRUE,
    unset_opts = "mem",
    from = "/tmp/from this/submission.swf",
    reset = TRUE
  )
  expect_identical(readLines(log), c(
    "CALL", "override", "calib",
    "--opt", "array=0-19%4",
    "--opt", "comment=two words '$HOME' *",
    "--unset-opt", "mem",
    "--data", "map.total=20",
    "--data", "map.note=a=b # literal",
    "--skip", "--repeat",
    "--from", "/tmp/from this/submission.swf",
    "--reset"
  ))
})

test_that("change_next_workflow_step calls next and optional override", {
  log <- local_swf_stub()
  result <- withVisible(change_next_workflow_step("fit", list(time = 120)))
  expect_identical(result$value, "fit")
  expect_false(result$visible)
  expect_identical(readLines(log), c(
    "CALL", "next", "fit",
    "CALL", "override", "fit", "--opt", "time=120"
  ))
})

test_that("set_map_size preserves throttling and validates its ceiling", {
  directory <- withr::local_tempdir()
  wf <- create_workflow("map-size", list(partition = "compute"), directory)
  wf <- add_workflow_step(
    wf,
    step_tmpl_map(identity, 1:5, max_array_size = 4),
    step_name = "mapped"
  )
  step_file <- file.path(wf[["root"]], "swf.d", "steps", "1_mapped", "step.swf")
  contents <- read_swf(step_file)
  contents[["opt.array"]] <- "0-3%2"
  write_swf(contents, step_file)
  withr::local_envvar(c(SWF_ROOT = wf[["root"]]))
  log <- local_swf_stub()

  set_map_size("mapped", 3)
  expect_identical(readLines(log), c(
    "CALL", "override", "mapped",
    "--opt", "array=0-2%2",
    "--data", "map.total=3",
    "--data", "map.offset=0"
  ))

  set_map_size(1, 0)
  expect_identical(tail(readLines(log), 4), c(
    "CALL", "override", "1", "--skip"
  ))
  expect_error(set_map_size("mapped", 6), "n_items")
  expect_error(set_map_size("mapped", -1), "non-negative")
})

test_that("swf command failures include status and captured stderr", {
  local_swf_stub()
  withr::local_envvar(c(SWF_TEST_FAIL = "1"))
  expect_error(override_workflow_step(1), "stub failure")
})

test_that("runtime helpers error outside a workflow", {
  withr::local_envvar(c(
    SWF_ROOT = NA, SWF_CMD = NA, SWF_CUR = NA,
    SWF_CUR_NAME = NA, SWF_SUBMISSION = NA
  ))
  expect_error(get_workflow_root(), "SWF_ROOT")
  expect_error(get_current_workflow_step(), "SWF_CUR")
  expect_error(get_current_workflow_step_name(), "SWF_CUR_NAME")
  expect_error(get_workflow_submission(), "SWF_SUBMISSION")
  expect_error(change_next_workflow_step(2), "SWF_ROOT")
})

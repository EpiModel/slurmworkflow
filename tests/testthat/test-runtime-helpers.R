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

test_that("override_workflow_step passes on_failure", {
  log <- local_swf_stub()
  override_workflow_step("fit", on_failure = "continue")
  override_workflow_step("fit", sbatch_opts = list(time = 5),
                         on_failure = "stop", reset = TRUE)
  expect_identical(readLines(log), c(
    "CALL", "override", "fit", "--on-failure", "continue",
    "CALL", "override", "fit", "--opt", "time=5", "--on-failure", "stop",
    "--reset"
  ))
  expect_error(override_workflow_step("fit", on_failure = "ignore"),
               "on_failure")
  expect_error(override_workflow_step("fit", on_failure = NA), "on_failure")
})

test_that("override values are validated with their key", {
  log <- local_swf_stub()
  expect_error(override_workflow_step("fit", sbatch_opts = list(comment = "")),
               "`opt.comment`.*empty")
  expect_error(override_workflow_step("fit", data = list(flag = TRUE)),
               "`data.flag` \\(logical\\)")
  override_workflow_step("fit", data = list(note = ""))
  expect_identical(readLines(log), c(
    "CALL", "override", "fit", "--data", "note="
  ))
})

test_that("a missing or non-executable swf command is reported", {
  skip_on_os("windows")
  directory <- withr::local_tempdir()
  missing <- file.path(directory, "nope", "swf")
  withr::local_envvar(c(SWF_CMD = missing))
  expect_error(change_next_workflow_step("fit"),
               "`swf` not found at .*nope/swf.*SWF_CMD")

  not_executable <- file.path(directory, "swf")
  writeLines("#!/bin/sh", not_executable)
  Sys.chmod(not_executable, mode = "0644")
  withr::local_envvar(c(SWF_CMD = not_executable))
  expect_error(override_workflow_step("fit"), "not found at .*SWF_CMD")

  withr::local_envvar(c(SWF_CMD = NA, SWF_ROOT = directory))
  Sys.chmod(not_executable, mode = "0755")
  expect_silent(run_swf("status"))
  withr::local_envvar(c(SWF_ROOT = file.path(directory, "nope")))
  expect_error(run_swf("status"), "not found at")
})

# The map runtime script, sourced with a fake array task environment.
local_map_task <- function(n_items = 5, max_array_size = 2, submission = list(),
                           task = list(), env = parent.frame()) {
  directory <- withr::local_tempdir(.local_envir = env)
  wf <- create_workflow("maprt", list(partition = "compute"), directory)
  out <- file.path(directory, "items")
  wf <- add_workflow_step(
    wf,
    step_tmpl_map(
      function(x, out) cat(x, "\n", file = out, append = TRUE, sep = ""),
      x = seq_len(n_items) * 10,
      MoreArgs = list(out = out),
      max_array_size = max_array_size
    ),
    step_name = "mapped"
  )
  step_dir <- file.path(wf[["root"]], "swf.d", "steps", "1_mapped")
  contents <- as.list(read_swf(file.path(step_dir, "step.swf")))
  contents[names(submission)] <- submission
  contents <- Filter(Negate(is.null), contents)
  path <- file.path(directory, "submission.swf")
  write_swf(contents, path)
  vars <- c(
    SWF__CUR_DIR = step_dir, SWF_SUBMISSION = path, SWF_CUR = "1",
    SWF_CUR_NAME = "mapped", SLURM_ARRAY_TASK_ID = "0",
    SLURM_ARRAY_TASK_MIN = "0",
    SLURM_ARRAY_TASK_MAX = as.character(min(max_array_size, n_items) - 1),
    SLURM_ARRAY_TASK_COUNT = as.character(min(max_array_size, n_items))
  )
  vars[names(task)] <- unlist(task)
  withr::local_envvar(vars, .local_envir = env)
  list(script = file.path(step_dir, "script.R"), out = out, path = path)
}

run_map_task <- function(task) {
  suppressMessages(sys.source(task$script, envir = new.env()))
}

test_that("the map runtime maps 0-based positions to R items", {
  task <- local_map_task(
    submission = list(data.map.offset = "2", data.map.total = "5",
                      opt.array = "0-1"),
    task = list(SLURM_ARRAY_TASK_ID = "1")
  )
  run_map_task(task)
  # pos = offset + task id = 3, item pos + 1 = 4.
  expect_identical(readLines(task$out), "40")
})

test_that("the map runtime validates the map data of the submission", {
  cases <- list(
    list(list(data.map.offset = NULL), "`data.map.offset` is missing"),
    list(list(data.map.total = "abc"), "`data.map.total` must be a non-negative"),
    list(list(data.map.offset = "-1"), "`data.map.offset` must be a non-negative"),
    list(list(data.map.offset = "1.5"), "non-negative integer"),
    list(list(data.map.offset = "5"), "0 <= data.map.offset \\(5\\) < data.map.total \\(5\\)"),
    list(list(data.map.max_array_size = "0"), "max_array_size \\(0\\) >= 1"),
    list(list(data.map.total = "9"), "data.map.total \\(9\\) exceeds the number of map items \\(5\\)")
  )
  for (case in cases) {
    task <- local_map_task(submission = case[[1L]])
    expect_error(run_map_task(task), case[[2L]])
    expect_error(run_map_task(task), "1_mapped", fixed = TRUE)
    expect_error(run_map_task(task), task$path, fixed = TRUE)
    expect_false(file.exists(task$out))
  }
})

test_that("the map runtime fails when the array does not cover the slice", {
  # 5 items, slices of 2: the first slice expects tasks 0-1.
  cases <- list(
    list(SLURM_ARRAY_TASK_COUNT = "1", SLURM_ARRAY_TASK_MAX = "0"),
    list(SLURM_ARRAY_TASK_COUNT = "3", SLURM_ARRAY_TASK_MAX = "2"),
    list(SLURM_ARRAY_TASK_MIN = "1", SLURM_ARRAY_TASK_MAX = "2",
         SLURM_ARRAY_TASK_ID = "1"),
    list(SLURM_ARRAY_TASK_MAX = "2")
  )
  for (case in cases) {
    task <- local_map_task(
      submission = list(opt.array = "1,3,5"), task = case
    )
    expect_error(
      run_map_task(task),
      "does not match the map slice. Expected 2 tasks numbered 0-1"
    )
    expect_error(run_map_task(task), "\"1,3,5\"", fixed = TRUE)
    expect_error(run_map_task(task), task$path, fixed = TRUE)
    expect_false(file.exists(task$out))
  }
  task <- local_map_task(task = list(SLURM_ARRAY_TASK_COUNT = NA))
  expect_error(run_map_task(task), "SLURM_ARRAY_TASK_COUNT must be")
})

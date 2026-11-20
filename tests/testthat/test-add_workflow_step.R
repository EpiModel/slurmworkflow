test_that("add_workflow_step creates named directories and resolved data", {
  directory <- withr::local_tempdir()
  wf <- create_workflow(
    "steps",
    list(partition = "compute", mem = "8G", time = 60),
    directory
  )

  template <- function(instructions_script, wf_vars, wf_summary, sbatch_opts, ...) {
    expect_true(dir.exists(wf_vars[["SWF__CUR_DIR"]]))
    expect_identical(sbatch_opts[["mem"]], "8G")
    writeLines("echo first", instructions_script)
    list(
      sbatch_opts = list(`mem-per-cpu` = "4G"),
      data = list(alpha = "a=b # literal", count = 100000)
    )
  }
  wf <- add_workflow_step(
    wf, template, step_name = "first_step", next_step = "finish-later"
  )

  step_dir <- file.path(wf[["root"]], "swf.d", "steps", "1_first_step")
  expect_true(dir.exists(step_dir))
  expect_true(file.exists(file.path(step_dir, "instructions.sh")))
  expect_false(file.exists(file.path(step_dir, "job.sh")))
  expect_named(
    wf[["steps"]][[1L]],
    c("number", "name", "next", "sbatch_opts", "data", "on_failure")
  )
  expect_identical(wf[["steps"]][[1L]][["on_failure"]], "stop")
  expect_false("on_failure" %in% names(read_swf(file.path(step_dir, "step.swf"))))
  expect_identical(wf[["steps"]][[1L]][["number"]], 1L)
  expect_identical(wf[["steps"]][[1L]][["next"]], "finish-later")
  expect_identical(wf[["steps"]][[1L]][["sbatch_opts"]][["mem-per-cpu"]], "4G")
  expect_false("mem" %in% names(wf[["steps"]][[1L]][["sbatch_opts"]]))

  contents <- read_swf(file.path(step_dir, "step.swf"))
  expect_identical(contents[["next"]], "finish-later")
  expect_identical(contents[["data.alpha"]], "a=b # literal")
  expect_identical(contents[["data.count"]], "100000")
  expect_identical(contents[["opt.time"]], "60")
  expect_identical(wf, load_workflow(wf[["root"]]))
})

test_that("step names, defaults, and static successors are validated", {
  directory <- withr::local_tempdir()
  wf <- create_workflow("names", list(partition = "compute"), directory)
  bash <- step_tmpl_bash_lines("true")
  wf <- add_workflow_step(wf, bash)
  expect_identical(wf[["steps"]][[1L]][["name"]], "step_1")
  expect_null(wf[["steps"]][[1L]][["next"]])

  wf <- add_workflow_step(wf, bash, next_step = 1)
  expect_identical(wf[["steps"]][[2L]][["name"]], "step_2")
  expect_identical(wf[["steps"]][[2L]][["next"]], "step_1")
  wf <- add_workflow_step(wf, bash, next_step = NA)
  expect_identical(wf[["steps"]][[3L]][["next"]], "")
  wf <- add_workflow_step(wf, bash, step_name = "finished", next_step = "")
  expect_identical(wf[["steps"]][[4L]][["next"]], "")

  expect_error(add_workflow_step(wf, bash, step_name = "finished"), "already")
  for (invalid in list("1numeric", "", "has space", "under_score.ok", NA_character_)) {
    expect_error(add_workflow_step(wf, bash, step_name = invalid), "step_name")
  }
  expect_error(add_workflow_step(wf, bash, next_step = 99), "Unknown")
  expect_error(add_workflow_step(wf, bash, next_step = 1.5), "whole")
  expect_error(add_workflow_step(wf, bash, next_step = "not a name"), "`next_step`")
})

test_that("template results merge exclusive options and reject malformed returns", {
  directory <- withr::local_tempdir()
  wf <- create_workflow("templates", list(partition = "compute", mem = "4G"), directory)
  wf <- add_workflow_step(
    wf,
    step_tmpl = function(instructions_script, ...) {
      writeLines("true", instructions_script)
      list(sbatch_opts = list(`mem-per-gpu` = "2G"))
    },
    sbatch_opts = list(`mem-per-cpu` = "8G")
  )
  options <- wf[["steps"]][[1L]][["sbatch_opts"]]
  expect_named(options, c("partition", "mem-per-gpu"))

  expect_error(
    add_workflow_step(
      wf,
      function(instructions_script, ...) list(array = "0-2")
    ),
    "only contain"
  )
  expect_error(
    add_workflow_step(
      wf,
      function(instructions_script, ...) list(data = list(1, 2))
    ),
    "named list"
  )
})

test_that("step_tmpl_map writes map data and an array without export", {
  directory <- withr::local_tempdir()
  wf <- create_workflow("map", list(partition = "compute"), directory)
  wf <- add_workflow_step(
    wf,
    step_tmpl_map(
      function(x, fixed) x + fixed,
      x = 1:5,
      MoreArgs = list(fixed = 2),
      max_array_size = 3
    ),
    step_name = "mapped",
    next_step = NA
  )
  step <- wf[["steps"]][[1L]]
  expect_identical(step[["sbatch_opts"]][["array"]], "0-2")
  expect_false("export" %in% names(step[["sbatch_opts"]]))
  expect_identical(
    step[["data"]],
    list(map.n_items = "5", map.max_array_size = "3",
         map.offset = "0", map.total = "5")
  )
  expect_identical(step[["next"]], "")

  step_dir <- file.path(wf[["root"]], "swf.d", "steps", "1_mapped")
  expect_true(file.exists(file.path(step_dir, "script.R")))
  expect_true(file.exists(file.path(step_dir, "map.rds")))
  map_data <- readRDS(file.path(step_dir, "map.rds"))
  expect_identical(map_data[["dots"]], list(x = 1:5))
  expect_false("array_size" %in% names(map_data))

  expect_error(step_tmpl_map(identity), "at least one")
  expect_error(step_tmpl_map(identity, integer()), "empty")
  expect_error(step_tmpl_map(identity, x = 1:2, y = 1:3), "same length")
  expect_error(step_tmpl_map(identity, 1:2, max_array_size = 0), "positive")
})

test_that("infinite map array size is stored as the finite item count", {
  directory <- withr::local_tempdir()
  wf <- create_workflow("map-infinite", list(partition = "compute"), directory)
  wf <- add_workflow_step(wf, step_tmpl_map(identity, letters[1:2]))
  expect_identical(wf[["steps"]][[1L]][["data"]][["map.max_array_size"]], "2")
  expect_identical(wf[["steps"]][[1L]][["sbatch_opts"]][["array"]], "0-1")
})

test_that("on_failure is written only for continue and read back", {
  directory <- withr::local_tempdir()
  wf <- create_workflow("failure", list(partition = "compute"), directory)
  bash <- step_tmpl_bash_lines("true")
  wf <- add_workflow_step(wf, bash, step_name = "strict")
  wf <- add_workflow_step(wf, bash, step_name = "lenient",
                          on_failure = "continue")
  wf <- add_workflow_step(wf, bash, step_name = "explicit", on_failure = "stop")
  expect_identical(
    vapply(wf[["steps"]], `[[`, "", "on_failure"),
    c("stop", "continue", "stop")
  )
  steps_dir <- file.path(wf[["root"]], "swf.d", "steps")
  lenient <- read_swf(file.path(steps_dir, "2_lenient", "step.swf"))
  expect_identical(lenient[["on_failure"]], "continue")
  for (step in c("1_strict", "3_explicit")) {
    expect_false(
      "on_failure" %in% names(read_swf(file.path(steps_dir, step, "step.swf")))
    )
  }
  expect_identical(wf, load_workflow(wf[["root"]]))
  expect_error(add_workflow_step(wf, bash, on_failure = "ignore"), "arg")

  path <- file.path(steps_dir, "3_explicit", "step.swf")
  contents <- read_swf(path)
  contents[["on_failure"]] <- "retry"
  write_swf(contents, path)
  expect_error(load_workflow(wf[["root"]]), "on_failure.*retry.*3_explicit")
})

test_that("next_step and step name errors name the argument and cap length", {
  directory <- withr::local_tempdir()
  wf <- create_workflow("b7", list(partition = "compute"), directory)
  bash <- step_tmpl_bash_lines("true")
  expect_error(add_workflow_step(wf, bash, next_step = TRUE), "`next_step`")
  expect_error(add_workflow_step(wf, bash, next_step = "a b"), "`next_step`")
  expect_error(
    add_workflow_step(wf, bash, next_step = strrep("n", 65)),
    "`next_step` must be at most 64"
  )
  expect_error(
    add_workflow_step(wf, bash, step_name = strrep("s", 65)),
    "`step_name` must be at most 64"
  )
  wf <- add_workflow_step(wf, bash, step_name = strrep("s", 64))
  expect_identical(wf[["steps"]][[1L]][["name"]], strrep("s", 64))
})

test_that("add_workflow_step refuses a layout that is not numbered 1..N", {
  directory <- withr::local_tempdir()
  wf <- create_workflow("layout", list(partition = "compute"), directory)
  bash <- step_tmpl_bash_lines("true")
  wf <- add_workflow_step(wf, bash, step_name = "a")
  wf <- add_workflow_step(wf, bash, step_name = "b")
  steps_dir <- file.path(wf[["root"]], "swf.d", "steps")
  file.rename(file.path(steps_dir, "2_b"), file.path(steps_dir, "3_b"))
  expect_error(
    add_workflow_step(wf, bash, step_name = "c"),
    "exactly 1..N; found: 1_a, 3_b"
  )
  expect_setequal(list.files(steps_dir), c("1_a", "3_b"))

  # A duplicate number (a deleted step re-added by hand) is refused too.
  file.rename(file.path(steps_dir, "3_b"), file.path(steps_dir, "1_b"))
  expect_error(add_workflow_step(wf, bash, step_name = "c"), "1_a, 1_b")
  expect_setequal(list.files(steps_dir), c("1_a", "1_b"))
})

test_that("the step directory is removed when the final reload fails", {
  directory <- withr::local_tempdir()
  wf <- create_workflow("guard", list(partition = "compute"), directory)
  steps_dir <- file.path(wf[["root"]], "swf.d", "steps")
  template <- function(instructions_script, wf_vars, ...) {
    writeLines("true", instructions_script)
    dir.create(file.path(wf_vars[["SWF__STEPS_DIR"]], "not-a-step"))
    list()
  }
  expect_error(add_workflow_step(wf, template, step_name = "a"),
               "Invalid step directory")
  expect_identical(list.files(steps_dir), "not-a-step")
})

test_that("a template option conflicting with a user option is refused", {
  directory <- withr::local_tempdir()
  wf <- create_workflow("conflict", list(partition = "compute"), directory)
  map <- step_tmpl_map(function(x) x, 1:3)
  expect_error(
    add_workflow_step(wf, map, sbatch_opts = list(array = "0-2%1")),
    "template sets `array`"
  )
  expect_length(list.files(file.path(wf[["root"]], "swf.d", "steps")), 0L)
  wf <- add_workflow_step(wf, map, sbatch_opts = list(array = "0-2"))
  expect_identical(wf[["steps"]][[1L]][["sbatch_opts"]][["array"]], "0-2")
  # Equal values compare as written: 60 and "60" are the same option value.
  timed <- function(instructions_script, ...) {
    writeLines("true", instructions_script)
    list(sbatch_opts = list(time = "60"))
  }
  wf <- add_workflow_step(wf, timed, sbatch_opts = list(time = 60))
  expect_identical(wf[["steps"]][[2L]][["sbatch_opts"]][["time"]], "60")
  expect_error(
    add_workflow_step(wf, timed, sbatch_opts = list(time = 30)),
    "template sets `time`"
  )
})

test_that("array_throttle is appended to the map array", {
  directory <- withr::local_tempdir()
  wf <- create_workflow("throttle", list(partition = "compute"), directory)
  wf <- add_workflow_step(
    wf,
    step_tmpl_map(function(x) x, 1:10, max_array_size = 4, array_throttle = 2),
    step_name = "mapped"
  )
  expect_identical(wf[["steps"]][[1L]][["sbatch_opts"]][["array"]], "0-3%2")
  wf <- add_workflow_step(
    wf,
    step_tmpl_map_script("script.R", x = 1:3, array_throttle = 1L),
    step_name = "scripted"
  )
  expect_identical(wf[["steps"]][[2L]][["sbatch_opts"]][["array"]], "0-2%1")
  for (invalid in list(0, -1, 1.5, Inf, NA, "2", c(1, 2))) {
    expect_error(step_tmpl_map(identity, 1:2, array_throttle = invalid),
                 "array_throttle")
  }
})

test_that("functions relying on the global environment trigger a warning", {
  skip_if_not_installed("codetools")
  assign("swf_test_global_value", 1, envir = globalenv())
  withr::defer(rm("swf_test_global_value", envir = globalenv()))
  uses_global <- function(x) x + swf_test_global_value
  environment(uses_global) <- globalenv()
  self_contained <- function(x, y) x + y
  environment(self_contained) <- globalenv()

  expect_warning(step_tmpl_do_call(uses_global, list(x = 1)),
                 "`what`.*swf_test_global_value.*`args`")
  expect_warning(step_tmpl_map(uses_global, 1:2),
                 "`FUN`.*swf_test_global_value.*`MoreArgs`")
  expect_no_warning(step_tmpl_do_call(self_contained, list(x = 1, y = 2)))
  expect_no_warning(step_tmpl_map(self_contained, 1:2, MoreArgs = list(y = 1)))
  # Closures keep their own environment: nothing to warn about.
  local_value <- 2
  closure <- function(x) x + local_value
  expect_no_warning(step_tmpl_do_call(closure, list(x = 1)))
  expect_no_warning(step_tmpl_do_call(sum, list(1, 2)))
})

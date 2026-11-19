test_that("create_workflow writes the engine and resolved SWF files", {
  directory <- withr::local_tempdir()
  wf <- create_workflow(
    wf_name = "my-workflow",
    default_sbatch_opts = list(
      partition = "compute",
      account = "project",
      mem = "8G",
      time = 180
    ),
    wf_common_dir = directory
  )
  root <- wf[["root"]]

  expect_true(dir.exists(root))
  expect_true(file.exists(file.path(root, "swf")))
  expect_setequal(
    list.files(file.path(root, "swf.d")),
    c("lib.sh", "controller.sh", "job.sh", "workflow.swf",
      "sbatch_rules.swf", "steps")
  )
  expect_false(file.exists(file.path(root, "workflow.yaml")))
  expect_false(file.exists(file.path(root, "start_workflow.sh")))

  workflow <- read_swf(file.path(root, "swf.d", "workflow.swf"))
  expect_identical(workflow[["opt.partition"]], "compute")
  expect_identical(workflow[["opt.time"]], "180")
  expect_identical(workflow[["ctrl.opt.partition"]], "compute")
  expect_identical(workflow[["ctrl.opt.account"]], "project")
  expect_false("ctrl.opt.mail-user" %in% names(workflow))
  expect_false("ctrl.opt.mail-type" %in% names(workflow))

  rules <- read_swf(file.path(root, "swf.d", "sbatch_rules.swf"))
  expect_identical(rules[["exclusive.mem"]], "mem mem-per-cpu mem-per-gpu")
  expect_identical(
    rules[["reserved"]],
    "dependency job-name output parsable export export-file"
  )
  expect_true("partition" %in% strsplit(rules[["valid"]], " ", fixed = TRUE)[[1L]])
  expect_identical(wf, load_workflow(root))
  expect_named(wf, c("name", "root", "default_sbatch_opts", "steps"))
  expect_length(wf[["steps"]], 0L)
})

test_that("create_workflow validates names, partitions, and reserved options", {
  directory <- withr::local_tempdir()
  expect_error(
    create_workflow("one", list(account = "project"), directory),
    "partition"
  )

  wf <- create_workflow("one", list(partition = "compute"), directory)
  expect_error(
    create_workflow("one", list(partition = "compute"), directory),
    "already exists"
  )
  for (option in get_reserved_sbatch_opts()) {
    expect_error(
      create_workflow(
        option,
        setNames(list(partition = "compute", "anything"),
                 c("partition", option)),
        directory
      ),
      "managed"
    )
  }
  expect_error(
    add_workflow_step(
      wf,
      step_tmpl_bash_lines("true"),
      sbatch_opts = list(`job-name` = "custom")
    ),
    "managed"
  )
})

test_that("a mail-user default makes controllers mail on failure", {
  directory <- withr::local_tempdir()
  wf <- create_workflow(
    "mail",
    list(partition = "compute", `mail-user` = "me@example.org",
         `mail-type` = "END"),
    directory
  )
  workflow <- read_swf(file.path(wf[["root"]], "swf.d", "workflow.swf"))
  expect_identical(workflow[["ctrl.opt.mail-user"]], "me@example.org")
  expect_identical(workflow[["ctrl.opt.mail-type"]], "FAIL")
  expect_identical(workflow[["opt.mail-type"]], "END")
  expect_identical(
    wf[["default_sbatch_opts"]],
    list(partition = "compute", `mail-user` = "me@example.org",
         `mail-type` = "END")
  )
})

test_that("workflow names are validated", {
  directory <- withr::local_tempdir()
  for (invalid in list("a/b", "", "1abc", "_x", "has space", NA_character_,
                       c("a", "b"), 1)) {
    expect_error(
      create_workflow(invalid, list(partition = "compute"), directory),
      "wf_name"
    )
  }
  expect_error(
    create_workflow(strrep("a", 65), list(partition = "compute"), directory),
    "at most 64"
  )
  wf <- create_workflow("ok.name-1_x", list(partition = "compute"), directory)
  expect_identical(wf[["name"]], "ok.name-1_x")
  expect_identical(list.files(directory), "ok.name-1_x")
})

test_that("0.1.x workflow directories are detected", {
  directory <- withr::local_tempdir()
  for (legacy in c("workflow.yaml", "start_workflow.sh")) {
    root <- file.path(directory, paste0("old_", sub("[.].*", "", legacy)))
    dir.create(root)
    writeLines("", file.path(root, legacy))
    expect_error(load_workflow(root), "0.1.x workflow.*rebuild")
    expect_error(
      create_workflow(basename(root), list(partition = "compute"), directory),
      "0.1.x workflow"
    )
    withr::with_envvar(c(SWF_ROOT = root), {
      expect_error(load_workflow(), "0.1.x workflow")
    })
  }
})

test_that("create_workflow makes the swf command executable", {
  skip_if_no_posix_perms()
  directory <- withr::local_tempdir()
  wf <- create_workflow("exec-bit", list(partition = "compute"), directory)
  expect_identical(
    unname(file.access(file.path(wf[["root"]], "swf"), mode = 1L)),
    0L
  )
})

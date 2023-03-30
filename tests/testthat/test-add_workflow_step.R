test_that("`add_workflow_step` produces the right file structure", {
  test_dir <- "workflows"
  withr::local_file(test_dir)

  writeLines(
    c("git pull", "cd /"),
    "dummy.sh"
  )

  writeLines(
    c("x <- 1:4", "cat(x)"),
    "dummy.R"
  )

  wf_name <- "test_step_struct"

  wf <- create_workflow(
    wf_name = wf_name,
    default_sbatch_opts = list(
      "account" = "test_account"
    ),
    wf_common_dir = test_dir
  )


  wf <- add_workflow_step(
    wf,
    step_tmpl = step_tmpl_bash_script(
      bash_script = "dummy.sh"
    ),
    sbatch_opts = list(
      "mem" = "16G",
      "cpus-per-task" = 1,
      "time" = 120
    ),
    step_name = "report"
  )

  file.remove("dummy.sh")

  wf_vars <- make_wf_vars(wf)
  expect_dir_exists(wf_vars[["SWF__CUR_DIR"]])

  expect_file_exists(wf_vars[["SWF__JOB_SCRIPT"]])
  expect_file_exists(wf_vars[["SWF__INSTRUCTIONS_SCRIPT"]])

  wf <- add_workflow_step(
    wf,
    step_tmpl = step_tmpl_rscript(
      r_script = "dummy.R"
    ),
    sbatch_opts = list(
      "mem-per-cpu" = "4G",
      "cpus-per-task" = 1,
      "time" = 120
    ),
    step_name = "report"
  )

  wf <- add_workflow_step(
    wf,
    step_tmpl = step_tmpl_do_call_script(
      r_script = "dummy.R",
      args = c(arg1 = 10, arg2 = 20),
      setup_lines = c(
        ". loadR.sh",
        "Rscript \"R/abce-report.R\""
      )
    ),
    sbatch_opts = list(
      "mem" = "16G",
      "cpus-per-task" = 1,
      "time" = 120
    ),
    step_name = "dummy_do_call"
  )

  file.remove("dummy.R")

  wf <- add_workflow_step(
    wf,
    step_tmpl = step_tmpl_map_script(
      r_script = "dummy_map.R",
      iterator1 = 1:20,
      iterator1 = 20:1,
      MoreArgs = c(arg1 = 10, arg2 = 20),
      setup_lines = c(
        ". loadR.sh",
        "Rscript \"R/abce-report.R\""
      )
    ),
    sbatch_opts = list(
      "mem" = "16G",
      "cpus-per-task" = 1,
      "time" = 120
    ),
    step_name = "dummy_map"
  )

  expect_error({
    add_workflow_step(
      wf,
      step_tmpl = step_tmpl_map(
        function(iterator1, iterator2) cat(iterator1, iterator2),
        iterator1 = 1:20,
        iterator1 = 1:10,
        setup_lines = c(
          ". loadR.sh",
          "Rscript \"R/abce-report.R\""
        )
        ),
      sbatch_opts = list(
        "mem" = "16G",
        "cpus-per-task" = 1,
        "time" = 120
        ),
      step_name = "dummy_map_fail"
    )
  })
})

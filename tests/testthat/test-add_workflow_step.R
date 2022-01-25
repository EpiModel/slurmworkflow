test_that("`add_workflow_step` produces the right file structure", {
  test_dir <- "workflows"
  withr::local_file(test_dir)

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
    step_tmpl = step_tmpl_bash_lines(
      bash_lines = c(
        ". loadR.sh",
        "Rscript \"R/abce-report.R\""
      )
    ),
    sbatch_opts = list(
      "mem" = "16G",
      "cpus-per-task" = 1,
      "time" = 120
    ),
    step_name = "report"
  )

  wf_vars <- make_wf_vars(wf)
  expect_dir_exists(wf_vars[["SWF__CUR_DIR"]])

  expect_file_exists(wf_vars[["SWF__JOB_SCRIPT"]])
  expect_file_exists(wf_vars[["SWF__INSTRUCTIONS_SCRIPT"]])
})

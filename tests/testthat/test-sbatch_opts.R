test_that("exclusive SBATCH options throw errors", {
  expect_error(validate_sbatch_opts(list(mem = 1, `mem-per-cpu` = 1)))
  expect_error(validate_sbatch_opts(list(mem = 1, `mem-per-gpu` = 1)))
  expect_error(validate_sbatch_opts(list(`mem-per-cpu` = 1, `mem-per-gpu` = 1)))
  expect_silent(validate_sbatch_opts(list(mem = NULL, `mem-per-cpu` = 1)))

  expect_error(validate_sbatch_opts(list(`extra-node-info` = 1, hint = 1)))
  expect_error(validate_sbatch_opts(list(hint = 2, `threads-per-core` = 1)))
  expect_error(validate_sbatch_opts(list(
    `threads-per-core` = 1, `ntasks-per-core` = 1
  )))
})

test_that("invalid and reserved SBATCH options throw errors", {
  expect_error(validate_sbatch_opts(list(memory = 1)))
  for (option in get_reserved_sbatch_opts()) {
    expect_error(validate_sbatch_opts(setNames(list("x"), option)), "managed")
  }
})

test_that("step options replace defaults and conflicting options", {
  defaults <- list(partition = "compute", mem = "8G", time = 60)
  updated <- update_sbatch_opts(defaults, list(`mem-per-cpu` = "2G", time = 30))
  expect_identical(
    updated,
    list(partition = "compute", time = 30, `mem-per-cpu` = "2G")
  )
})

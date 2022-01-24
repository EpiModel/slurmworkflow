test_that("exlclusive SBATCH options throw errors", {
  expect_error(validate_sbatch_opts(list("mem" = 1, "mem-per-cpu" = 1)))
  expect_error(validate_sbatch_opts(list("mem" = 1, "mem-per-gpu" = 1)))
  expect_error(validate_sbatch_opts(list("mem-per-cpu" = 1, "mem-per-gpu" = 1)))
  expect_silent(validate_sbatch_opts(list("mem" = NULL, "mem-per-cpu" = 1)))

  expect_error(validate_sbatch_opts(list("extra-node-info" = 1, "hint" = 1)))
  expect_error(validate_sbatch_opts(list("hint" = 2, "threads-per-core" = 1)))
  expect_error(validate_sbatch_opts(
      list("threads-per-core" = 1, "ntasks-per-core" = 1)))
})

test_that("invalid SBATCH options throw errors", {
  expect_error(validate_sbatch_opts(list("memory" = 1)))
})

test_that("SWF files round trip verbatim values", {
  directory <- withr::local_tempdir()
  path <- file.path(directory, "values.swf")
  values <- c(
    empty = "",
    spaces = "  two spaces  ",
    quotes = "single ' and double \"",
    shell = "$HOME * %A %a #value",
    equals = "left=middle=right",
    unicode = "caf\u00e9 \u96ea"
  )

  expect_identical(write_swf(values, path), path)
  expect_identical(read_swf(path), values)
  expect_identical(names(read_swf(path)), names(values))
  expect_length(list.files(directory, pattern = "^\\..*\\.tmp\\."), 0L)
})

test_that("SWF readers ignore comments and blank lines and strip CR", {
  directory <- withr::local_tempdir()
  path <- file.path(directory, "comments.swf")
  writeBin(charToRaw("#!swf-v1\r\n# comment\r\n\r\nkey=a=b # not comment\r\n"), path)
  expect_identical(read_swf(path), c(key = "a=b # not comment"))
})

test_that("SWF writers format integral numbers without scientific notation", {
  directory <- withr::local_tempdir()
  path <- file.path(directory, "numbers.swf")
  write_swf(list(seconds = 180, large = 100000, other = 1e6), path)
  expect_identical(
    read_swf(path),
    c(seconds = "180", large = "100000", other = "1000000")
  )
})

test_that("SWF validation rejects malformed input", {
  directory <- withr::local_tempdir()
  path <- file.path(directory, "bad.swf")

  expect_error(write_swf(c("bad key" = "x"), path), "keys")
  expect_error(write_swf(c(a = "x", a = "y"), path), "unique")
  expect_error(write_swf(c(a = "one\ntwo"), path), "newlines")
  expect_error(write_swf(c(a = "one\rtwo"), path), "newlines")
  expect_error(write_swf(c(a = NA_character_), path), "non-missing")
  expect_error(write_swf(list(a = 1:2), path), "scalars")

  bad_files <- c(
    header = "not-swf\na=b\n",
    missing_equals = "#!swf-v1\nnot-a-pair\n",
    bad_key = "#!swf-v1\nbad key=value\n",
    duplicate = "#!swf-v1\na=1\na=2\n",
    carriage_return = "#!swf-v1\na=left\rright\n"
  )
  for (i in seq_along(bad_files)) {
    writeLines(bad_files[[i]], path, sep = "")
    expect_error(read_swf(path), "SWF|swf|Duplicate|carriage")
  }
})

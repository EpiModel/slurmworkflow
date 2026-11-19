# Platform rules for the tests. Building a workflow is pure R and runs
# everywhere; only the engine (`swf`, `swf.d/*.sh`) needs `/bin/bash` >= 4.2,
# because its shebang is `#!/bin/bash`. See tests/README.md.

# "major.minor" of /bin/bash, or NA when it is missing or not runnable.
engine_bash_version <- function(bash = "/bin/bash") {
  if (.Platform$OS.type == "windows" || !file.exists(bash)) {
    return(NA_character_)
  }
  out <- suppressWarnings(tryCatch(
    system2(
      bash, c("-c", shQuote("echo \"${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}\"")),
      stdout = TRUE, stderr = FALSE
    ),
    error = function(e) NA_character_
  ))
  if (length(out) != 1 || !grepl("^[0-9]+\\.[0-9]+$", out)) {
    return(NA_character_)
  }
  out
}

# TRUE when `/bin/bash` is older than 4.2 (stock macOS: 3.2).
engine_bash_is_old <- function() {
  version <- engine_bash_version()
  !is.na(version) && numeric_version(version) < "4.2"
}

# Tests that run the engine: Unix with /bin/bash >= 4.2.
skip_if_no_engine_bash <- function() {
  skip_on_os("windows")
  version <- engine_bash_version()
  skip_if(is.na(version), "/bin/bash is not available")
  skip_if(
    numeric_version(version) < "4.2",
    paste0("engine needs bash >= 4.2 at /bin/bash; found ", version)
  )
}

# Tests about file permissions: Windows has no executable bit.
skip_if_no_posix_perms <- function() {
  skip_on_os("windows")
}

# Helper Function to Consistently Write Setup Lines

Helper Function to Consistently Write Setup Lines

## Usage

``` r
helper_use_setup_lines(instructions, setup_lines)
```

## Arguments

- instructions:

  Vector of bash lines to be run by the workflow step

- setup_lines:

  Vector of bash lines to be run before the rest of the step
  instructions.

  @return The modified instructions

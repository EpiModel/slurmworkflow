#!/bin/bash
# Shared, non-executable helpers for the slurmworkflow engine.

# .swf files are data, never shell code. Keep that rule even for files whose
# names look trustworthy: users may write messages by hand.
declare -A SWF_VALUES=()
SWF_KEYS=()

function swf_now {
  date '+%Y-%m-%dT%H:%M:%S'
}

function swf_error {
  printf 'swf: %s\n' "$*" >&2
}

# Read one .swf file into SWF_KEYS and SWF_VALUES. SWF_KEYS preserves order;
# the associative array is only an index into the values.
function swf_read {
  local path="$1"
  local line key value
  local line_number=0

  SWF_KEYS=()
  SWF_VALUES=()

  if [[ ! -f "$path" ]]; then
    swf_error "file not found: $path"
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    line="${line%$'\r'}"

    if (( line_number == 1 )); then
      if [[ "$line" != '#!swf-v1' ]]; then
        swf_error "$path: line 1 must be #!swf-v1"
        return 1
      fi
      continue
    fi

    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" != *=* ]]; then
      swf_error "$path:$line_number: expected key=value"
      return 1
    fi

    key="${line%%=*}"
    value="${line#*=}"
    if [[ ! "$key" =~ ^[A-Za-z0-9_.-]+$ ]]; then
      swf_error "$path:$line_number: invalid key: $key"
      return 1
    fi
    if [[ ${SWF_VALUES[$key]+present} ]]; then
      swf_error "$path:$line_number: duplicate key: $key"
      return 1
    fi

    SWF_KEYS+=("$key")
    SWF_VALUES[$key]="$value"
  done < "$path"

  if (( line_number == 0 )); then
    swf_error "$path: empty file (missing #!swf-v1)"
    return 1
  fi
}

# Set STEP_DIR, STEP_N, STEP_NAME and STEP_ID. Names are the canonical runtime
# references. A third argument of "number" also permits an exact numeric N.
function swf_resolve_step {
  local root="$1"
  local reference="$2"
  local allow_number="${3:-}"
  local dir base number name matches=0

  STEP_DIR=''
  STEP_N=''
  STEP_NAME=''
  STEP_ID=''

  if [[ "$allow_number" == number && "$reference" =~ ^[0-9]+$ ]]; then
    :
  elif [[ "$allow_number" == id && "$reference" =~ ^[1-9][0-9]*_[A-Za-z][A-Za-z0-9_-]*$ ]]; then
    :
  elif [[ ! "$reference" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]]; then
    return 1
  fi

  for dir in "$root"/swf.d/steps/*/; do
    [[ -d "$dir" ]] || continue
    base="${dir%/}"
    base="${base##*/}"
    [[ "$base" == *_* ]] || continue
    number="${base%%_*}"
    name="${base#*_}"
    [[ "$number" =~ ^[1-9][0-9]*$ ]] || continue
    [[ "$name" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || continue

    if [[ "$allow_number" == number && "$reference" =~ ^[0-9]+$ ]]; then
      [[ "$number" == "$reference" ]] || continue
    elif [[ "$allow_number" == id ]]; then
      [[ "$base" == "$reference" ]] || continue
    else
      [[ "$name" == "$reference" ]] || continue
    fi

    matches=$((matches + 1))
    STEP_DIR="${dir%/}"
    STEP_N="$number"
    STEP_NAME="$name"
    STEP_ID="${number}_${name}"
  done

  [[ "$matches" == 1 ]]
}

function swf_step_count {
  local root="$1"
  local dir base number name
  local count=0
  for dir in "$root"/swf.d/steps/*/; do
    [[ -d "$dir" ]] || continue
    base="${dir%/}"
    base="${base##*/}"
    [[ "$base" == *_* ]] || continue
    number="${base%%_*}"
    name="${base#*_}"
    [[ "$number" =~ ^[1-9][0-9]*$ ]] || continue
    [[ "$name" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

# Global lock directory and ownership flag. Callers normally install an EXIT
# trap immediately after a successful lock.
SWF_LOCK_DIR=''
SWF_LOCK_HELD=0

function swf_lock {
  local run_dir="$1"
  local attempt
  SWF_LOCK_DIR="$run_dir/lock"
  for (( attempt = 0; attempt < 300; attempt++ )); do
    if mkdir "$SWF_LOCK_DIR" 2>/dev/null; then
      SWF_LOCK_HELD=1
      trap swf_unlock EXIT
      return 0
    fi
    sleep 0.2
  done
  swf_error "could not acquire lock: $SWF_LOCK_DIR"
  return 1
}

function swf_unlock {
  if [[ "$SWF_LOCK_HELD" == 1 ]]; then
    rmdir "$SWF_LOCK_DIR" 2>/dev/null || true
    SWF_LOCK_HELD=0
  fi
}

function swf_history {
  local run_dir="$1"
  local event="$2"
  shift 2
  {
    printf 'time=%s event=%s' "$(swf_now)" "$event"
    printf ' %s' "$@"
    printf '\n'
  } >> "$run_dir/history"
}

function swf_origin_job {
  if [[ -n "${SLURM_ARRAY_JOB_ID:-}" && -n "${SLURM_ARRAY_TASK_ID:-}" ]]; then
    printf '%s_%s\n' "$SLURM_ARRAY_JOB_ID" "$SLURM_ARRAY_TASK_ID"
  else
    printf '%s\n' "${SLURM_JOB_ID:-}"
  fi
}

function swf_value_has_newline {
  [[ "$1" == *$'\n'* || "$1" == *$'\r'* ]]
}

function swf_word_in_list {
  local wanted="$1"
  local list="$2"
  local word
  for word in $list; do
    [[ "$word" == "$wanted" ]] && return 0
  done
  return 1
}

function swf_atomic_write_current {
  local path="$1"
  local stop_time="$2"
  local key
  local dir tmp
  dir="${path%/*}"
  tmp="$dir/.current.swf.tmp.$$"
  {
    printf '#!swf-v1\n'
    for key in "${SWF_KEYS[@]}"; do
      [[ "$key" == stopped ]] && continue
      printf '%s=%s\n' "$key" "${SWF_VALUES[$key]}"
    done
    printf 'stopped=%s\n' "$stop_time"
  } > "$tmp" || return 1
  mv "$tmp" "$path"
}

# Text files copied from Windows may have CRLF endings. Only inspect files
# grep considers text; certificates, RDS files, and other binary payloads are
# left alone. grep and sed are core utilities on the target systems.
function fix_crlf_files {
  local root="$1"
  local file
  while IFS= read -r -d '' file; do
    if grep -Iq $'\r' "$file"; then
      sed -i 's/\r$//' "$file"
    fi
  done < <(find "$root" -type f -print0)
}

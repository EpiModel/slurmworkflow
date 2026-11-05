#!/usr/bin/env bash
#
# Local tests for the default step payload execution.
#
# The harness runs the real step template (`inst/templates/workflow/SWF/step.sh`)
# and `inst/templates/step_dir/job.sh` with a stub `sbatch`. It asserts the
# invariants for the child-shell behavior.
#
# No Slurm, R, or network access is required.
#
# Usage, from the repository root:
#   bash tests/runtime/test-step-shell.sh
#   bash tests/runtime/test-step-shell.sh --verbose

set -uo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
    echo "This test harness requires bash 4 or later." >&2
    exit 2
fi

VERBOSE=0
[[ "${1:-}" == "--verbose" ]] && VERBOSE=1

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
template_dir="$repo_root/inst/templates/workflow"
job_template="$repo_root/inst/templates/step_dir/job.sh"

if [[ ! -f "$template_dir/SWF/step.sh" ]]; then
    echo "Cannot find templates under $template_dir" >&2
    exit 2
fi
if [[ ! -f "$job_template" ]]; then
    echo "Cannot find $job_template" >&2
    exit 2
fi

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/swf-step-shell.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

scenarios=(ok exit0 exit1 exec cd set_u path function return var nonexport nextstep array_env bash_env signal sbatch_missing)

fakebin="$tmp_root/bin"
mkdir -p "$fakebin"

cat > "$fakebin/sbatch" <<'EOF'
#!/usr/bin/env bash
# Stub sbatch: record the call and pretend it succeeded.
{
  printf 'cwd=%s\n' "$PWD"
  printf 'argc=%s\n' "$#"
  i=0
  for arg in "$@"; do
    printf 'arg%d=%s\n' "$i" "$arg"
    i=$((i + 1))
  done
} >> "${SBATCH_LOG:?}"
echo "Submitted batch job 999"
EOF
chmod +x "$fakebin/sbatch"

function write_payload {
    local scenario="$1"
    local file="$2"

    case "$scenario" in
        ok)
            printf '%s\n' 'echo "payload ok"' > "$file"
            ;;
        exit0)
            printf '%s\n' 'echo "payload exit0"' 'exit 0' > "$file"
            ;;
        exit1)
            printf '%s\n' 'echo "payload exit1"' 'exit 1' > "$file"
            ;;
        exec)
            printf '%s\n' 'echo "payload exec"' 'exec true' > "$file"
            ;;
        cd)
            cat > "$file" <<'EOF'
echo "payload cd before: $PWD"
cd "$ALT_DIR"
echo "payload cd after: $PWD"
EOF
            ;;
        set_u)
            cat > "$file" <<'EOF'
set -u
echo "payload set_u"
EOF
            ;;
        path)
            cat > "$file" <<'EOF'
PATH=/nonexistent
export PATH
echo "payload path changed"
EOF
            ;;
        function)
            cat > "$file" <<'EOF'
sbatch() {
    echo "hijacked sbatch" >&2
    return 0
}
echo "payload function defined"
EOF
            ;;
        return)
            cat > "$file" <<'EOF'
echo "payload return before"
return 0
echo "payload return after"
EOF
            ;;
        var)
            cat > "$file" <<'EOF'
SWF__CTRL_SCRIPT=/bogus
echo "payload var changed"
EOF
            ;;
        nonexport)
            cat > "$file" <<'EOF'
printf 'SWF__JOB_ID=%s\n' "${SWF__JOB_ID-<unset>}"
EOF
            ;;
        nextstep)
            cat > "$file" <<'EOF'
printf '3\n' > "$SWF_NEXTSTEP_FILE"
echo "payload nextstep"
EOF
            ;;
        array_env)
            cat > "$file" <<'EOF'
printf 'TASK=%s MAX=%s JOB=%s COUNT=%s OFFSET=%s\n' \
    "${SLURM_ARRAY_TASK_ID-<unset>}" \
    "${SLURM_ARRAY_TASK_MAX-<unset>}" \
    "${SLURM_ARRAY_JOB_ID-<unset>}" \
    "${SLURM_ARRAY_TASK_COUNT-<unset>}" \
    "${SWF__ARRAY_OFFSET-<unset>}"
EOF
            ;;
        bash_env)
            cat > "$file" <<'EOF'
if command -v module_setup_function > /dev/null 2>&1; then
    echo "payload bash_env visible"
else
    echo "payload bash_env missing"
    exit 1
fi
EOF
            ;;
        signal)
            cat > "$file" <<'EOF'
trap 'echo "payload cleanup"' TERM EXIT
echo "payload start"
sleep 30
echo "payload end"
EOF
            ;;
        sbatch_missing)
            # payload that would succeed if sbatch were available
            printf '%s\n' 'echo "payload ok"' > "$file"
            ;;
        *)
            echo "Unknown scenario: $scenario" >&2
            return 1
            ;;
    esac
}

declare -A RC HANDOFF CWD CTRL NEXT STDOUT STDERR

function run_case {
    local scenario="$1"
    local key="$scenario"
    local dir="$tmp_root/$key"
    local wf="$dir/workflow"
    local project="$dir/project"
    local out="$dir/stdout"
    local err="$dir/stderr"
    local rc handoff=0 cwd="" ctrl="" next=""

    mkdir -p "$project" "$dir/tmp" "$dir/alt"
    cp -a "$template_dir" "$wf"
    mkdir -p "$wf/SWF/steps/1"
    cp "$job_template" "$wf/SWF/steps/1/job.sh"
    write_payload "$scenario" "$wf/SWF/steps/1/instructions.sh"

    if [[ "$scenario" == "bash_env" ]]; then
        cat > "$wf/SWF/parent_setup.sh" <<'EOF'
module_setup_function() { :; }
export -f module_setup_function
EOF
    fi

    if [[ "$scenario" == "sbatch_missing" ]]; then
        mkdir -p "$dir/nobin"
    fi

    if ! bash -n "$wf/SWF/step.sh"; then
        echo "Invalid generated step.sh for $key" >&2
        return 1
    fi

    : > "$dir/sbatch.log"

    local -a slurm_env=(
        -u SLURM_TMPDIR
        -u BASH_ENV
        -u SLURM_ARRAY_TASK_ID
        -u SLURM_ARRAY_TASK_MAX
        -u SLURM_ARRAY_JOB_ID
        -u SLURM_ARRAY_TASK_COUNT
        -u SWF__ARRAY_OFFSET
    )
    if [[ "$scenario" == "array_env" ]]; then
        slurm_env=(
            -u SLURM_TMPDIR
            -u BASH_ENV
            SLURM_ARRAY_TASK_ID=2
            SLURM_ARRAY_TASK_MAX=2
            SLURM_ARRAY_JOB_ID=5000
            SLURM_ARRAY_TASK_COUNT=2
            SWF__ARRAY_OFFSET=5
        )
    fi
    if [[ "$scenario" == "bash_env" ]]; then
        slurm_env=(
            -u SLURM_TMPDIR
            BASH_ENV="$wf/SWF/parent_setup.sh"
            SLURM_ARRAY_TASK_ID=2
            SLURM_ARRAY_TASK_MAX=2
            SLURM_ARRAY_JOB_ID=5000
            SLURM_ARRAY_TASK_COUNT=2
            SWF__ARRAY_OFFSET=5
        )
    fi

    local test_path="$fakebin:$PATH"
    if [[ "$scenario" == "sbatch_missing" ]]; then
        test_path="$dir/nobin:$PATH"
    fi

    (
        cd "$project" || exit 99
        env "${slurm_env[@]}" \
            TMP="$dir/tmp" \
            SBATCH_LOG="$dir/sbatch.log" \
            SLURM_JOB_ID=1000 \
            ALT_DIR="$dir/alt" \
            PATH="$test_path" \
            bash "$wf/SWF/steps/1/job.sh" "$wf" 1
    ) > "$out" 2> "$err"
    rc=$?

    if [[ -s "$dir/sbatch.log" ]]; then
        handoff=1
        cwd="$(sed -n 's/^cwd=//p' "$dir/sbatch.log" | head -n 1)"
        ctrl="$(sed -n 's/^arg3=//p' "$dir/sbatch.log" | head -n 1)"
        next="$(sed -n 's/^arg5=//p' "$dir/sbatch.log" | head -n 1)"
    fi

    RC["$key"]="$rc"
    HANDOFF["$key"]="$handoff"
    STDOUT["$key"]="$(cat "$out")"
    STDERR["$key"]="$(cat "$err")"

    if [[ "$cwd" == "$project" ]]; then
        CWD["$key"]="project"
    elif [[ "$cwd" == "$dir/alt" ]]; then
        CWD["$key"]="alt"
    else
        CWD["$key"]="$cwd"
    fi

    if [[ "$ctrl" == "$wf/SWF/controller.sh" ]]; then
        CTRL["$key"]="controller"
    else
        CTRL["$key"]="$ctrl"
    fi
    NEXT["$key"]="$next"

    if (( VERBOSE )); then
        printf '%s\n' "--- $key (rc=$rc, handoff=$handoff) ---"
        printf 'stdout: %s\n' "$(tr '\n' '|' < "$out")"
        printf 'stderr: %s\n' "$(tr '\n' '|' < "$err")"
        printf 'sbatch: %s\n' "$(tr '\n' '|' < "$dir/sbatch.log")"
    fi
}

function cell {
    local scenario="$1"
    local key="$scenario"
    local text="rc=${RC[$key]} h=${HANDOFF[$key]}"

    case "$scenario" in
        cd)       text+=" cwd=${CWD[$key]}" ;;
        var)      text+=" ctrl=${CTRL[$key]}" ;;
        nextstep) text+=" next=${NEXT[$key]}" ;;
        array_env)
            if grep -q '^TASK=2 MAX=2 JOB=5000 COUNT=2 OFFSET=5$' <<< "${STDOUT[$key]}"; then
                text+=" env=ok"
            else
                text+=" env=BAD"
            fi
            ;;
        nonexport)
            if grep -q 'SWF__JOB_ID=1000' <<< "${STDOUT[$key]}"; then
                text+=" var=visible"
            else
                text+=" var=hidden"
            fi
            ;;
        function)
            if grep -q 'hijacked sbatch' <<< "${STDERR[$key]}"; then
                text+=" hijacked=yes"
            else
                text+=" hijacked=no"
            fi
            ;;
        bash_env)
            if grep -q 'payload bash_env visible' <<< "${STDOUT[$key]}"; then
                text+=" visible=yes"
            else
                text+=" visible=no"
            fi
            ;;
    esac

    printf '%s' "$text"
}

failures=0
function check {
    local label="$1"
    local got="$2"
    local want="$3"
    if [[ "$got" != "$want" ]]; then
        printf 'FAIL %-32s got=%q want=%q\n' "$label" "$got" "$want" >&2
        failures=$((failures + 1))
    fi
}

function check_nonzero {
    local label="$1"
    local got="$2"
    if [[ -z "$got" || "$got" == "0" ]]; then
        printf 'FAIL %-32s got=%q want=non-zero\n' "$label" "$got" >&2
        failures=$((failures + 1))
    fi
}

# Run all cases first; then report and assert.
for scenario in "${scenarios[@]}"; do
    if [[ "$scenario" == "signal" ]]; then
        # signal case is run specially below
        continue
    fi
    run_case "$scenario" || exit 1
done

printf '\nBehavior matrix (rc=exit code, h=1 if sbatch was called)\n'
printf '%-30s' "scenario"
printf '%-32s' "default"
printf '\n'
printf '%.0s-' {1..40}
printf '\n'
for scenario in "${scenarios[@]}"; do
    if [[ "$scenario" == "signal" ]]; then
        continue
    fi
    printf '%-30s' "$scenario"
    printf '%-32s' "$(cell "$scenario")"
    printf '\n'
done

# --- Expected invariants ----------------------------------------------------
check "ok rc" "${RC[ok]}" "0"
check "ok handoff" "${HANDOFF[ok]}" "1"
check "exit1 rc" "${RC[exit1]}" "1"
check "exit1 handoff" "${HANDOFF[exit1]}" "0"
check "exit0 handoff" "${HANDOFF[exit0]}" "1"
check "exec handoff" "${HANDOFF[exec]}" "1"
check "cd cwd" "${CWD[cd]}" "project"
check "set_u handoff" "${HANDOFF[set_u]}" "1"
check "set_u rc" "${RC[set_u]}" "0"
check "path handoff" "${HANDOFF[path]}" "1"
check "path rc" "${RC[path]}" "0"
check "function handoff" "${HANDOFF[function]}" "1"
check "var ctrl" "${CTRL[var]}" "controller"
check "return handoff" "${HANDOFF[return]}" "0"
check_nonzero "return rc" "${RC[return]}"
check "nextstep handoff" "${HANDOFF[nextstep]}" "1"
check "nextstep next" "${NEXT[nextstep]}" "3"
check "array_env handoff" "${HANDOFF[array_env]}" "1"
check "array_env env" \
    "$(grep '^TASK=' <<< "${STDOUT[array_env]}")" \
    "TASK=2 MAX=2 JOB=5000 COUNT=2 OFFSET=5"
check "nonexport visibility" \
    "$(grep '^SWF__JOB_ID=' <<< "${STDOUT[nonexport]}")" "SWF__JOB_ID=<unset>"
check "function hijack" \
    "$(grep -c 'hijacked sbatch' <<< "${STDERR[function]}")" "0"
check "bash_env handoff" "${HANDOFF[bash_env]}" "1"
check "bash_env visible" \
    "$(grep 'payload bash_env visible' <<< "${STDOUT[bash_env]}")" "payload bash_env visible"
check "sbatch_missing rc" "${RC[sbatch_missing]}" "127"
check "sbatch_missing handoff" "${HANDOFF[sbatch_missing]}" "0"

# --- Signal forwarding test -------------------------------------------------
signal_dir="$tmp_root/signal"
mkdir -p "$signal_dir/project" "$signal_dir/tmp" "$signal_dir/alt"
cp -a "$template_dir" "$signal_dir/workflow"
mkdir -p "$signal_dir/workflow/SWF/steps/1"
cp "$job_template" "$signal_dir/workflow/SWF/steps/1/job.sh"
cat > "$signal_dir/workflow/SWF/steps/1/instructions.sh" <<'EOF'
trap 'echo "payload cleanup"' TERM EXIT
echo "payload start"
sleep 30
echo "payload end"
EOF
: > "$signal_dir/sbatch.log"
cat > "$signal_dir/run.sh" <<'EOF'
#!/usr/bin/env bash
signal_dir="$1"
cd "$signal_dir/project" || exit 99
env -u SLURM_TMPDIR -u BASH_ENV \
    -u SLURM_ARRAY_TASK_ID -u SLURM_ARRAY_TASK_MAX \
    -u SLURM_ARRAY_JOB_ID -u SLURM_ARRAY_TASK_COUNT -u SWF__ARRAY_OFFSET \
    TMP="$signal_dir/tmp" \
    SBATCH_LOG="$signal_dir/sbatch.log" \
    SLURM_JOB_ID=1000 \
    ALT_DIR="$signal_dir/alt" \
    PATH="$PATH" \
    bash "$signal_dir/workflow/SWF/steps/1/job.sh" "$signal_dir/workflow" 1
EOF
chmod +x "$signal_dir/run.sh"
# Run the signal test in its own process group so we can send TERM to the whole
# group, as Slurm does for a job.
set -m
PATH="$fakebin:$PATH" bash "$signal_dir/run.sh" "$signal_dir" > "$signal_dir/stdout" 2> "$signal_dir/stderr" &
signal_pgid=$!
set +m
sleep 0.5
# Send TERM to the process group, as Slurm does for a job.
kill -TERM -$signal_pgid 2>/dev/null || true
t0=$(date +%s.%N)
wait $signal_pgid 2>/dev/null || true
t1=$(date +%s.%N)
signal_duration=$(echo "$t1 - $t0" | bc)
signal_stdout=$(cat "$signal_dir/stdout")
signal_stderr=$(cat "$signal_dir/stderr")

if grep -q "payload cleanup" <<< "$signal_stdout"; then
    printf 'signal cleanup ran (%.2fs)\n' "$signal_duration"
else
    printf 'FAIL signal cleanup did not run\n' >&2
    printf 'stdout: %s\n' "$signal_stdout" >&2
    printf 'stderr: %s\n' "$signal_stderr" >&2
    failures=$((failures + 1))
fi

if (( failures > 0 )); then
    printf '\n%d assertion(s) failed.\n' "$failures" >&2
    exit 1
fi

printf '\nAll expected behaviors matched.\n'

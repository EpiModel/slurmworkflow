#!/usr/bin/env bash
#
# Local tests for running a step payload in a new shell.
#
# The harness runs the real step template (`inst/templates/workflow/SWF/step.sh`)
# with a stub `sbatch`, once per variant:
#
#   source     today's behaviour: source the payload in the framework shell
#   bash       run the payload with `bash -e -- instructions.sh`
#   subshell   run `( set -e; source instructions.sh )`
#   bash-rc    `bash -e` plus `set +e`/`SWF__RC`/`set -e` around the child
#
# It reports a behaviour matrix and asserts the invariants we care about.
# No Slurm, R, or network access is required.
#
# Usage, from the repository root:
#   bash tests/runtime/test-step-shell.sh
#   bash tests/runtime/test-step-shell.sh --verbose

set -uo pipefail

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

variants=(source bash subshell bash-rc default)
scenarios=(ok exit0 exit1 exec cd set_u path function return var nonexport nextstep array_env)

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

# Replace the block between the two SWF_PAYLOAD_INVOCATION markers.
function replace_payload_block {
    local file="$1"
    local replacement_file="$2"
    local tmp="$file.tmp"

    awk -v replfile="$replacement_file" '
        /^# >>> SWF_PAYLOAD_INVOCATION >>>$/ {
            print
            while ((getline line < replfile) > 0) print line
            close(replfile)
            inblock = 1
            starts++
            next
        }
        /^# <<< SWF_PAYLOAD_INVOCATION <<<$/ {
            inblock = 0
            print
            ends++
            next
        }
        inblock { next }
        { print }
        END { exit(starts == 1 && ends == 1 ? 0 : 1) }
    ' "$file" > "$tmp" || {
        echo "Failed to replace the payload block in $file" >&2
        rm -f "$tmp"
        return 1
    }
    mv "$tmp" "$file"
}

function patch_step_variant {
    local variant="$1"
    local step="$2"
    local repl="$tmp_root/replacement.$variant"

    case "$variant" in
        default)
            return 0
            ;;
        source)
            printf '%s\n' 'source "$SWF__INSTRUCTIONS_SCRIPT"' > "$repl"
            ;;
        bash)
            printf '%s\n' 'env -u BASH_ENV "${BASH:-/bin/bash}" -e -- "$SWF__INSTRUCTIONS_SCRIPT"' > "$repl"
            ;;
        subshell)
            printf '%s\n' '( set -e; source "$SWF__INSTRUCTIONS_SCRIPT" )' > "$repl"
            ;;
        bash-rc)
            cat > "$repl" <<'EOF'
set +e
env -u BASH_ENV "${BASH:-/bin/bash}" -e -- "$SWF__INSTRUCTIONS_SCRIPT"
SWF__RC=$?
set -e
if (( SWF__RC != 0 )); then
    echo "step payload failed: rc=$SWF__RC" >&2
    exit "$SWF__RC"
fi
EOF
            ;;
        *)
            echo "Unknown variant: $variant" >&2
            return 1
            ;;
    esac

    replace_payload_block "$step" "$repl"
}

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
        *)
            echo "Unknown scenario: $scenario" >&2
            return 1
            ;;
    esac
}

declare -A RC HANDOFF CWD CTRL NEXT STDOUT STDERR

function run_case {
    local variant="$1"
    local scenario="$2"
    local key="$variant:$scenario"
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
    patch_step_variant "$variant" "$wf/SWF/step.sh" || return 1

    if ! bash -n "$wf/SWF/step.sh"; then
        echo "Invalid generated step.sh for $key" >&2
        return 1
    fi

    : > "$dir/sbatch.log"

    local -a slurm_env=(
        -u SLURM_ARRAY_TASK_ID
        -u SLURM_ARRAY_TASK_MAX
        -u SLURM_ARRAY_JOB_ID
        -u SLURM_ARRAY_TASK_COUNT
        -u SWF__ARRAY_OFFSET
    )
    if [[ "$scenario" == "array_env" ]]; then
        slurm_env=(
            SLURM_ARRAY_TASK_ID=2
            SLURM_ARRAY_TASK_MAX=2
            SLURM_ARRAY_JOB_ID=5000
            SLURM_ARRAY_TASK_COUNT=2
            SWF__ARRAY_OFFSET=5
        )
    fi

    (
        cd "$project" || exit 99
        env "${slurm_env[@]}" \
            TMP="$dir/tmp" \
            SBATCH_LOG="$dir/sbatch.log" \
            SLURM_JOB_ID=1000 \
            ALT_DIR="$dir/alt" \
            PATH="$fakebin:$PATH" \
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
    local variant="$1"
    local scenario="$2"
    local key="$variant:$scenario"
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
for variant in "${variants[@]}"; do
    for scenario in "${scenarios[@]}"; do
        run_case "$variant" "$scenario" || exit 1
    done
done

printf '\nBehaviour matrix (rc=exit code, h=1 if sbatch was called)\n'
printf '%-30s' "scenario"
for variant in "${variants[@]}"; do
    printf '%-32s' "$variant"
done
printf '\n'
printf '%.0s-' {1..160}
printf '\n'
for scenario in "${scenarios[@]}"; do
    printf '%-30s' "$scenario"
    for variant in "${variants[@]}"; do
        printf '%-32s' "$(cell "$variant" "$scenario")"
    done
    printf '\n'
done

# --- Expected invariants ----------------------------------------------------
for variant in "${variants[@]}"; do
    check "$variant:ok rc" "${RC[$variant:ok]}" "0"
    check "$variant:ok handoff" "${HANDOFF[$variant:ok]}" "1"
    check "$variant:exit1 rc" "${RC[$variant:exit1]}" "1"
    check "$variant:exit1 handoff" "${HANDOFF[$variant:exit1]}" "0"
    check "$variant:nextstep handoff" "${HANDOFF[$variant:nextstep]}" "1"
    check "$variant:nextstep next" "${NEXT[$variant:nextstep]}" "3"
    check "$variant:array_env handoff" "${HANDOFF[$variant:array_env]}" "1"
    check "$variant:array_env env" \
        "$(grep '^TASK=' <<< "${STDOUT[$variant:array_env]}")" \
        "TASK=2 MAX=2 JOB=5000 COUNT=2 OFFSET=5"
done

# Current source: user code runs in the framework shell.
check "source:exit0 handoff" "${HANDOFF[source:exit0]}" "0"
check "source:exec handoff" "${HANDOFF[source:exec]}" "0"
check "source:cd cwd" "${CWD[source:cd]}" "alt"
check "source:set_u handoff" "${HANDOFF[source:set_u]}" "0"
check_nonzero "source:set_u rc" "${RC[source:set_u]}"
check "source:path handoff" "${HANDOFF[source:path]}" "0"
check_nonzero "source:path rc" "${RC[source:path]}"
check "source:function handoff" "${HANDOFF[source:function]}" "0"
check "source:var ctrl" "${CTRL[source:var]}" "/bogus"

# New child shell: user code is isolated, but a top-level `return` breaks.
for variant in bash bash-rc default; do
    check "$variant:exit0 handoff" "${HANDOFF[$variant:exit0]}" "1"
    check "$variant:exec handoff" "${HANDOFF[$variant:exec]}" "1"
    check "$variant:cd cwd" "${CWD[$variant:cd]}" "project"
    check "$variant:set_u handoff" "${HANDOFF[$variant:set_u]}" "1"
    check "$variant:set_u rc" "${RC[$variant:set_u]}" "0"
    check "$variant:path handoff" "${HANDOFF[$variant:path]}" "1"
    check "$variant:path rc" "${RC[$variant:path]}" "0"
    check "$variant:function handoff" "${HANDOFF[$variant:function]}" "1"
    check "$variant:var ctrl" "${CTRL[$variant:var]}" "controller"
    check "$variant:return handoff" "${HANDOFF[$variant:return]}" "0"
    check_nonzero "$variant:return rc" "${RC[$variant:return]}"
done

# Subshell: isolated like the child, but keeps `return` and non-exported vars.
check "subshell:exit0 handoff" "${HANDOFF[subshell:exit0]}" "1"
check "subshell:exec handoff" "${HANDOFF[subshell:exec]}" "1"
check "subshell:cd cwd" "${CWD[subshell:cd]}" "project"
check "subshell:set_u handoff" "${HANDOFF[subshell:set_u]}" "1"
check "subshell:set_u rc" "${RC[subshell:set_u]}" "0"
check "subshell:path handoff" "${HANDOFF[subshell:path]}" "1"
check "subshell:path rc" "${RC[subshell:path]}" "0"
check "subshell:function handoff" "${HANDOFF[subshell:function]}" "1"
check "subshell:var ctrl" "${CTRL[subshell:var]}" "controller"
check "subshell:return handoff" "${HANDOFF[subshell:return]}" "1"
check "subshell:return rc" "${RC[subshell:return]}" "0"

# Non-exported parent variables are visible to source and subshell, not to
# the child shell.
check "source:nonexport visibility" \
    "$(grep '^SWF__JOB_ID=' <<< "${STDOUT[source:nonexport]}")" "SWF__JOB_ID=1000"
check "subshell:nonexport visibility" \
    "$(grep '^SWF__JOB_ID=' <<< "${STDOUT[subshell:nonexport]}")" "SWF__JOB_ID=1000"
check "bash:nonexport visibility" \
    "$(grep '^SWF__JOB_ID=' <<< "${STDOUT[bash:nonexport]}")" "SWF__JOB_ID=<unset>"
check "bash-rc:nonexport visibility" \
    "$(grep '^SWF__JOB_ID=' <<< "${STDOUT[bash-rc:nonexport]}")" "SWF__JOB_ID=<unset>"
check "default:nonexport visibility" \
    "$(grep '^SWF__JOB_ID=' <<< "${STDOUT[default:nonexport]}")" "SWF__JOB_ID=<unset>"

# The function-based sbatch hijack is local to the child/subshell.
check "source:function hijack" \
    "$(grep -c 'hijacked sbatch' <<< "${STDERR[source:function]}")" "1"
check "bash:function hijack" \
    "$(grep -c 'hijacked sbatch' <<< "${STDERR[bash:function]}")" "0"
check "subshell:function hijack" \
    "$(grep -c 'hijacked sbatch' <<< "${STDERR[subshell:function]}")" "0"
check "default:function hijack" \
    "$(grep -c 'hijacked sbatch' <<< "${STDERR[default:function]}")" "0"

if (( failures > 0 )); then
    printf '\n%d assertion(s) failed.\n' "$failures" >&2
    exit 1
fi

printf '\nAll expected behaviours matched.\n'

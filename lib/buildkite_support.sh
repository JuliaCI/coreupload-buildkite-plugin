
# Helper function to kill execution when something goes wrong
function die() {
    echo "ERROR: ${1}" >&2
    if which buildkite-agent >/dev/null 2>/dev/null; then
        # By default, the annotation context is unique to the message
        local CONTEXT=$(echo "${1}" | ${SHASUM})
        if [[ "$#" -gt 1 ]]; then
            CONTEXT="${2}"
        fi
        buildkite-agent annotate --context="${CONTEXT}" --style=error "${1}"
    fi
    exit 1
}

# Helper function to collect a buildkite array
function collect_buildkite_array() {
    local PARAMETER_NAME="${1}"

    local IDX=0
    while [[ -v "${PARAMETER_NAME}_${IDX}" ]]; do
        # Fetch the pattern
        VARNAME="${PARAMETER_NAME}_${IDX}"
        printf "%s\n" "${!VARNAME}"

        IDX=$((${IDX} + 1))
    done
}

# Helper function to collect a glob pattern
function collect_glob_pattern() {
    local target="${1}"
    # Iterate over the glob pattern
    for f in ${target}; do
        # Ignore directories, only list files
        if [[ -f "${f}" ]]; then
            printf "%s\n" "${f}"
        fi
    done
}

# Helper function to assert that a tool is available
function ensure_tool() {
    local TOOL="${1}"
    local REASON="${2}"
    if ! which "${TOOL}" >/dev/null 2>/dev/null; then
        die "Cannot find '${TOOL}', ${REASON}!"
    fi
}

# Helper function to filter out only existant files.
# Also deduplicates the files and removes `/../` from the path.
function filter_existant_files() {
    # Read `stdin` into `INPUT_FILES`
    local INPUT_FILES=()
    readarray -t INPUT_FILES

    # Construct associative array, use that to store de-duplicated filenames
    declare -A OUTPUT_FILES
    for F in "${INPUT_FILES[@]}"; do
        if [[ -f "${F}" ]]; then
            OUTPUT_FILES["$(realpath -s "${F}")"]=1
        fi
    done

    # Output our list of real files, sorted for cleanliness
    printf "%s\n" "${!OUTPUT_FILES[@]}" | sort
}

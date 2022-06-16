function gdb_list_images() {
    local COREFILE="${1}"
    local COREFILE_EXE="${2}"

    # Use gdb to get a list of shared libraries, using `grep` to grab all lines starting with an address,
    # then print only the last token in each line that matches.
    gdb -nh "${COREFILE_EXE}" "${COREFILE}" -batch -ex 'info sharedlibrary' 2>&1 | grep -E '^0x[0-9a-f]+ ' | grep -E -o '[^ ]+$'
}

declare -A COREFILE_EXE_CACHE
function parse_corefile_executable() {
    local COREFILE="${1}"

    if [[ ! -v "COREFILE_EXE_CACHE[${COREFILE}]" ]]; then
        # Automatically determine the executable this corefile came from using `file`:
        # Parse out a `file` command output that looks like:
        # ..., execfn: '/path/to/exe', ...
        # We parse it out by splitting on commas, finding `execfn` and splitting on the colon
        local FILE_OUTPUT="$(file "${COREFILE}" 2>/dev/null | tr ',' '\n')"
        COREFILE_EXE_CACHE["${COREFILE}"]="$(grep "execfn" <<<"${FILE_OUTPUT}" | cut -d':' -f2 | tr -d "'" | xargs)"
    fi
    echo "${COREFILE_EXE_CACHE["${COREFILE}"]}"
}

function collect_bundle_files() {
    local COREFILE="${1}"

    # Get a bunch of images, include the corefile and the executable, then filter to only existant files
    local COREFILE_EXE="$(parse_corefile_executable "${COREFILE}")"
    (gdb_list_images "${COREFILE}" "${COREFILE_EXE}"; echo "${COREFILE}"; echo "${COREFILE_EXE}") | filter_existant_files
}

function run_dbg_command() {
    local COREFILE="${1}"
    local CMD="${2}"

    local COREFILE_EXE="$(parse_corefile_executable "${COREFILE}")"
    gdb -nh "${COREFILE_EXE}" "${COREFILE}" -batch -ex "${CMD}"
}

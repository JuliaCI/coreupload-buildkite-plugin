# Helper function to allow compressing in a pipeline
function compress() {
    if [[ "${COMPRESSOR}" == "zstd" ]]; then
        zstd -q -z -5 -T0 "-"
    elif [[ "${COMPRESSOR}" == "none" ]]; then
        cat "-"
    else
        die "Unknown compressor '${COMPRESSOR}'"
    fi
}

# We need to know what to call things after they've been compressed
function compressed_bundle_names() {
    EXT=""
    if [[ "${CREATE_BUNDLE}" == "true" ]]; then
        EXT="${EXT}.tar"
    fi
    if [[ "${COMPRESSOR}" == "zstd" ]]; then
        EXT="${EXT}.zst"
    fi

    for f in "$@"; do
        echo "${f}${EXT}"
    done
}

function compress_bundle() {
    local COREFILE="${1}"
    local BUNDLE_NAME="$(compressed_bundle_names "${COREFILE}")"

    # Skip out early if we're not doing anything
    if [[ "${COREFILE}" == "${BUNDLE_NAME}" ]]; then
        return
    fi

    if [[ "${CREATE_BUNDLE}" == "true" ]]; then
        # Pass the file list off to `tar` and compress it
        declare -a FILE_LIST
        readarray -t FILE_LIST < <(collect_bundle_files "${COREFILE}")
        tar -f - -h -c "${FILE_LIST[@]}" | compress > "${BUNDLE_NAME}"
    else
        # Compress the file directly
        compress <"${COREFILE}" >"${BUNDLE_NAME}"
    fi
}

# Whether there is room to compress a core and still leave 5 GiB of disk space free,
# assuming zstd output as large as its input, plus 1 GiB for bundled executables and
# libraries.
function has_room_for_bundle() {
    local COREFILE="${1}"
    if [[ "${COMPRESSOR}" == "none" && "${CREATE_BUNDLE}" != "true" ]]; then
        # The core is uploaded as-is
        return 0
    fi
    local NEEDED_KIB=$(( $(file_size_kib "${COREFILE}") + (1 + 5) * 1024 * 1024 ))
    (( $(free_space_kib "$(dirname "${COREFILE}")") >= NEEDED_KIB ))
}

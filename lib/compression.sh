# Helper function to allow compressing in a pipeline
function compress() {
    if [[ "${COMPRESSOR}" == "zstd" ]]; then
        zstd -q -z --adapt=min=5 -T0 "-"
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

    # We are going to use `tar` to bundle together one or more files:
    declare -a FILE_LIST
    if [[ "${CREATE_BUNDLE}" == "true" ]]; then
        readarray -t FILE_LIST < <(collect_bundle_files "${COREFILE}")
    else
        FILE_LIST=( "${COREFILE}" )
    fi

    # Pass the file list off to `tar` and compress it
    tar hc "${FILE_LIST[@]}" | compress > "$(compressed_bundle_names "${COREFILE}")"
}

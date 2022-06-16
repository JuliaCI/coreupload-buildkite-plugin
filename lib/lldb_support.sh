function lldb_list_images() {
    local COREFILE="${1}"

    # Use lldb to get a list of images, filtering out all lines except the ones
    # containing images
    lldb -x -c "${COREFILE}" --batch -o 'image list' -Q 2>/dev/null | grep '^\[' 
}

function parse_lldb_image() {
    # Parse the path out of a line that looks like:
    #
    # [  0] 9ADFFDC8 0x0000000000400000 /path/to/exe (0x0000000)
    # 
    # First, get rid of the variable number of spaces by splitting on `]`
    # then split by spaces and skip the addresses.  Next, strip out any
    # trailing address in parens, and then strip whitespace.
    cut -d']' -f2- | cut -d' ' -f4- | cut -d'(' -f1 | awk '{$1=$1};1'
}

function parse_corefile_executable() {
    local COREFILE="${1}"

    # Use `lldb` to parse out the executable path as the 0th image in the list of loaded images
    lldb_list_images "${COREFILE}" | grep -E "^\[\s*0\] " | parse_lldb_image | filter_existant_files
}

function collect_bundle_files() {
    local COREFILE="${1}"

    # Output the full image list, as well as the corefile, output the list of files
    (lldb_list_images "${COREFILE}" | parse_lldb_image; echo "${COREFILE}") | filter_existant_files
}

function run_dbg_command() {
    local COREFILE="${1}"
    local CMD="${2}"

    lldb -x -c "${COREFILE}" --batch -o "${CMD}" -Q
}

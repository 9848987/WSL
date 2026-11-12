#!/usr/bin/env bash
set -euo pipefail
umask 077

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
installer=${1:-$project_dir/install.sh}
test_root=$(mktemp -d /tmp/wsl-watch-tests.XXXXXXXX)
real_mktemp=$(command -v mktemp)
watch_pid=
passed=0
failed=0

stop_watcher() {
    if [[ -n $watch_pid ]]; then
        kill "$watch_pid" 2>/dev/null || true
        wait "$watch_pid" 2>/dev/null || true
        watch_pid=
    fi
}

cleanup() {
    stop_watcher
    rm -rf -- "$test_root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# Extract the production entry point directly from the self-contained installer.
awk '
    /^XCLIP_SOURCE$/ { finished=1; exit }
    emitting { print }
    /<<\047XCLIP_SOURCE\047/ { emitting=1 }
    END { if (!emitting || !finished) exit 1 }
' "$installer" > "$test_root/bridge"
bash -n "$test_root/bridge"

prepare_case() {
    stop_watcher
    case_dir="$test_root/$1"
    mkdir -p "$case_dir/bin" "$case_dir/runtime" "$case_dir/tmp" \
        "$case_dir/home/.local/lib/xclip-x11/usr/bin" "$case_dir/source/folder"
    printf 'first version\n' > "$case_dir/source/中文 文件.txt"
    printf 'nested file\n' > "$case_dir/source/folder/inside.txt"
    mkfifo "$case_dir/events"

    # Every executable stub below is a Linux process inside this test fixture.
    cat > "$case_dir/bin/powershell.exe" <<'MOCK'
#!/usr/bin/env bash
exec cat "$CASE_DIR/events"
MOCK
    cat > "$case_dir/bin/wslpath" <<'MOCK'
#!/usr/bin/env bash
[[ $# == 2 && $1 == -u ]] || exit 2
printf '%s\n' "$2"
MOCK
    cat > "$case_dir/bin/mktemp" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
arguments=()
for argument in "$@"; do
    case "$argument" in
        /tmp/xclip-request.*|/tmp/chatgpt-clipboard.*)
            argument="$CASE_DIR/tmp/${argument##*/}" ;;
    esac
    arguments+=("$argument")
done
exec "$REAL_MKTEMP" "${arguments[@]}"
MOCK
    cat > "$case_dir/home/.local/lib/xclip-x11/usr/bin/xclip" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
for argument; do :; done
exec 8> "$CASE_DIR/publication.lock"
flock 8
count=0
if [[ -f $CASE_DIR/count ]]; then read -r count < "$CASE_DIR/count"; fi
count=$((count + 1))
cp -- "$argument" "$CASE_DIR/publication.$count"
printf '%s\n' "$count" > "$CASE_DIR/count.next"
mv -- "$CASE_DIR/count.next" "$CASE_DIR/count"
MOCK
    chmod +x "$case_dir/bin/"* "$case_dir/home/.local/lib/xclip-x11/usr/bin/xclip"

    # Keep the FIFO open so EOF cannot masquerade as a bridge failure.
    exec 7<> "$case_dir/events"
    CASE_DIR="$case_dir" REAL_MKTEMP="$real_mktemp" HOME="$case_dir/home" \
        XDG_RUNTIME_DIR="$case_dir/runtime" PATH="$case_dir/bin:$PATH" \
        bash "$test_root/bridge" --watch > "$case_dir/stdout" 2> "$case_dir/stderr" 7>&- &
    watch_pid=$!
}

send_files() {
    local path encoded
    encoded=()
    for path in "$@"; do encoded+=("$(printf '%s' "$path" | base64 -w 0)"); done
    printf 'FILES %s\n' "${encoded[*]}" >&7
}

send_text() {
    printf 'TEXT %s\n' "$(printf '%s' "$1" | base64 -w 0)" >&7
}

wait_for_publication() {
    local expected=$1 attempt count
    for attempt in {1..100}; do
        count=0
        if [[ -f $case_dir/count ]]; then read -r count < "$case_dir/count"; fi
        if ((count >= expected)); then return 0; fi
        if ! kill -0 "$watch_pid" 2>/dev/null; then
            printf '  bridge exited before publication %s\n' "$expected"
            cat "$case_dir/stderr"
            return 1
        fi
        sleep 0.05
    done
    printf '  expected publication %s, received %s\n' "$expected" "$count"
    return 1
}

normal_file_and_directory() {
    local paths
    prepare_case normal
    send_files "$case_dir/source/中文 文件.txt" "$case_dir/source/folder"
    wait_for_publication 1 || return 1
    mapfile -t paths < "$case_dir/publication.1"
    [[ ${#paths[@]} == 2 ]] || return 1
    cmp -- "$case_dir/source/中文 文件.txt" "${paths[0]}" || return 1
    diff -r -- "$case_dir/source/folder" "${paths[1]}" || return 1
    kill -0 "$watch_pid"
}

recopy_modified_file() {
    local first_copy second_copy
    prepare_case recopy
    send_files "$case_dir/source/中文 文件.txt"
    wait_for_publication 1 || return 1
    read -r first_copy < "$case_dir/publication.1"
    cmp -- "$case_dir/source/中文 文件.txt" "$first_copy" || return 1

    printf 'second version\n' > "$case_dir/source/中文 文件.txt"
    send_files "$case_dir/source/中文 文件.txt"
    wait_for_publication 2 || return 1
    read -r second_copy < "$case_dir/publication.2"
    cmp -- "$case_dir/source/中文 文件.txt" "$second_copy" || return 1
    printf 'first version\n' | cmp - "$first_copy"
}

continue_after_copy_failure() {
    local copy_dirs
    prepare_case copy_failure
    # Fail after copying one item, then deliver a valid event to the same process.
    send_files "$case_dir/source/中文 文件.txt" "$case_dir/source/missing.txt"
    send_text '后续文本 😀'
    wait_for_publication 1 || return 1
    printf '%s' '后续文本 😀' | cmp - "$case_dir/publication.1" || return 1
    kill -0 "$watch_pid" || return 1
    copy_dirs=$(find "$case_dir/tmp" -maxdepth 1 -type d -name 'chatgpt-clipboard.*')
    [[ -z $copy_dirs ]]
}

run_test() {
    local label=$1 function_name=$2
    if "$function_name"; then
        printf 'PASS %s\n' "$label"
        passed=$((passed + 1))
    else
        printf 'FAIL %s\n' "$label"
        failed=$((failed + 1))
    fi
    stop_watcher
    exec 7>&-
}

run_test 'normal Unicode file and directory copying' normal_file_and_directory
run_test 'recopying the same path uses the updated content' recopy_modified_file
run_test 'copy failure cleans partial copies and preserves the watcher' continue_after_copy_failure
printf '\n%s passed, %s failed\n' "$passed" "$failed"
((failed == 0))

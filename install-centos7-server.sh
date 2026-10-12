#!/usr/bin/env bash
set -Eeuo pipefail

version=${1:?version required}
commit=${2:?commit required}
expected_hash=${3:?SHA256 required}
server_dir=${4:?server directory required}
archive=${5:?archive required}

[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid version' >&2; exit 2; }
[[ $commit =~ ^[a-f0-9]{40}$ ]] || { echo 'Invalid commit' >&2; exit 2; }
[[ $expected_hash =~ ^[a-f0-9]{64}$ ]] || { echo 'Invalid SHA256' >&2; exit 2; }
[[ $server_dir == "$HOME"/.* && $server_dir != *'..'* ]] || { echo 'Server directory must be inside HOME' >&2; exit 2; }
[[ $archive == "$HOME"/.vscode-centos7-installer-"$commit"/* ]] || { echo 'Unexpected archive path' >&2; exit 2; }

source /etc/os-release
[[ $ID == centos || $ID == rhel ]] && [[ $VERSION_ID == 7 || $VERSION_ID == 7.* ]] && [[ $(uname -m) == x86_64 ]] || {
    echo 'Only CentOS/RHEL 7 x86_64 is supported' >&2; exit 2;
}
[[ -f $archive ]] || { echo 'Archive missing' >&2; exit 2; }
actual_hash=$(sha256sum "$archive" | awk '{print $1}')
[[ $actual_hash == "$expected_hash" ]] || { echo 'Remote SHA256 mismatch' >&2; exit 2; }

stage_dir=$(dirname "$archive")
tar -tzf "$archive" > "$stage_dir/archive-list.txt"
for required in \
    vscode-server/code-latest \
    "vscode-server/code-$commit" \
    "vscode-server/code-$commit-cli" \
    "vscode-server/cli/servers/Stable-$commit/server/node" \
    vscode-server/gnu/libc.so.6; do
    grep -Fxq "$required" "$stage_dir/archive-list.txt" || { echo "Missing archive entry: $required" >&2; exit 2; }
done

mkdir -p "$server_dir"
original="$server_dir/code-$commit"
server_node="$server_dir/cli/servers/Stable-$commit/server/node"

smoke_test() {
    local smoke_log="$stage_dir/smoke.log" smoke_exit
    "$server_node" --version
    set +e
    timeout --signal=TERM --kill-after=2s 12s "$original" serve-web \
        --host 127.0.0.1 --port 0 --accept-server-license-terms \
        --without-connection-token --server-data-dir "$server_dir/.codex-smoke-data" \
        > "$smoke_log" 2>&1
    smoke_exit=$?
    set -e
    if [[ $smoke_exit != 0 && $smoke_exit != 124 ]] || ! grep -q 'Web UI available at http://127.0.0.1:' "$smoke_log"; then
        cat "$smoke_log" >&2
        echo "VS Code Server startup failed (exit $smoke_exit)" >&2
        exit 1
    fi
    echo "SERVER_SMOKE_OK version=$version commit=$commit"
}

finish() {
    rm -f "$archive" "$stage_dir/install-centos7-server.sh" "$stage_dir/archive-list.txt" "$stage_dir/smoke.log"
    rmdir "$stage_dir" 2>/dev/null || true
}

if [[ -x $original && -x $original-cli && -x $server_node ]] &&
   [[ $("$original" --version 2>/dev/null) == "code $version (commit $commit)" ]]; then
    echo 'Matching patched server is already installed; checking startup without replacing files.'
    smoke_test
    finish
    exit 0
fi

if ps -u "$(id -un)" -o args= | grep -F "$original" | grep -v -E 'grep|install-centos7-server' >/dev/null; then
    echo 'A VS Code Server process is active; refusing to replace its files.' >&2
    exit 1
fi

if [[ -f $original ]]; then
    backup="$original.pre-centos7-$(date +%Y%m%dT%H%M%S).bak"
    cp -p "$original" "$backup"
    echo "Original CLI backup: $backup"
fi

tar -xzf "$archive" -C "$server_dir" --strip-components 1 --no-same-owner
"$server_dir/code-latest" --patch-now

version_output=$("$original" --version)
[[ $version_output == "code $version (commit $commit)" ]] || {
    echo "Patched CLI version mismatch: $version_output" >&2; exit 1;
}
smoke_test
finish

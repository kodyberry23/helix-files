#!/usr/bin/env bash
# Launch broot as the persistent sidebar pane, with a unix socket configured
# for IPC from the dispatcher scripts.
#
# IMPORTANT: broot's `--listen <name>` takes a server NAME, not a full path.
# broot itself computes the actual socket path as `/tmp/broot-server-<name>.sock`
# (see src/net/mod.rs::socket_file_path). Passing a `/`-containing string
# makes broot try to bind to `/tmp/broot-server-<that-path>.sock`, which
# fails with ENOENT because the intermediate directories don't exist -
# that's the "error on the socket: No such file or directory" failure mode.
#
# Convention: the server name is just the zellij session name (already
# sanitized to alphanumerics + `-`/`_` by scripts/sessionizer.sh). The
# dispatcher passes the same name to `--send`, so both sides compute the
# same socket path implicitly.

set -euo pipefail

session=${ZELLIJ_SESSION_NAME:-default}
# Strip anything that's not safe (zellij sanitizes already, but defensive).
session=${session//[^A-Za-z0-9_-]/_}

# Stale-socket cleanup from a previous crashed broot.
rm -f "/tmp/broot-server-${session}.sock"

# Export the name so dispatch-to-sidebar.sh (if invoked from a child of
# this pane's process tree) can find it without recomputing.
export BROOT_SERVER="$session"

exec broot --listen "$session"

#!/usr/bin/env bash
# Send a MappableCommand string to the running helix instance via its
# Unix socket (helix-editor/helix PR #13896).
#
# Socket path resolution mirrors helix's own logic in
# helix-term/src/application.rs::start_unix_socket_listener:
#
#   1. $HELIX_SOCKET_PATH if set
#   2. $XDG_RUNTIME_DIR/helix/helix.sock
#   3. /tmp/helix/helix.sock
#
# The wire format is a single MappableCommand string, e.g.:
#   :reload-all                     -> typable command, no args
#   :open /Users/you/file.md        -> typable command with args
#   :vsplit /Users/you/file.md      -> ditto
#   move_char_left                  -> static command, no colon prefix
#
# The PR forbids `write*` and `run-shell-command` server-side; helix
# emits an error message and the command is dropped if forbidden.
#
# Usage: helix-send.sh <command-string>
#
# Examples:
#   helix-send.sh ":reload-all"
#   helix-send.sh ":open /Users/me/notes.md"

set -euo pipefail

cmd=${1:-}
if [[ -z $cmd ]]; then
	echo "helix-send.sh: usage: $0 <command>" >&2
	exit 2
fi

sock_path=${HELIX_SOCKET_PATH:-${XDG_RUNTIME_DIR:-/tmp}/helix/helix.sock}

if [[ ! -S $sock_path ]]; then
	echo "helix-send.sh: no helix socket at $sock_path" >&2
	echo "  (is helix running? was it built from PR #13896?)" >&2
	exit 1
fi

# nc -U speaks Unix-domain. macOS /usr/bin/nc closes the socket on stdin
# EOF naturally; older instructions suggested adding `-N` to force a
# half-close but that flag's meaning has drifted across nc forks and
# macOS rejects it with "invalid tcp adaptive write timeout value".
printf '%s' "$cmd" | nc -U "$sock_path"

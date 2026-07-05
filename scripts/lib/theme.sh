# shellcheck shell=bash
# Theme-system helpers for helix-files. Sourced by apply-theme.sh and
# setup.sh AFTER lib/common.sh (uses info/ok/warn/err/would) and after
# REPO_ROOT is set.
#
# The theme pipeline is zero-dependency bash + BSD awk (system bash is 3.2:
# no associative arrays; BSD awk: no strtonum/gensub). To make that viable,
# theme files and ~/.config/helix-files.toml are valid TOML restricted to:
#   [section] headers, `key = "value"` (values ALWAYS double-quoted), and
#   `#` comments. The parser extracts the first double-quoted group on a
#   matching key line, so a `#` inside a quoted hex value never collides
#   with comment handling.

THEME_USER_CONFIG="$HOME/.config/helix-files.toml"
THEMES_DIR="$REPO_ROOT/themes"
# shellcheck disable=SC2034  # consumed by apply-theme.sh after sourcing
THEME_TEMPLATES_DIR="$REPO_ROOT/themes/templates"

# Every key a canonical themes/<name>.toml must define, as section.key.
# theme_validate reports ALL missing keys at once; render_template fails on
# any {{token}} not in this universe. Single source of truth for the schema.
THEME_REQUIRED_KEYS="meta.name
ui.bg ui.bg_dark ui.bg_surface ui.bg_highlight ui.bg_highlight2
ui.fg ui.fg_bright ui.fg_muted ui.cursor ui.accent ui.accent_alt ui.accent_dim
ui.folder ui.selection_bg ui.selection_fg
colors.red colors.orange colors.yellow colors.green colors.purple colors.blue
syntax.keyword syntax.function syntax.string syntax.type syntax.type_builtin
syntax.constant syntax.number syntax.comment syntax.operator syntax.punctuation
syntax.variable syntax.member syntax.special syntax.namespace
ansi.c0 ansi.c1 ansi.c2 ansi.c3 ansi.c4 ansi.c5 ansi.c6 ansi.c7
ansi.c8 ansi.c9 ansi.c10 ansi.c11 ansi.c12 ansi.c13 ansi.c14 ansi.c15
ansi.fg"

# theme_get <file> <section> <key>
# Print the value of `key = "value"` under [section] ("" = top-level, i.e.
# before any section header). Returns 1 when the file or key is missing.
theme_get() {
	local file=$1 section=$2 key=$3 val
	[[ -f $file ]] || return 1
	val=$(awk -v s="$section" -v k="$key" '
		/^[[:space:]]*\[/ {
			line = $0
			sub(/^[[:space:]]*\[/, "", line)
			sub(/\].*$/, "", line)
			cur = line
			next
		}
		cur == s && $0 ~ ("^[[:space:]]*" k "[[:space:]]*=") {
			if (match($0, /"[^"]*"/)) {
				print substr($0, RSTART + 1, RLENGTH - 2)
				exit
			}
		}
	' "$file")
	[[ -n $val ]] || return 1
	printf '%s\n' "$val"
}

# Create ~/.config/helix-files.toml with defaults when absent. Never
# overwrites an existing file (it's per-machine user preference).
ensure_user_config() {
	[[ -f $THEME_USER_CONFIG ]] && return 0
	if ${DRY_RUN:-false}; then
		would "create $THEME_USER_CONFIG (defaults: nord-aurora, transparency on)"
		return 0
	fi
	mkdir -p "$(dirname "$THEME_USER_CONFIG")"
	cat > "$THEME_USER_CONFIG" <<'EOF'
# helix-files user preferences. Read by scripts/apply-theme.sh (via
# scripts/lib/theme.sh) on every apply / update. Per-machine: created once
# by setup.sh and never overwritten after that.
#
# Parser note: keep values double-quoted - the zero-dependency awk parser
# only reads `key = "value"` lines.

# Active theme - a file name from <helix-files>/themes/ (without .toml).
# Switch with `hft <name>`, or edit this line and run scripts/apply-theme.sh.
theme = "nord-aurora"

[transparency]
# "true": ghostty gets the opacity/blur below. Every other layer (helix,
# zellij, treelix, fzf) already paints terminal-default backgrounds, so
# no per-app change is needed - at opacity 1.0 the terminal default IS the
# opaque theme background. "false" applies opacity 1.0 / blur 0.
# NOTE: ghostty only picks up opacity/blur changes on a full restart.
enabled = "true"
opacity = "0.92"
blur    = "20"
EOF
	ok "created $THEME_USER_CONFIG (defaults: nord-aurora, transparency on)"
}

# Accessors over the user config, with defaults so a missing file (e.g.
# during --dry-run before ensure_user_config ran for real) still resolves.
active_theme()         { theme_get "$THEME_USER_CONFIG" ""            theme   || echo "nord-aurora"; }
transparency_enabled() { theme_get "$THEME_USER_CONFIG" transparency enabled || echo "true"; }
transparency_opacity() { theme_get "$THEME_USER_CONFIG" transparency opacity || echo "0.92"; }
transparency_blur()    { theme_get "$THEME_USER_CONFIG" transparency blur    || echo "20"; }

# List available theme names (basenames of themes/*.toml), for error text.
list_themes() {
	local f
	for f in "$THEMES_DIR"/*.toml; do
		[[ -f $f ]] && basename "$f" .toml
	done
}

# theme_validate <file>
# Check every THEME_REQUIRED_KEYS entry exists, meta.name matches the file
# basename, and every color is #RRGGBB. Reports ALL problems, then fails.
# Single awk pass (same parser shape as render_template's pass 1) - the
# earlier fork-per-key version cost ~52 awk forks per theme, ~0.3s per
# apply across three themes. ERE interval {6} is supported by macOS awk
# (verified on awk 20200816).
theme_validate() {
	local file=$1 base problems
	base=$(basename "$file" .toml)
	# BSD awk rejects embedded newlines in `-v var=val` (same quirk
	# setup_managed_block works around) - flatten the key list to spaces.
	problems=$(awk -v required="${THEME_REQUIRED_KEYS//$'\n'/ }" -v base="$base" '
		/^[[:space:]]*\[/ {
			line = $0
			sub(/^[[:space:]]*\[/, "", line)
			sub(/\].*$/, "", line)
			cur = line
			next
		}
		match($0, /^[[:space:]]*[A-Za-z0-9_]+[[:space:]]*=/) {
			key = $0
			sub(/^[[:space:]]*/, "", key)
			sub(/[[:space:]]*=.*$/, "", key)
			if (match($0, /"[^"]*"/))
				map[cur "." key] = substr($0, RSTART + 1, RLENGTH - 2)
		}
		END {
			n = split(required, req, /[[:space:]]+/)
			for (i = 1; i <= n; i++) {
				k = req[i]
				if (k == "") continue
				if (!(k in map)) {
					printf "  missing key: %s\n", k
				} else if (k == "meta.name") {
					if (map[k] != base)
						printf "  meta.name \"%s\" != filename \"%s\"\n", map[k], base
				} else if (map[k] !~ /^#[0-9A-Fa-f]{6}$/) {
					printf "  bad color (want #RRGGBB): %s = \"%s\"\n", k, map[k]
				}
			}
		}
	' "$file")
	if [[ -n $problems ]]; then
		err "invalid theme $file:"
		printf '%s\n' "$problems" >&2
		return 1
	fi
	return 0
}

# render_template <template> <theme-file> <output>
# Substitute every {{section.key}} in the template with the theme's value.
# Fails (without touching the output) on tokens the theme doesn't define or
# malformed tokens. A substitution token is `{{` IMMEDIATELY followed by
# the key ({{ui.bg}}); `{{ ` with a space is passed through untouched so
# oh-my-posh's own Go-template syntax ({{ .HEAD }}) survives rendering.
# Writes atomically via mktemp + mv so a committed generated file is never
# left half-written.
render_template() {
	local tmpl=$1 theme_file=$2 out=$3 tmp
	if ${DRY_RUN:-false}; then
		would "render $(basename "$tmpl") x $(basename "$theme_file" .toml) -> ${out#"$REPO_ROOT"/}"
		return 0
	fi
	mkdir -p "$(dirname "$out")"
	tmp=$(mktemp) || return 1
	if ! awk '
		NR == FNR {
			# Pass 1: theme file -> map["section.key"] = value
			if ($0 ~ /^[[:space:]]*\[/) {
				line = $0
				sub(/^[[:space:]]*\[/, "", line)
				sub(/\].*$/, "", line)
				cur = line
				next
			}
			if (match($0, /^[[:space:]]*[A-Za-z0-9_]+[[:space:]]*=/)) {
				key = $0
				sub(/^[[:space:]]*/, "", key)
				sub(/[[:space:]]*=.*$/, "", key)
				if (match($0, /"[^"]*"/))
					map[cur "." key] = substr($0, RSTART + 1, RLENGTH - 2)
			}
			next
		}
		{
			# Pass 2: template -> output, substituting {{section.key}}
			line = $0
			while (match(line, /\{\{[A-Za-z0-9_.]+\}\}/)) {
				tok = substr(line, RSTART + 2, RLENGTH - 4)
				if (!(tok in map)) {
					printf "unknown token {{%s}} (not in theme file)\n", tok > "/dev/stderr"
					exit 1
				}
				line = substr(line, 1, RSTART - 1) map[tok] substr(line, RSTART + RLENGTH)
			}
			if (line ~ /\{\{[A-Za-z0-9_.]/) {
				printf "malformed token in template line: %s\n", line > "/dev/stderr"
				exit 1
			}
			print line
		}
	' "$theme_file" "$tmpl" > "$tmp"; then
		rm -f "$tmp"
		err "render failed: $(basename "$tmpl") x $(basename "$theme_file" .toml)"
		return 1
	fi
	mv "$tmp" "$out"
}

# set_pointer_line <file> <anchor-regex> <replacement-line>
# Replace the first line matching anchor with the replacement. Fails loudly
# when the anchor is missing (hand-edited file?); no-ops when the line is
# already correct (keeps apply idempotent and dry-run output honest).
set_pointer_line() {
	local file=$1 anchor=$2 replacement=$3 tmp
	if ! grep -qE "$anchor" "$file"; then
		err "pointer anchor '$anchor' not found in $file (hand-edited?)"
		return 1
	fi
	if grep -qxF "$replacement" "$file"; then
		return 0
	fi
	if ${DRY_RUN:-false}; then
		would "set '$replacement' in ${file#"$REPO_ROOT"/}"
		return 0
	fi
	tmp=$(mktemp) || return 1
	awk -v a="$anchor" -v r="$replacement" '
		!done && $0 ~ a { print r; done = 1; next }
		{ print }
	' "$file" > "$tmp" && mv "$tmp" "$file"
	ok "${file#"$REPO_ROOT"/}: $replacement"
}

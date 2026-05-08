--- helix-vsplit
---
--- Bound to <C-v> in yazi/keymap.toml. When pressed, writes "VSPLIT:<path>"
--- to the file at $YAZI_PICK_MARKER (set by scripts/yazi-pick.sh) and then
--- quits yazi. The wrapper reads that marker and routes the picked file
--- into helix's :vsplit instead of :open.
---
--- Implemented as a plugin (rather than a chained shell+quit keymap) because
--- yazi's `shell` action is async — succ!() returns before the spawned printf
--- runs, so quit fires first, kill_on_drop kills printf, and the marker
--- stays empty. Lua plugins run in-process and synchronously.
---
--- Note: cx access has to be inside `ya.sync()` per yazi's plugin model;
--- direct access from the entry function silently no-ops.

local M = {}

local hovered_path = ya.sync(function()
	local h = cx.active.current.hovered
	return h and tostring(h.url) or nil
end)

function M:entry()
	local path = hovered_path()
	if not path then
		ya.notify { title = "helix-vsplit", content = "no hovered file", level = "warn", timeout = 3 }
		return
	end

	local marker = os.getenv("YAZI_PICK_MARKER")
	if not marker or marker == "" then
		ya.notify {
			title = "helix-vsplit",
			content = "YAZI_PICK_MARKER not set — was yazi launched outside helix's space-e picker?",
			level = "warn",
			timeout = 5,
		}
		return
	end

	local f, err = io.open(marker, "w")
	if not f then
		ya.notify { title = "helix-vsplit", content = "open " .. marker .. " failed: " .. tostring(err), level = "error", timeout = 5 }
		return
	end
	f:write("VSPLIT:" .. path)
	f:close()

	ya.emit("quit", {})
end

return M

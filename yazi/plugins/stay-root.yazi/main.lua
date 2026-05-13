--- @sync entry
---
--- stay-root — confine yazi navigation to $YAZI_LOCK_ROOT.
---
--- The sessionizer (zellij default layout) and the helix `space e` picker
--- (scripts/yazi-pick.sh) export YAZI_LOCK_ROOT to the project root before
--- launching yazi. This plugin replaces the `leave` keybind (h) so that
--- pressing it at the root boundary stays put, while pressing it inside
--- the root behaves like the built-in `leave`.
---
--- Modes (passed as the plugin's first arg):
---   up    (default) — like `leave`, but blocked at the root boundary
---   root            — jump straight back to YAZI_LOCK_ROOT
---
--- If YAZI_LOCK_ROOT is unset (yazi launched outside the sessionizer /
--- helix flow), `up` falls through to the built-in `leave` so plain
--- `yazi` from a shell still behaves normally.

local function get_root()
	local r = os.getenv("YAZI_LOCK_ROOT")
	if not r or r == "" then
		return nil
	end
	return r
end

local function entry(_, job)
	local mode = job.args[1] or "up"
	local root = get_root()

	if mode == "root" then
		if root then
			ya.emit("cd", { Url(root) })
		end
		return
	end

	local cwd = cx.active.current.cwd
	local parent = cwd and cwd.parent or nil
	if not parent then
		return
	end

	if not root then
		ya.emit("leave", {})
		return
	end

	-- Url:starts_with is reflexive, so cwd==root/sub returning to root
	-- is allowed; only parent-of-root (escape) hits the silent no-op.
	if parent:starts_with(Url(root)) then
		ya.emit("cd", { parent })
	end
end

return { entry = entry }

#!/usr/bin/env python3
"""Tests for the repo's zellij config.

A KDL syntax error in zellij/config.kdl breaks every new zellij session with
an opaque parse error, and nothing else in the repo would catch it before a
commit lands. `zellij setup --check` loads the given config and exits nonzero
on a deserialization error, so this test gates config edits.

The pane-frame scenarios drive a throwaway session through a pty with the
real binary and the repo config (isolated ZELLIJ_SOCKET_DIR, so live sessions
are untouched) and count frame glyphs after a forced full repaint. They exist
because zellij's default pane-mode `z` toggled frames off whenever helix's
Ctrl-p ("previous entry" in pickers / prompts / completion) entered pane mode
unnoticed and the next keystroke was `z` (helix view mode).

Run:  python3 scripts/tests/test_zellij_config.py      (exit 0 = all pass)

Scenarios
  1. self-check: a deliberately broken config makes `setup --check` fail
     (proves the checker still catches errors; guards against a zellij
     update quietly turning --check into a no-op)
  2. zellij/config.kdl passes `setup --check`
  3. pane frames are drawn at startup, and Ctrl-p followed by a bare `z`
     leaves them drawn AND drops zellij back to normal mode: a following
     `x` (helix "extend line") must not reach pane mode's CloseFocus, so
     both panes still exist afterwards (the accidental helix chord is inert)
  4. Ctrl-p then Ctrl-z hides the frames, and the same chord again restores
     them (the deliberate toggle still works, both ways)
  5. [hx + treelix] the default layout survives losing its editor pane: after
     the pane is closed the way an accident closes it (zellij close-pane,
     which leaves helix's socket file behind), the first file picked in the
     sidebar spawns ONE replacement editor pane that binds the session's
     helix socket, and the next file picked opens in that pane instead of
     spawning another
"""
import fcntl
import os
import pathlib
import pty
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import termios
import time
import uuid

REPO = pathlib.Path(__file__).resolve().parents[2]
CONFIG = REPO / "zellij" / "config.kdl"
SOCKET_DIR = f"/tmp/zellij-test-{os.getuid()}"
FRAME_GLYPHS = "─│╭╮╰╯┌┐└┘"
# A 30x100 two-pane layout with frames draws ~300 frame glyphs. With frames
# hidden zellij still draws one boundary column between the panes (one glyph
# per row, ~30), so the cutoff sits well clear of both. Pane contents are
# empty (the layout below runs `sleep`), so nothing else contributes.
FRAME_GLYPH_MIN = 120

PROBE_LAYOUT = """\
layout {
    pane split_direction="vertical" {
        pane name="left" size="30%" command="sleep" { args "1000"; }
        pane name="right" focus=true command="sleep" { args "1000"; }
    }
}
"""

failures = []


def check(config: pathlib.Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["zellij", "--config", str(config), "setup", "--check"],
        capture_output=True,
        text=True,
        timeout=30,
    )


# ─── pty-driven session ─────────────────────────────────────────────────────

def key_bytes(tok: str) -> bytes:
    if tok == "Esc":
        return b"\x1b"
    if tok.startswith("C-") and len(tok) == 3:
        return bytes([ord(tok[2].lower()) & 0x1F])
    return tok.encode()


def frame_glyphs(raw: bytes) -> int:
    txt = raw.decode("utf-8", "replace")
    return sum(txt.count(c) for c in FRAME_GLYPHS)


class Session:
    """A zellij session on its own socket dir, driven through a pty."""

    def __init__(self, layout: pathlib.Path, cwd: pathlib.Path = None):
        self.name = "test-" + uuid.uuid4().hex[:8]
        self.env = dict(os.environ, ZELLIJ_SOCKET_DIR=SOCKET_DIR, TERM="xterm-256color")
        self.rows, self.cols = 30, 100
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            try:
                if cwd is not None:
                    os.chdir(cwd)
                os.environ.update(self.env)
                os.execvp("zellij", [
                    "zellij", "--config", str(CONFIG), "--session", self.name,
                    "--new-session-with-layout", str(layout),
                ])
            except OSError:
                os._exit(127)
        self._winsize()

    def _winsize(self):
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ,
                    struct.pack("HHHH", self.rows, self.cols, 0, 0))

    def read_until(self, done, timeout: float) -> bytes:
        """Pump the pty until `done(buf)` holds or the deadline passes."""
        buf = b""
        end = time.time() + timeout
        while time.time() < end and not done(buf):
            r, _, _ = select.select([self.fd], [], [], 0.1)
            if r:
                try:
                    buf += os.read(self.fd, 65536)
                except OSError:
                    break
        return buf

    def wait_for_frames(self, timeout: float = 15) -> bytes:
        return self.read_until(lambda b: frame_glyphs(b) >= FRAME_GLYPH_MIN, timeout)

    def send(self, *keys: str):
        for tok in keys:
            os.write(self.fd, key_bytes(tok))
            # zellij needs the previous key applied before the next arrives
            # (a mode switch, then the key inside that mode)
            self.read_until(lambda b: False, 0.3)

    def repaint(self) -> bytes:
        """zellij paints diffs only; a resize forces a full redraw. The
        post-resize paint always contains the boundary column, so wait for
        at least one row's worth of glyphs and then let the paint finish."""
        self.read_until(lambda b: False, 0.3)
        self.rows += 1
        self.cols += 2
        self._winsize()
        buf = self.read_until(lambda b: frame_glyphs(b) >= self.rows - 2, 10)
        return buf + self.read_until(lambda b: False, 0.8)

    def panes(self) -> list:
        """(id, name) of the terminal panes, via `zellij action list-panes`."""
        r = subprocess.run(["zellij", "--session", self.name, "action", "list-panes"],
                           env=self.env, capture_output=True, text=True, timeout=20)
        panes = []
        for line in r.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 3 and parts[1] == "terminal":
                panes.append((parts[0], parts[2]))
        return panes

    def pane_names(self) -> list:
        return [name for _, name in self.panes()]

    def action(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(["zellij", "--session", self.name, "action", *args],
                              env=self.env, capture_output=True, text=True, timeout=20)

    def pane_env(self) -> dict:
        """The environment a script run from inside one of this session's
        panes would see, as far as the repo's scripts care."""
        return dict(self.env, ZELLIJ="1", ZELLIJ_SESSION_NAME=self.name)

    def close(self):
        # kill-session stops the server; delete-session --force then removes
        # the serialized cache entry. On a custom ZELLIJ_SOCKET_DIR,
        # `delete-session --force` alone does NOT kill the live server (it
        # reports "not found" and exits 2), so both steps stay.
        for cmd in (["kill-session", self.name], ["delete-session", "--force", self.name]):
            try:
                subprocess.run(["zellij", *cmd], env=self.env, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, timeout=20)
            except subprocess.TimeoutExpired:
                print(f"warn: zellij {cmd[0]} {self.name} timed out", file=sys.stderr)
        try:
            os.kill(self.pid, 9)
        except OSError:
            pass
        # The client is the pty's session leader: after SIGKILL it lingers in
        # the exiting state until the master side closes, so close first and
        # only then reap (bounded, so a wedged client cannot hang the suite).
        try:
            os.close(self.fd)
        except OSError:
            pass
        deadline = time.time() + 5
        while time.time() < deadline:
            try:
                pid, _ = os.waitpid(self.pid, os.WNOHANG)
            except OSError:
                break
            if pid:
                break
            time.sleep(0.05)
        else:
            print(f"warn: zellij client {self.pid} did not exit after SIGKILL", file=sys.stderr)


def expect_frames(label: str, raw: bytes, want: bool):
    n = frame_glyphs(raw)
    have = n >= FRAME_GLYPH_MIN
    if have == want:
        print(f"ok: {label} ({n} frame glyphs)")
    else:
        failures.append(f"{label}: expected frames {'drawn' if want else 'hidden'}, "
                        f"counted {n} frame glyphs")


def frame_scenarios(tmp: pathlib.Path):
    layout = tmp / "probe.kdl"
    layout.write_text(PROBE_LAYOUT)

    # 3. accidental chord is inert: frames stay, and mode returns to normal
    s = Session(layout)
    try:
        expect_frames("frames drawn at startup", s.wait_for_frames(), True)
        s.send("C-p", "z")
        expect_frames("Ctrl-p then bare z leaves frames drawn", s.repaint(), True)
        s.send("x")  # helix "extend line"; in pane mode this is CloseFocus
        s.read_until(lambda b: False, 0.5)
        names = s.pane_names()
        if sorted(names) == ["left", "right"]:
            print("ok: Ctrl-p then bare z returns to normal mode (a following x closed nothing)")
        else:
            failures.append("Ctrl-p then bare z left zellij in pane mode: a following x "
                            f"changed the panes to {names} (expected left + right)")
    finally:
        s.close()

    # 4. deliberate toggle works both ways
    s = Session(layout)
    try:
        s.wait_for_frames()
        s.send("C-p", "C-z")
        expect_frames("Ctrl-p then Ctrl-z hides frames", s.repaint(), False)
        s.send("C-p", "C-z")
        expect_frames("Ctrl-p then Ctrl-z again restores frames", s.repaint(), True)
    finally:
        s.close()


def socket_accepts(path: str, timeout: float) -> bool:
    """True once a listener answers on the unix socket at `path`."""
    import socket as socketlib
    end = time.time() + timeout
    while time.time() < end:
        try:
            with socketlib.socket(socketlib.AF_UNIX, socketlib.SOCK_STREAM) as c:
                c.connect(path)
            return True
        except OSError:
            time.sleep(0.2)
    return False


def hx_binds_a_socket(tmp: pathlib.Path) -> bool:
    """Whether the `hx` on PATH has the command-socket patch (PR #13896):
    started with HELIX_SOCKET_PATH it binds that path; stock helix never
    does. `--health` says nothing about it, so probe the behavior."""
    probe = str(tmp / "probe.sock")
    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.environ["HELIX_SOCKET_PATH"] = probe
            os.execvp("hx", ["hx"])
        except OSError:
            os._exit(127)
    try:
        return socket_accepts(probe, 10)
    finally:
        os.kill(pid, 9)
        os.close(fd)
        os.waitpid(pid, 0)
        try:
            os.remove(probe)
        except OSError:
            pass


def editor_pane_scenario(tmp: pathlib.Path):
    """5: losing the editor pane, then picking two files from the sidebar."""
    # launch-editor.sh runs a bare `hx`, so PATH is what counts (the pane
    # inherits this environment).
    if not (shutil.which("hx") and shutil.which("treelix")):
        print("SKIP 5: hx or treelix not on PATH")
        return
    if not hx_binds_a_socket(tmp):
        print("SKIP 5: hx lacks the command socket (not built from local-patches)")
        return
    project = tmp / "project"
    (project / "sub").mkdir(parents=True)
    one = project / "one.rs"
    two = project / "sub" / "two.rs"
    one.write_text("fn one() {}\n")
    two.write_text("fn two() {}\n")
    dispatch = REPO / "scripts" / "dispatch-to-editor.sh"
    s = Session(REPO / "zellij" / "layouts" / "default.kdl", cwd=project)
    env = s.pane_env()
    # The same derivation as lib/common.sh helix_socket_path / treelix_socket_path.
    runtime = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    sock = f"{runtime}/helix/{s.name}.sock"
    sidebar_sock = f"{runtime}/treelix/{s.name}.sock"

    def editors() -> list:
        return [pid for pid, name in s.panes() if name == "editor"]

    try:
        s.wait_for_frames()
        if not socket_accepts(sock, 20):
            failures.append(f"5: the layout's editor pane never bound {sock}")
            return
        # Close the editor pane the way an accident does. helix is killed
        # with the pane, so its socket file stays behind.
        ids = editors()
        if len(ids) != 1:
            failures.append(f"5: expected one editor pane at startup, found {ids}")
            return
        s.action("focus-pane-id", ids[0])
        s.action("close-pane")
        s.read_until(lambda b: False, 1.0)
        if editors():
            failures.append("5: close-pane left the editor pane in place")
            return
        if not os.path.exists(sock):
            print("note: 5: the socket file was cleaned up on close; the stale-file case is not exercised")

        subprocess.run([str(dispatch), "open", str(one)], env=env, cwd=project,
                       capture_output=True, text=True, timeout=30)
        bound = socket_accepts(sock, 20)
        n = len(editors())
        if bound and n == 1:
            print("ok: 5: the first pick spawns one replacement editor pane that binds the session socket")
        else:
            failures.append(f"5: after the first pick: session socket accepting = {bound}, "
                            f"editor panes = {n} (expected True and 1)")
            return

        # The second pick must route into that pane, not spawn another. Wait
        # for the replacement to have opened its file, not just bound.
        if b"one.rs" not in s.read_until(lambda b: b"one.rs" in b, 10):
            failures.append("5: the replacement editor pane never showed one.rs")
            return
        subprocess.run([str(dispatch), "open", str(two)], env=env, cwd=project,
                       capture_output=True, text=True, timeout=30)
        screen = s.read_until(lambda b: b"two.rs" in b, 10) + s.repaint()
        n = len(editors())
        if n == 1 and b"two.rs" in screen:
            print("ok: 5: the second pick opens in the replacement pane (still one editor pane)")
        else:
            failures.append(f"5: after the second pick: editor panes = {n}, "
                            f"two.rs on screen = {b'two.rs' in screen} (expected 1 and True)")
    finally:
        s.close()
        # helix and treelix die with the session and leave their socket
        # files behind.
        for stale in (sock, sidebar_sock):
            try:
                os.remove(stale)
            except OSError:
                pass


def main() -> int:
    if shutil.which("zellij") is None:
        print("SKIP: zellij not installed")
        return 0

    # 1. Self-check: the checker must reject a broken config, otherwise a
    #    green result on the real config proves nothing.
    with tempfile.TemporaryDirectory() as tmp:
        broken = pathlib.Path(tmp) / "broken.kdl"
        broken.write_text('keybinds {\n  normal {\n    bind "Alt x" {\n')
        res = check(broken)
        if res.returncode == 0:
            failures.append(
                "self-check: `zellij setup --check` accepted a malformed "
                "config; it no longer detects parse errors"
            )
        else:
            print("ok: self-check (broken config rejected)")

    # 2. The real config.
    res = check(CONFIG)
    if res.returncode != 0:
        failures.append(
            f"{CONFIG.relative_to(REPO)} failed `zellij setup --check` "
            f"(exit {res.returncode}):\n{res.stdout}\n{res.stderr}"
        )
    else:
        print(f"ok: {CONFIG.relative_to(REPO)} parses")
        # 3-4. Behavior, only meaningful when the config loads.
        os.makedirs(SOCKET_DIR, mode=0o700, exist_ok=True)
        with tempfile.TemporaryDirectory() as tmp:
            frame_scenarios(pathlib.Path(tmp))
        # 5. The default layout with the real hx + treelix.
        with tempfile.TemporaryDirectory() as tmp:
            editor_pane_scenario(pathlib.Path(os.path.realpath(tmp)))

    if failures:
        for f in failures:
            print(f"FAIL: {f}", file=sys.stderr)
        return 1
    print("all pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())

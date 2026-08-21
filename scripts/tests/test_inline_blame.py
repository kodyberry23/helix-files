#!/usr/bin/env python3
"""Behavioral tests for inline git blame in the local-patches hx build.

`cargo test` covers helix-vcs's blame engine and the handler's request
coalescing, but not the editor loop: config loading, the render of the
virtual text, `space B`, runtime `:set`, and the refs watcher. This drives the
installed `hx` through a pty against a throwaway git repo and asserts on the
cleaned terminal stream.

Run:  python3 scripts/tests/test_inline_blame.py      (exit 0 = all pass)

Scenarios
  1. auto-fetch on: blame virtual text appears on the cursor line unprompted
  2. auto-fetch off: nothing appears until `space B`, which then prints the
     line's blame in the statusline
  3. `:set inline-blame.show never` is accepted at runtime
  4. `:set inline-blame.auto-fetch true` at runtime fetches for the open buffer
  5. an external `git commit --amend --author` swaps the rendered author and
     hash without any edit in the editor (refs watcher -> blame refresh)
  6. a file opened inside a linked `git worktree` renders blame
"""
import fcntl
import os
import pty
import re
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import termios
import time

HX = shutil.which("hx") or os.path.expanduser("~/.cargo/bin/hx")
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BASE_CONFIG = os.path.join(REPO_ROOT, "helix", "config.toml")
ESC = re.compile(rb"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07|\x1b[()][A-Z0-9]|\x1b[=>]")
GIT_ENV = {
    **os.environ,
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_CONFIG_SYSTEM": "/dev/null",
    "GIT_TERMINAL_PROMPT": "false",
}


def sh(*cmd, cwd):
    return subprocess.run(cmd, cwd=cwd, check=True, capture_output=True, text=True, env=GIT_ENV).stdout


def clean(raw):
    return ESC.sub(b"", raw).decode("utf-8", "replace")


def config_with(workdir, auto_fetch):
    """Copy of the repo's helix config with inline-blame.auto-fetch overridden."""
    src = open(BASE_CONFIG).read()
    if "auto-fetch = true" not in src:
        sys.exit("helix/config.toml no longer sets `auto-fetch = true`; update this test")
    dst = os.path.join(workdir, f"config-autofetch-{str(auto_fetch).lower()}.toml")
    with open(dst, "w") as fh:
        fh.write(src.replace("auto-fetch = true", f"auto-fetch = {str(auto_fetch).lower()}"))
    return dst


class Hx:
    """One hx process on a pty, 220x40, with the given config and file."""

    def __init__(self, cwd, file, config):
        self.buf = bytearray()
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(cwd)
            os.environ["TERM"] = "xterm-256color"
            os.environ["COLORTERM"] = "truecolor"
            # Never attach this throwaway editor to a live sidebar/socket.
            for key in ("HELIX_SOCKET_PATH", "TREELIX_SOCKET_PATH"):
                os.environ.pop(key, None)
            os.execv(HX, [HX, "-c", config, file])
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 220, 0, 0))

    def pump(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([self.fd], [], [], 0.05)
            if ready:
                try:
                    chunk = os.read(self.fd, 65536)
                except OSError:
                    return
                if not chunk:
                    return
                self.buf.extend(chunk)

    def send(self, keys):
        os.write(self.fd, keys.encode())

    def text(self, since=0):
        return clean(bytes(self.buf[since:]))

    def wait_for(self, pattern, timeout, since=0, redraw=False):
        """Poll the cleaned stream for `pattern`. With `redraw`, ask helix for
        a full repaint every ~2s: an in-place update repaints only the changed
        cells, so a whole-line pattern never lines up in the stream."""
        end = time.time() + timeout
        next_redraw = time.time() + 2.0
        while time.time() < end:
            self.pump(0.2)
            if re.search(pattern, self.text(since)):
                return True
            if redraw and time.time() >= next_redraw:
                self.send(":redraw\r")
                next_redraw = time.time() + 2.0
        return False

    def quit(self):
        self.send(":q!\r")
        self.pump(0.5)
        try:
            os.kill(self.pid, 15)
        except ProcessLookupError:
            pass
        os.waitpid(self.pid, 0)


def main():
    work = tempfile.mkdtemp(prefix="hx-blame-")
    repo = os.path.join(work, "repo")
    os.makedirs(repo)
    sh("git", "init", "-q", "-b", "main", cwd=repo)
    sh("git", "config", "user.email", "one@example.invalid", cwd=repo)
    sh("git", "config", "user.name", "Author One", cwd=repo)
    with open(os.path.join(repo, "notes.txt"), "w") as fh:
        fh.write("first line\nsecond line\n")
    sh("git", "add", "notes.txt", cwd=repo)
    sh("git", "commit", "-q", "-m", "initial notes", cwd=repo)
    sha1 = sh("git", "rev-parse", "--short", "HEAD", cwd=repo).strip()
    cfg_on = config_with(work, True)
    cfg_off = config_with(work, False)
    line_one = r"Author One, .*ago • initial notes • " + re.escape(sha1)
    failures = []

    def check(ok, label, hx, since=0):
        if ok:
            print("OK  ", label)
        else:
            failures.append(label)
            print("FAIL", label)
            print("     ...", hx.text(since)[-500:].replace("\n", "\n     "))

    # 1. auto-fetch on: unprompted virtual text
    hx = Hx(repo, "notes.txt", cfg_on)
    check(hx.wait_for(line_one, 8), "1 auto-fetch renders blame on the cursor line", hx)
    if re.search(r"unknown field|Failed to load config|malformed", hx.text(), re.I):
        check(False, "1 config accepted by the binary", hx)
    # 3. runtime show toggle
    mark = len(hx.buf)
    hx.send(":set inline-blame.show never\r")
    hx.pump(1.0)
    check(not re.search(r"error|unknown|invalid", hx.text(mark), re.I), "3 `:set inline-blame.show never` accepted", hx, mark)
    hx.quit()

    # 2. auto-fetch off: nothing until space B
    hx = Hx(repo, "notes.txt", cfg_off)
    hx.pump(1.5)
    check(not re.search(line_one, hx.text()), "2 auto-fetch off shows no blame unprompted", hx)
    mark = len(hx.buf)
    hx.send(" B")
    check(hx.wait_for(r"Author One, .*ago", 6, since=mark), "2 `space B` prints the line's blame in the statusline", hx, mark)
    # 4. runtime enable of auto-fetch (new document state: blame already
    #    fetched by space B, so use a fresh editor for a clean check)
    hx.quit()
    hx = Hx(repo, "notes.txt", cfg_off)
    hx.pump(1.5)
    mark = len(hx.buf)
    hx.send(":set inline-blame.auto-fetch true\r")
    check(hx.wait_for(line_one, 8, since=mark), "4 `:set inline-blame.auto-fetch true` fetches for the open buffer", hx, mark)
    hx.quit()

    # 5. external amend refreshes the rendered blame
    hx = Hx(repo, "notes.txt", cfg_on)
    check(hx.wait_for(line_one, 8), "5 initial blame before amend", hx)
    mark = len(hx.buf)
    sh("git", "commit", "-q", "--amend", "--no-edit", "--author", "Author Two <two@example.invalid>", cwd=repo)
    sha2 = sh("git", "rev-parse", "--short", "HEAD", cwd=repo).strip()
    line_two = r"Author Two, .*ago • initial notes • " + re.escape(sha2)
    check(hx.wait_for(line_two, 10, since=mark, redraw=True), "5 external amend refreshes the inline blame", hx, mark)
    hx.quit()

    # 6. linked worktree
    worktree = os.path.join(work, "wt")
    sh("git", "worktree", "add", "-q", "-b", "blame-wt", worktree, "main", cwd=repo)
    hx = Hx(worktree, "notes.txt", cfg_on)
    check(hx.wait_for(line_two, 8), "6 blame renders inside a linked worktree", hx)
    hx.quit()

    shutil.rmtree(work, ignore_errors=True)
    if failures:
        print(f"\n{len(failures)} failure(s)")
        return 1
    print("\nALL OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Behavioral tests for diagnostics coloring in the treelix sidebar.

Drives the installed `treelix` through a pty against a throwaway directory,
speaks the reveal-socket protocol to it, and asserts on the colors the terminal
receives. Then, when rust-analyzer is installed, runs the real pipeline: a
scratch cargo crate with one error, `hx` launched with TREELIX_SOCKET_PATH, and
the sidebar turning the file red on its own.

Run:  python3 scripts/tests/test_treelix_diagnostics.py      (exit 0 = all pass)

Scenarios
  1. `diagnostics 2 0 <file>` paints the file name red with a " 2" badge and
     its collapsed parent folder red; `0 1` turns both yellow; `0 0` clears
  2. an executable script is not green (green is reserved for git staged)
  3. [rust-analyzer] hx + treelix end to end: a compile error in main.rs shows
     up red in the sidebar without any action in the editor
  4. git status keeps up with commits made elsewhere: a modified file is
     yellow, and goes back to plain once another process commits it
  5. snapshots (`diagnostics-begin <seq>` ... `diagnostics-end <seq>`, what hx
     sends) replace the whole set atomically, and an older sequence number
     arriving late is ignored
"""
import fcntl
import os
import pty
import re
import select
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time

TREELIX = shutil.which("treelix") or os.path.expanduser("~/.cargo/bin/treelix")
HX = shutil.which("hx") or os.path.expanduser("~/.cargo/bin/hx")
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
THEME = "oh-lucy-evening"
# Palette of the generated theme (treelix/themes/oh-lucy-evening.toml).
RED = (0xD9, 0x55, 0x55)
YELLOW = (0xEF, 0xD4, 0x72)
GREEN = (0x7E, 0xC4, 0x9D)
SGR = re.compile(rb"\x1b\[([0-9;]*)m")
ESC = re.compile(rb"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07|\x1b[()][A-Z0-9]|\x1b[=>]")


def fg_of(rgb):
    return f"{rgb[0]};{rgb[1]};{rgb[2]}"


def fg_from_sgr(params, current):
    """The truecolor foreground an SGR parameter list leaves in effect.
    crossterm packs several attributes into one sequence (`1;38;2;r;g;b;49`),
    so walk the parameters instead of matching a prefix."""
    parts = params.split(";") if params else ["0"]
    i = 0
    fg = current
    while i < len(parts):
        p = parts[i]
        if p in ("0", ""):
            fg = ""
        elif p == "39":
            fg = ""
        elif p == "38" and parts[i + 1:i + 2] == ["2"] and len(parts) >= i + 5:
            fg = ";".join(parts[i + 2:i + 5])
            i += 4
        elif p == "48" and parts[i + 1:i + 2] == ["2"]:
            i += 4
        i += 1
    return fg


def colored_spans(raw):
    """(fg "r;g;b" or "", text) for every run of text in the pty stream, so a
    name can be matched together with the foreground it was painted in."""
    spans = []
    fg = ""
    pos = 0
    for m in re.finditer(rb"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07", raw):
        text = raw[pos:m.start()]
        if text.strip():
            spans.append((fg, text.decode("utf-8", "replace")))
        sgr = SGR.fullmatch(m.group(0))
        if sgr:
            fg = fg_from_sgr(sgr.group(1).decode(), fg)
        pos = m.end()
    return spans


class Pty:
    def __init__(self, argv, cwd, env):
        self.buf = bytearray()
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(cwd)
            os.environ.clear()
            os.environ.update(env)
            os.execv(argv[0], argv)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 80, 0, 0))

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

    def drain_in_background(self):
        """Keep reading this pty so the process never blocks on terminal
        output while the test is watching a different pty (a TUI that cannot
        write stops rendering, and with it every side effect of a render)."""
        def drain():
            while True:
                try:
                    chunk = os.read(self.fd, 65536)
                except OSError:
                    return
                if not chunk:
                    return
                self.buf.extend(chunk)
        threading.Thread(target=drain, daemon=True).start()

    def send(self, keys):
        os.write(self.fd, keys.encode())

    def wait_for_span(self, name, fg, timeout, since=0):
        """True once `name` has been painted with foreground `fg` after `since`."""
        end = time.time() + timeout
        while time.time() < end:
            self.pump(0.2)
            for span_fg, text in colored_spans(bytes(self.buf[since:])):
                if name in text and span_fg == fg:
                    return True
        return False

    def last_fg_of(self, name, since=0):
        last = None
        for span_fg, text in colored_spans(bytes(self.buf[since:])):
            if name in text:
                last = span_fg
        return last

    def quit(self, keys):
        self.send(keys)
        self.pump(0.5)
        try:
            os.kill(self.pid, 15)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(self.pid, 0)
        except ChildProcessError:
            pass


def base_env(sock):
    env = {k: os.environ[k] for k in ("HOME", "PATH", "USER", "LANG") if k in os.environ}
    env.update({
        "TERM": "xterm-256color",
        "COLORTERM": "truecolor",
        "TREELIX_SOCKET_PATH": sock,
        # hx binds its own command socket at startup; give this instance its
        # own so it never collides with an editor already running.
        "HELIX_SOCKET_PATH": sock + ".hx",
    })
    return env


def send_line(sock, line, timeout=10):
    end = time.time() + timeout
    while True:
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                s.connect(sock)
                s.sendall((line + "\n").encode())
            return
        except OSError:
            if time.time() > end:
                raise
            time.sleep(0.1)


def main():
    failures = []

    def check(ok, label, extra=""):
        print(("OK  " if ok else "FAIL"), label)
        if not ok:
            failures.append(label)
            if extra:
                print("     ...", extra[-600:].replace("\n", "\n     "))

    work = tempfile.mkdtemp(prefix="treelix-diag-")
    work = os.path.realpath(work)
    os.makedirs(os.path.join(work, "src"))
    target = os.path.join(work, "src", "main.rs")
    open(target, "w").write("fn main() {}\n")
    script = os.path.join(work, "run.sh")
    open(script, "w").write("#!/bin/sh\n")
    os.chmod(script, 0o755)
    sock = os.path.join(work, "treelix.sock")

    # 1 + 2: protocol-driven coloring
    tl = Pty([TREELIX, "--theme", THEME, work], work, base_env(sock))
    tl.pump(1.5)
    check(tl.wait_for_span("run.sh", "", 3) or tl.last_fg_of("run.sh") not in (fg_of(GREEN),),
          "2 an executable script is not painted staged-green",
          f"run.sh fg = {tl.last_fg_of('run.sh')}")
    mark = len(tl.buf)
    send_line(sock, f"diagnostics 2 0 {target}")
    check(tl.wait_for_span("src", fg_of(RED), 5, since=mark),
          "1 collapsed folder turns red for an error inside it", ESC.sub(b"", bytes(tl.buf[mark:])).decode("utf-8", "replace"))
    # expand src (reveal the file) and look for the badge
    send_line(sock, f"reveal {target}")
    check(tl.wait_for_span("main.rs", fg_of(RED), 5, since=mark) and tl.wait_for_span("2", fg_of(RED), 3, since=mark),
          "1 file name red with its error count", ESC.sub(b"", bytes(tl.buf[mark:])).decode("utf-8", "replace"))
    mark = len(tl.buf)
    send_line(sock, f"diagnostics 0 1 {target}")
    check(tl.wait_for_span("main.rs", fg_of(YELLOW), 5, since=mark), "1 a warning paints it yellow")
    mark = len(tl.buf)
    send_line(sock, f"diagnostics 0 0 {target}")
    tl.pump(1.0)
    check(tl.last_fg_of("main.rs", since=mark) not in (fg_of(RED), fg_of(YELLOW)), "1 clearing restores the plain color",
          f"fg = {tl.last_fg_of('main.rs', since=mark)}")

    # 5: snapshots
    mark = len(tl.buf)
    send_line(sock, f"diagnostics-begin 5\ndiagnostics 1 0 {target}\ndiagnostics-end 5")
    check(tl.wait_for_span("main.rs", fg_of(RED), 5, since=mark), "5 a snapshot colors the file")
    mark = len(tl.buf)
    send_line(sock, "diagnostics-begin 4\ndiagnostics-end 4")
    tl.pump(1.0)
    check(tl.last_fg_of("main.rs", since=mark) in (None, fg_of(RED)), "5 an older snapshot is ignored",
          f"fg = {tl.last_fg_of('main.rs', since=mark)}")
    mark = len(tl.buf)
    send_line(sock, "diagnostics-begin 6\ndiagnostics-end 6")
    tl.pump(1.0)
    check(tl.last_fg_of("main.rs", since=mark) not in (None, fg_of(RED), fg_of(YELLOW)), "5 a newer empty snapshot clears it",
          f"fg = {tl.last_fg_of('main.rs', since=mark)}")
    tl.quit("q")

    # 3: end to end through helix + rust-analyzer
    ra = shutil.which("rust-analyzer")
    if not ra:
        print("SKIP 3 rust-analyzer not installed")
    else:
        crate = os.path.join(work, "crate")
        os.makedirs(os.path.join(crate, "src"))
        open(os.path.join(crate, "Cargo.toml"), "w").write('[package]\nname = "diagdemo"\nversion = "0.1.0"\nedition = "2021"\n')
        bad = os.path.join(crate, "src", "main.rs")
        open(bad, "w").write('fn main() { let x: i32 = "not a number"; }\n')
        subprocess.run(["git", "init", "-q"], cwd=crate, check=True)
        sock2 = os.path.join(work, "treelix2.sock")
        tl = Pty([TREELIX, "--theme", THEME, crate], crate, base_env(sock2))
        tl.pump(1.0)
        send_line(sock2, f"reveal {bad}")
        tl.pump(0.5)
        mark = len(tl.buf)
        hx = Pty([HX, "src/main.rs"], crate, base_env(sock2))
        hx.drain_in_background()
        ok = tl.wait_for_span("main.rs", fg_of(RED), 90, since=mark)
        check(ok, "3 rust-analyzer error reaches the sidebar as red through hx", ESC.sub(b"", bytes(tl.buf[mark:])).decode("utf-8", "replace"))
        hx.quit(":q!\r")
        tl.quit("q")

    # 4: git status refresh after an external commit
    repo = os.path.join(work, "repo")
    os.makedirs(repo)
    git_env = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
               "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@example.invalid",
               "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@example.invalid"}
    def git(*args):
        subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True, env=git_env)
    git("init", "-q", "-b", "main")
    tracked = os.path.join(repo, "notes.txt")
    open(tracked, "w").write("one\n")
    git("add", "notes.txt")
    git("commit", "-q", "-m", "initial")
    sock3 = os.path.join(work, "treelix3.sock")
    tl = Pty([TREELIX, "--theme", THEME, repo], repo, base_env(sock3))
    tl.pump(1.0)
    mark = len(tl.buf)
    open(tracked, "a").write("two\n")
    check(tl.wait_for_span("notes.txt", fg_of(YELLOW), 6, since=mark), "4 a modified tracked file turns yellow")
    mark = len(tl.buf)
    git("commit", "-q", "-am", "second")
    end = time.time() + 8
    cleared = False
    while time.time() < end:
        tl.pump(0.3)
        fg = tl.last_fg_of("notes.txt", since=mark)
        if fg is not None and fg != fg_of(YELLOW):
            cleared = True
            break
    check(cleared, "4 an external commit clears the modified color",
          f"last fg = {tl.last_fg_of('notes.txt', since=mark)}")
    tl.quit("q")

    shutil.rmtree(work, ignore_errors=True)
    if failures:
        print(f"\n{len(failures)} failure(s)")
        return 1
    print("\nALL OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())

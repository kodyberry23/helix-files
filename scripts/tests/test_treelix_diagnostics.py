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
     its collapsed parent folder red; `0 1` turns both yellow; `0 0` clears;
     a report whose casing differs from the on-disk name still colors the file
     (macOS resolves paths case-insensitively, so editors see either casing)
  2. an executable script is not green (green is reserved for git staged)
  3. [rust-analyzer] hx + treelix end to end: a compile error in main.rs shows
     up red in the sidebar without any action in the editor
  4. git status keeps up with commits made elsewhere: a modified file is
     yellow, and goes back to plain once another process commits it
  5. snapshots (`diagnostics-begin [<sender>] <seq>` ... `diagnostics-end
     <seq>`, what hx sends) replace the whole set atomically; an older sequence
     from the same sender arriving late is ignored, while a different sender
     (a restarted editor) is applied whatever its sequence
  6. `diagnostics-bye <sender> <seq>` (an exiting hx) clears the tree only
     when that sender's snapshot is the one on display; a snapshot of its own
     that arrives late is still ignored, and a new sender still applies
  7. [rust-analyzer] fix the error and `:wq` at once, before rust-analyzer
     can republish: the exiting hx retracts its markers, the file goes plain
  8. [rust-analyzer] a file fixed on disk by another program (a file hx is
     not editing, then one it is): hx asks rust-analyzer to re-check, so the
     sidebar clears with no keystroke in the editor, and colors again when
     the error comes back the same way
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
        self.draining = False
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(cwd)
            os.environ.clear()
            os.environ.update(env)
            try:
                os.execv(argv[0], argv)
            except OSError as err:
                sys.stderr.write(f"exec {argv[0]} failed: {err}\n")
                os._exit(127)
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
        write stops rendering, and with it every side effect of a render).
        From then on the drain thread is the pty's only reader."""
        self.draining = True

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
        """Never put ESC and the next key in one write: crossterm reads
        `ESC x` arriving together as Alt-x."""
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

    def wait_for_plain(self, name, timeout, since=0):
        """The first non red/yellow foreground `name` is repainted in after
        `since`, or None if it is not repainted plain within `timeout`."""
        end = time.time() + timeout
        while time.time() < end:
            self.pump(0.3)
            fg = self.last_fg_of(name, since=since)
            if fg is not None and fg not in (fg_of(RED), fg_of(YELLOW)):
                return fg
        return None

    def quit(self, keys):
        try:
            self.send(keys)
        except OSError:
            pass
        if not self.draining:
            self.pump(0.5)
        else:
            time.sleep(0.5)
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
    children = []

    def spawn(argv, cwd, env):
        child = Pty(argv, cwd, env)
        children.append(child)
        return child

    def check(ok, label, extra=""):
        print(("OK  " if ok else "FAIL"), label)
        if not ok:
            failures.append(label)
            if extra:
                print("     ...", extra[-600:].replace("\n", "\n     "))

    work = tempfile.mkdtemp(prefix="treelix-diag-")
    work = os.path.realpath(work)
    try:
        return run(work, failures, check, spawn)
    finally:
        # Whatever happened, no live editor or sidebar is left behind and the
        # scratch tree goes with them.
        for child in children:
            try:
                os.kill(child.pid, 15)
                os.waitpid(child.pid, 0)
            except (ProcessLookupError, ChildProcessError):
                pass
        shutil.rmtree(work, ignore_errors=True)


class LspLog:
    """The methods hx sent rust-analyzer since `mark()`, from `hx -v --log`."""
    METHOD = re.compile(r'rust-analyzer -> .*?"method":"([^"]+)"')

    def __init__(self, path):
        self.path = path
        self.offset = 0

    def _read(self):
        try:
            return open(self.path).read()
        except FileNotFoundError:
            return ""

    def mark(self):
        self.offset = len(self._read())

    def methods_since_mark(self):
        return self.METHOD.findall(self._read()[self.offset:])


def wait_for_exit(child, timeout):
    end = time.time() + timeout
    while time.time() < end:
        try:
            pid, _ = os.waitpid(child.pid, os.WNOHANG)
        except ChildProcessError:
            return True
        if pid:
            return True
        time.sleep(0.05)
    return False


def run(work, failures, check, spawn):
    os.makedirs(os.path.join(work, "src"))
    target = os.path.join(work, "src", "main.rs")
    open(target, "w").write("fn main() {}\n")
    script = os.path.join(work, "run.sh")
    open(script, "w").write("#!/bin/sh\n")
    os.chmod(script, 0o755)
    sock = os.path.join(work, "treelix.sock")

    # 1 + 2: protocol-driven coloring
    tl = spawn([TREELIX, "--theme", THEME, work], work, base_env(sock))
    tl.pump(1.5)
    check(tl.last_fg_of("run.sh") not in (None, fg_of(GREEN)),
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
    check(tl.last_fg_of("main.rs", since=mark) not in (None, fg_of(RED), fg_of(YELLOW)), "1 clearing restores the plain color",
          f"fg = {tl.last_fg_of('main.rs', since=mark)}")

    # 1b: case difference between the editor's report and the on-disk name
    disk_cased = os.path.join(work, "src", "Header.txt")
    open(disk_cased, "w").write("x\n")
    mark = len(tl.buf)
    send_line(sock, f"diagnostics 3 0 {os.path.join(work, 'src', 'header.txt')}")
    check(tl.wait_for_span("Header.txt", fg_of(RED), 5, since=mark),
          "1b a lowercase report colors the on-disk-cased file",
          ESC.sub(b"", bytes(tl.buf[mark:])).decode("utf-8", "replace"))
    send_line(sock, f"diagnostics 0 0 {os.path.join(work, 'src', 'header.txt')}")
    tl.pump(0.8)

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
    mark = len(tl.buf)
    send_line(sock, f"diagnostics-begin hx-restarted 1\ndiagnostics 1 0 {target}\ndiagnostics-end 1")
    check(tl.wait_for_span("main.rs", fg_of(RED), 5, since=mark), "5 a new sender is applied despite a lower sequence")

    # 6: an exiting editor retracts its snapshot, and only its own
    mark = len(tl.buf)
    send_line(sock, "diagnostics-bye hx-someone-else 2")
    tl.pump(1.0)
    check(tl.last_fg_of("main.rs", since=mark) in (None, fg_of(RED)), "6 a farewell from another editor is ignored",
          f"fg = {tl.last_fg_of('main.rs', since=mark)}")
    mark = len(tl.buf)
    send_line(sock, "diagnostics-bye hx-restarted 2")
    tl.pump(1.0)
    check(tl.last_fg_of("main.rs", since=mark) not in (None, fg_of(RED), fg_of(YELLOW)), "6 a farewell from the displayed editor clears it",
          f"fg = {tl.last_fg_of('main.rs', since=mark)}")
    mark = len(tl.buf)
    send_line(sock, f"diagnostics-begin hx-restarted 1\ndiagnostics 1 0 {target}\ndiagnostics-end 1")
    tl.pump(1.0)
    check(tl.last_fg_of("main.rs", since=mark) not in (fg_of(RED), fg_of(YELLOW)), "6 a snapshot that lost the race to the farewell is stale",
          f"fg = {tl.last_fg_of('main.rs', since=mark)}")
    mark = len(tl.buf)
    send_line(sock, f"diagnostics-begin hx-third 1\ndiagnostics 1 0 {target}\ndiagnostics-end 1")
    check(tl.wait_for_span("main.rs", fg_of(RED), 5, since=mark), "6 a new editor still applies after a farewell")
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
        # The error on its own line, so scenario 7 can fix it by deleting the
        # line instead of retyping through helix's auto-pairs.
        open(bad, "w").write('fn main() {}\nfn broken() { let x: i32 = "not a number"; }\n')
        subprocess.run(["git", "init", "-q"], cwd=crate, check=True)
        sock2 = os.path.join(work, "treelix2.sock")
        tl = spawn([TREELIX, "--theme", THEME, crate], crate, base_env(sock2))
        tl.pump(1.0)
        send_line(sock2, f"reveal {bad}")
        tl.pump(0.5)
        mark = len(tl.buf)
        hx = spawn([HX, "src/main.rs"], crate, base_env(sock2))
        hx.drain_in_background()
        ok = tl.wait_for_span("main.rs", fg_of(RED), 90, since=mark)
        check(ok, "3 rust-analyzer error reaches the sidebar as red through hx", ESC.sub(b"", bytes(tl.buf[mark:])).decode("utf-8", "replace"))

        # 7: fix it and quit before rust-analyzer can report the fix
        mark = len(tl.buf)
        hx.send("\x1b")
        time.sleep(0.2)
        hx.send("gg")
        hx.send("j")
        hx.send("xd")
        hx.send(":wq\r")
        exited = wait_for_exit(hx, 10)
        check(exited, "7 hx exits on :wq")
        check(exited and open(bad).read() == "fn main() {}\n", "7 the fix was written", repr(open(bad).read()))
        check(tl.wait_for_plain("main.rs", 8, since=mark) is not None,
              "7 an editor that exits before the LSP republishes does not leave the file red",
              f"last fg = {tl.last_fg_of('main.rs', since=mark)}")
        tl.quit("q")

        # 8: fixed on disk by another program, with no keystroke in hx
        crate = os.path.join(work, "crate8")
        os.makedirs(os.path.join(crate, "src"))
        open(os.path.join(crate, "Cargo.toml"), "w").write('[package]\nname = "diagdemo"\nversion = "0.1.0"\nedition = "2021"\n')
        main = os.path.join(crate, "src", "main.rs")
        other = os.path.join(crate, "src", "other.rs")
        # A borrow-check error: only cargo check reports it, never
        # rust-analyzer's own analysis, so nothing but a re-check clears it.
        moved = 'let s = String::new(); let t = s; println!("{}{}", s, t);'
        fixed = 'let s = String::new(); let t = s.clone(); println!("{}{}", s, t);'
        open(main, "w").write('mod other;\nfn main() { other::f(); }\n')
        open(other, "w").write(f'pub fn f() {{ {moved} }}\n')
        subprocess.run(["git", "init", "-q"], cwd=crate, check=True)
        sock3 = os.path.join(work, "treelix3.sock")
        tl = spawn([TREELIX, "--theme", THEME, crate], crate, base_env(sock3))
        tl.pump(1.0)
        send_line(sock3, f"reveal {main}")
        tl.pump(0.5)
        mark = len(tl.buf)
        # `-v --log`: helix logs every message it sends a server
        # (`rust-analyzer -> {...}`), which pins the mechanism, not just the
        # color it ends in.
        hx_log = LspLog(os.path.join(work, "hx8.log"))
        hx = spawn([HX, "-v", "--log", hx_log.path, "src/main.rs"], crate, base_env(sock3))
        hx.drain_in_background()
        check(tl.wait_for_span("other.rs", fg_of(RED), 90, since=mark),
              "8 a cargo-check error in a file hx is not editing is red",
              ESC.sub(b"", bytes(tl.buf[mark:])).decode("utf-8", "replace"))
        mark = len(tl.buf)
        hx_log.mark()
        open(other, "w").write(f'pub fn f() {{ {fixed} }}\n')
        check(tl.wait_for_plain("other.rs", 45, since=mark) is not None,
              "8 fixing that file on disk clears it with no keystroke in hx",
              f"last fg = {tl.last_fg_of('other.rs', since=mark)}")
        sent = hx_log.methods_since_mark()
        check("rust-analyzer/runFlycheck" in sent and "textDocument/didSave" not in sent,
              "8 hx asked rust-analyzer to re-check the file it is not editing (runFlycheck, no fake save)", str(sent))
        mark = len(tl.buf)
        open(other, "w").write(f'pub fn f() {{ {moved} }}\n')
        check(tl.wait_for_span("other.rs", fg_of(RED), 45, since=mark),
              "8 breaking it again on disk colors it again (the re-check really ran)")
        mark = len(tl.buf)
        open(other, "w").write(f'pub fn f() {{ {fixed} }}\n')
        check(tl.wait_for_plain("other.rs", 45, since=mark) is not None,
              "8 and fixing it once more clears it once more",
              f"last fg = {tl.last_fg_of('other.rs', since=mark)}")
        # A file of another language must not start a cargo check, or cargo's
        # own writes could start a check that starts another.
        hx_log.mark()
        open(os.path.join(crate, "README.md"), "w").write("# demo\n")
        time.sleep(4)
        sent = hx_log.methods_since_mark()
        check("rust-analyzer/runFlycheck" not in sent and "textDocument/didSave" not in sent,
              "8 a README write asks rust-analyzer for nothing", str(sent))
        # The file hx has open: auto-reload picks up the change, and the
        # reload is reported to rust-analyzer as a save.
        mark = len(tl.buf)
        hx_log.mark()
        open(main, "w").write(f'mod other;\nfn main() {{ other::f(); {moved} }}\n')
        check(tl.wait_for_span("main.rs", fg_of(RED), 45, since=mark),
              "8 an error written into the open file on disk is red")
        sent = hx_log.methods_since_mark()
        check(sent.count("textDocument/didSave") == 1 and "rust-analyzer/runFlycheck" not in sent,
              "8 the reload of the open file was reported as one save", str(sent))
        mark = len(tl.buf)
        open(main, "w").write(f'mod other;\nfn main() {{ other::f(); {fixed} }}\n')
        check(tl.wait_for_plain("main.rs", 45, since=mark) is not None,
              "8 fixing the open file on disk clears it with no keystroke in hx",
              f"last fg = {tl.last_fg_of('main.rs', since=mark)}")
        # hx's own :w is one save, not a save plus a watcher-triggered one.
        hx_log.mark()
        hx.send("\x1b")
        time.sleep(0.2)
        hx.send(":w\r")
        time.sleep(4)
        sent = hx_log.methods_since_mark()
        check(sent.count("textDocument/didSave") == 1 and "rust-analyzer/runFlycheck" not in sent,
              "8 hx's own :w is reported once", str(sent))
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
    tl = spawn([TREELIX, "--theme", THEME, repo], repo, base_env(sock3))
    tl.pump(1.0)
    mark = len(tl.buf)
    open(tracked, "a").write("two\n")
    check(tl.wait_for_span("notes.txt", fg_of(YELLOW), 6, since=mark), "4 a modified tracked file turns yellow")
    mark = len(tl.buf)
    git("commit", "-q", "-am", "second")
    check(tl.wait_for_plain("notes.txt", 8, since=mark) is not None, "4 an external commit clears the modified color",
          f"last fg = {tl.last_fg_of('notes.txt', since=mark)}")
    tl.quit("q")

    if failures:
        print(f"\n{len(failures)} failure(s)")
        return 1
    print("\nALL OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())

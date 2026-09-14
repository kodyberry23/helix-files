#!/usr/bin/env python3
"""Behavioral test for the gitlab-ci language in helix/languages.toml.

Opens a deliberately broken `.gitlab-ci.yml` in the installed `hx` through a
pty with `-v --log`, which records every message exchanged with each language
server, and checks that the file is routed to BOTH servers and that each one
reports what it is there for.

Run:  python3 scripts/tests/test_gitlab_ci_lsp.py      (exit 0 = all pass)

Scenarios
  1. `.gitlab-ci.yml` opens as the gitlab-ci language: gitlab-ci-ls and
     yaml-language-server are both started and receive the document
  2. gitlab-ci-ls reports the job graph problems: an `extends` that names no
     job, and a `stage` that is not declared
  3. yaml-language-server reports the structural problem, a key the GitLab
     CI schema does not allow (the schema comes from SchemaStore, so this
     scenario is skipped, not failed, when schemastore.org is unreachable)

Skips when hx or gitlab-ci-ls is not on PATH.
"""
import os
import urllib.request
import pty
import re
import shutil
import subprocess
import sys
import tempfile
import termios
import fcntl
import struct
import threading
import time

HX = shutil.which("hx")
GITLAB_CI_LS = shutil.which("gitlab-ci-ls")

CI_FILE = """\
stages:
  - build

build:
  stage: build
  script:
    - echo build
  extends: .missing

deploy:
  stage: nope
  script:
    - echo deploy
  bogus_key: 1
"""


class Pty:
    def __init__(self, argv, cwd, env):
        self.buf = bytearray()
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
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
        threading.Thread(target=self._drain, daemon=True).start()

    def _drain(self):
        while True:
            try:
                chunk = os.read(self.fd, 65536)
            except OSError:
                return
            if not chunk:
                return
            self.buf.extend(chunk)

    def quit(self):
        try:
            os.write(self.fd, b"\x1b")
            time.sleep(0.2)
            os.write(self.fd, b":q!\r")
        except OSError:
            pass
        time.sleep(0.5)
        try:
            os.kill(self.pid, 15)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(self.pid, 0)
        except ChildProcessError:
            pass


class LspLog:
    """Messages hx exchanged with a server, from `hx -v --log`: the transport
    logs `<server> -> {json}` for what hx sent and `<server> <- {json}` for
    what came back."""

    def __init__(self, path):
        self.path = path

    def _lines(self):
        try:
            return open(self.path).read().splitlines()
        except FileNotFoundError:
            return []

    def sent(self, server, method):
        return [l for l in self._lines() if f"{server} -> " in l and f'"method":"{method}"' in l]

    def received(self, server, method):
        return [l for l in self._lines() if f"{server} <- " in l and f'"method":"{method}"' in l]

    def wait(self, predicate, timeout):
        end = time.time() + timeout
        while time.time() < end:
            if predicate():
                return True
            time.sleep(0.3)
        return predicate()


SCHEMASTORE = "https://www.schemastore.org/api/json/catalog.json"


def schemastore_reachable():
    try:
        with urllib.request.urlopen(SCHEMASTORE, timeout=5) as r:
            return r.status == 200
    except Exception:
        return False


def diagnostics_messages(lines):
    return re.findall(r'"message":"((?:[^"\\]|\\.)*)"', "\n".join(lines))


def main():
    if not (HX and GITLAB_CI_LS):
        print("SKIP: hx or gitlab-ci-ls not on PATH")
        return 0
    failures = []

    def check(ok, label, extra=""):
        print(("OK  " if ok else "FAIL"), label)
        if not ok:
            failures.append(label)
            if extra:
                print("     ...", extra[-800:].replace("\n", "\n     "))

    work = os.path.realpath(tempfile.mkdtemp(prefix="gitlabci-"))
    subprocess.run(["git", "init", "-q"], cwd=work, check=True)
    ci = os.path.join(work, ".gitlab-ci.yml")
    open(ci, "w").write(CI_FILE)
    log_path = os.path.join(work, "hx.log")
    env = {k: os.environ[k] for k in ("HOME", "PATH", "USER", "LANG") if k in os.environ}
    env.update({
        "TERM": "xterm-256color",
        "COLORTERM": "truecolor",
        # Its own sockets, so a live editor and sidebar are never touched.
        "HELIX_SOCKET_PATH": os.path.join(work, "hx.sock"),
        "TREELIX_SOCKET_PATH": os.path.join(work, "tl.sock"),
    })
    log = LspLog(log_path)
    hx = Pty([HX, "-v", "--log", log_path, ".gitlab-ci.yml"], work, env)
    try:
        # 1. both servers start and get the document
        for server in ("gitlab-ci-ls", "yaml-language-server"):
            started = log.wait(lambda: log.sent(server, "textDocument/didOpen"), 30)
            check(started, f"1 {server} is started for .gitlab-ci.yml and receives the document",
                  "\n".join(log._lines()[-20:]))

        # 2. gitlab-ci-ls: job graph diagnostics
        got = log.wait(lambda: len(diagnostics_messages(log.received("gitlab-ci-ls", "textDocument/publishDiagnostics"))) >= 2, 30)
        msgs = diagnostics_messages(log.received("gitlab-ci-ls", "textDocument/publishDiagnostics"))
        joined = "\n".join(msgs)
        check(got and ".missing" in joined, "2 gitlab-ci-ls reports the extends that names no job", joined)
        check(got and "nope" in joined, "2 gitlab-ci-ls reports the stage that is not declared", joined)

        # 3. yaml-language-server: schema diagnostics (SchemaStore, network)
        if not schemastore_reachable():
            print("SKIP 3 schemastore.org unreachable; the GitLab CI schema cannot be fetched")
        else:
            got = log.wait(lambda: any("bogus_key" in m for m in diagnostics_messages(
                log.received("yaml-language-server", "textDocument/publishDiagnostics"))), 60)
            msgs = diagnostics_messages(log.received("yaml-language-server", "textDocument/publishDiagnostics"))
            check(got, "3 yaml-language-server reports the key the GitLab CI schema rejects",
                  "\n".join(msgs))
    finally:
        hx.quit()
        shutil.rmtree(work, ignore_errors=True)

    print()
    if failures:
        print(f"{len(failures)} FAILED")
        return 1
    print("ALL OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())

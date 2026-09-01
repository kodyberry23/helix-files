#!/usr/bin/env python3
"""Smoke test: the repo's zellij config parses.

A KDL syntax error in zellij/config.kdl breaks every new zellij session with
an opaque parse error, and nothing else in the repo would catch it before a
commit lands. `zellij setup --check` loads the given config and exits nonzero
on a deserialization error, so this test gates config edits.

Run:  python3 scripts/tests/test_zellij_config.py      (exit 0 = all pass)

Scenarios
  1. self-check: a deliberately broken config makes `setup --check` fail
     (proves the checker still catches errors; guards against a zellij
     update quietly turning --check into a no-op)
  2. zellij/config.kdl passes `setup --check`
"""
import pathlib
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parents[2]
CONFIG = REPO / "zellij" / "config.kdl"

failures = []


def check(config: pathlib.Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["zellij", "--config", str(config), "setup", "--check"],
        capture_output=True,
        text=True,
        timeout=30,
    )


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

    if failures:
        for f in failures:
            print(f"FAIL: {f}", file=sys.stderr)
        return 1
    print("all pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())

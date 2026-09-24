#!/usr/bin/env python3
"""Exercise the CLI through a real controlling pseudo-terminal on macOS.

Usage: python3 Scripts/test-session.py /absolute/path/to/publish-dev
A tiny fake swift command makes build success/failure and cancellation deterministic;
Python serving, process management, locks, signals, and terminal input are real.
"""

import hashlib
import os
import pathlib
import pty
import select
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

BINARY = str(pathlib.Path(sys.argv[1]).resolve())
HINT = "Press Return or Ctrl+C"
SESSIONS = []


def eventually(predicate, description, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.025)
    raise AssertionError(description)


def port_is_free(port):
    with socket.socket() as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            listener.bind(("127.0.0.1", port))
            return True
        except OSError:
            return False


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def process_exists(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


class Session:
    def __init__(self, site, port, environment):
        self.pid, self.terminal = pty.fork()
        if self.pid == 0:
            os.execve(BINARY, [BINARY, "--site", str(site), "--port", str(port)], environment)
        self.output = ""
        self.status = None
        SESSIONS.append(self)

    def read(self):
        if self.terminal is None:
            return
        while select.select([self.terminal], [], [], 0)[0]:
            try:
                data = os.read(self.terminal, 65536)
            except OSError:
                return
            if not data:
                return
            self.output += data.decode(errors="replace")

    def expect(self, text, after=0):
        def found():
            self.read()
            return text in self.output[after:]
        try:
            eventually(found, f"Missing {text!r}")
        except AssertionError as error:
            raise AssertionError(f"{error}\n{self.output}") from error

    def send(self, text):
        os.write(self.terminal, text)

    def exited(self):
        self.read()
        if self.status is None:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.status = os.waitstatus_to_exitcode(status)
        return self.status is not None

    def wait(self, expected=0):
        eventually(self.exited, f"Session {self.pid} did not exit: {self.output}")
        assert self.status == expected, (self.status, self.output)

    def close_terminal(self):
        os.close(self.terminal)
        self.terminal = None

    def cleanup(self):
        if not self.exited():
            os.kill(self.pid, signal.SIGTERM)
            try:
                eventually(self.exited, "cleanup", timeout=3)
            except AssertionError:
                os.kill(self.pid, signal.SIGKILL)
                os.waitpid(self.pid, 0)
        if self.terminal is not None:
            self.close_terminal()


def session_lock(session):
    # Foundation canonicalizes macOS system paths differently from pathlib.resolve().
    website = session.output.split("Website: ", 1)[1].splitlines()[0]
    identifier = hashlib.sha256(website.encode()).hexdigest()
    return pathlib.Path(tempfile.gettempdir()) / f"publish-dev-{os.getuid()}-{identifier}.lock"


def ready(site, port, environment):
    session = Session(site, port, environment)
    session.expect("Preview updated")
    session.expect(HINT, after=session.output.index("Preview updated"))
    with urllib.request.urlopen(f"http://127.0.0.1:{port}", timeout=2) as response:
        assert b"fixture" in response.read()
    return session


def run(folder):
    site = folder / "site"
    site.mkdir()
    (site / "Package.swift").touch()
    inputs = site / "Sources"
    inputs.mkdir()
    commands = folder / "bin"
    commands.mkdir()
    swift = commands / "swift"
    swift.write_text('''#!/usr/bin/env python3
import json, pathlib, subprocess, sys
site = pathlib.Path.cwd()
if sys.argv[1:] == ["package", "dump-package"]:
    print(json.dumps({"products": [{"name": "Fixture", "type": {"executable": None}}]}))
elif (site / "Sources" / "slow").exists():
    child = subprocess.Popen(["/bin/sleep", "120"], start_new_session=True)
    (site / "child.pid").write_text(str(child.pid))
    child.wait()
elif (site / "Sources" / "fail").exists():
    sys.exit(1)
else:
    (site / "Output").mkdir(exist_ok=True)
    (site / "Output" / "index.html").write_text("<html><body>fixture</body></html>")
''')
    swift.chmod(0o700)
    environment = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ["PATH"])
    port = free_port()

    for stop in (b"\n", b"\x03", b"\x04", signal.SIGTERM, signal.SIGHUP, "close", signal.SIGKILL):
        session = ready(site, port, environment)
        if isinstance(stop, bytes):
            session.send(stop)
        elif stop == "close":
            session.close_terminal()
        else:
            os.kill(session.pid, stop)
        session.wait(-signal.SIGKILL if stop == signal.SIGKILL else 0)
        eventually(lambda: port_is_free(port), f"Port leaked after {stop!r}")
        print(f"PASS shutdown {stop!r}", flush=True)

    session = ready(site, port, environment)
    marker = len(session.output)
    (inputs / "fail").touch()
    session.expect("Build failed", after=marker)
    session.expect(HINT, after=session.output.index("Build failed", marker))
    (inputs / "fail").unlink()
    session.send(b"\n")
    session.wait()
    print("PASS stop hint after a failed build", flush=True)

    first = ready(site, port, environment)
    declined = Session(site, port, environment)
    declined.expect("Stop that session and restart here?")
    declined.send(b"\n")
    declined.wait()
    assert not first.exited()
    interrupted = Session(site, port, environment)
    interrupted.expect("Stop that session and restart here?")
    interrupted.send(b"\x03")
    interrupted.wait()
    assert not first.exited()
    second = Session(site, port, environment)
    second.expect("Stop that session and restart here?")
    second.send(b"yes\n")
    first.wait()
    second.expect("Preview updated")
    second.send(b"\n")
    second.wait()
    print("PASS same-site replacement, default decline, and prompt cancellation", flush=True)

    other = folder / "other-site"
    other.mkdir()
    (other / "Package.swift").touch()
    first = ready(site, port, environment)
    second = Session(other, port, environment)
    second.expect("Stop that session and restart here?")
    second.send(b"y\n")
    first.wait()
    second.expect("Preview updated")
    second.send(b"\n")
    second.wait()
    print("PASS verified replacement across websites sharing a port", flush=True)

    with socket.socket() as unrelated:
        unrelated.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        unrelated.bind(("127.0.0.1", port))
        unrelated.listen()
        conflict = Session(site, port, environment)
        conflict.expect("instead? [y/N]")
        conflict.send(b"y\n")
        conflict.expect("Preview updated")
        assert f"Preview: http://localhost:{port}\r" not in conflict.output
        conflict.send(b"\n")
        conflict.wait()
        assert unrelated.getsockname()[1] == port
        plain = subprocess.run([BINARY, "--site", str(site), "--port", str(port)],
                               env=environment, stdin=subprocess.DEVNULL,
                               capture_output=True, text=True, timeout=10)
        assert plain.returncode == 1 and "already in use" in plain.stderr, plain
    print("PASS unrelated port owner preserved and noninteractive conflict fails promptly", flush=True)

    first = ready(site, port, environment)
    plain = subprocess.run([BINARY, "--site", str(site), "--port", str(port)],
                           env=environment, stdin=subprocess.DEVNULL,
                           capture_output=True, text=True, timeout=10)
    assert plain.returncode == 1 and "interactive terminal" in plain.stderr, plain
    assert not first.exited()
    first.send(b"\n")
    first.wait()
    print("PASS noninteractive duplicate leaves the original running", flush=True)

    first = ready(site, port, environment)
    lock = session_lock(first)
    original = lock.read_bytes()
    lock.write_bytes(b'{"unverified": true}')
    unknown = Session(site, port, environment)
    unknown.expect("owner could not be verified")
    unknown.wait(expected=1)
    assert not first.exited()
    lock.write_bytes(original)
    first.send(b"\n")
    first.wait()
    print("PASS unverified session is never terminated", flush=True)

    (inputs / "slow").touch()
    child_file = site / "child.pid"
    first = Session(site, port, environment)
    eventually(child_file.exists, "slow build did not start")
    child = int(child_file.read_text())
    (inputs / "slow").unlink()
    second = Session(site, port, environment)
    second.expect("Stop that session and restart here?")
    second.send(b"y\n")
    second.expect("Preview updated")
    first.wait()
    assert not process_exists(child), "replacement overlapped with the previous build"
    second.send(b"\n")
    second.wait()
    print("PASS replacement waits for active build cleanup", flush=True)

    (inputs / "slow").touch()
    for stop in (b"\n", "close"):
        child_file = site / "child.pid"
        child_file.unlink(missing_ok=True)
        session = Session(site, port, environment)
        eventually(child_file.exists, "slow build did not start")
        child = int(child_file.read_text())
        if stop == "close":
            session.close_terminal()
        else:
            session.send(stop)
        session.wait()
        eventually(lambda: not process_exists(child), "build descendant survived shutdown")
        eventually(lambda: port_is_free(port), "server survived build cancellation")
    print("PASS Return and terminal closure during active build clean up descendants", flush=True)

    # Lock files intentionally persist during normal use. Remove only this test's private ones,
    # once every session has stopped, to avoid leaving fixtures in the user's temporary directory.
    for session in SESSIONS:
        if "Website: " in session.output:
            session_lock(session).unlink(missing_ok=True)



with tempfile.TemporaryDirectory(prefix="PublishDev-session-test-") as temporary:
    try:
        run(pathlib.Path(temporary))
    finally:
        for session in reversed(SESSIONS):
            session.cleanup()
print("All terminal session checks passed.")

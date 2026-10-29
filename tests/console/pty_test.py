"""The live console in a real pseudo-terminal: keys reach the TUI and every
way out restores the terminal (cooked mode, echo, main screen).

  (a) attach: `anole console <pid>` against examples/rest running in the
      background; /help is drawn, arrows work, Ctrl-C leaves and the app
      keeps running; again with stdio redirected (only /dev/tty is the
      terminal), and with SIGTERM instead of Ctrl-C.
  (b) in-process: examples/rest in the terminal; `c` + Enter opens the
      console, /help is drawn, arrows and Esc work (back to the logs),
      `c` + Enter again and Ctrl-C stops the server.

  python3 -I tests/console/pty_test.py <anole> <rest>

Std-only Python, Linux and macOS. Every process it starts is killed on exit.
"""
import os
import select
import signal
import struct
import subprocess
import sys
import termios
import time
import fcntl

ANOLE, REST = sys.argv[1], sys.argv[2]
ALT_ON, ALT_OFF = b"\x1b[?1049h", b"\x1b[?1049l"
procs = []


def factor():
    """ANOLE_TEST_TIMEOUT_FACTOR (a whole number, default 1): every wait here
    is a hang guard scaled by it, as src/testing/wait.zig's are."""
    try:
        return max(int(os.environ.get("ANOLE_TEST_TIMEOUT_FACTOR", "1")), 1)
    except ValueError:
        return 1


def env():
    e = dict(os.environ)
    # The development hotkey stays off under CI, systemd and journald.
    for k in ("CI", "INVOCATION_ID", "JOURNAL_STREAM", "NO_COLOR"):
        e.pop(k, None)
    e["TERM"] = "xterm-256color"
    e.setdefault("API_KEY", "console-pty-test-key-0123456789abcdef")
    return e


class Pty:
    """A child on a new pseudo-terminal that is its controlling terminal.
    A shell stays in front as the session leader (as in real use), so the
    terminal outlives the child and its modes can be read after it exits;
    the child's pid comes first as "PID:<n>" and its exit status last as
    "EXIT:<n>"."""

    def __init__(self, argv, redirect=False):
        # The inner shell prints its pid and becomes the child (exec).
        io = " </dev/null >/dev/null 2>&1" if redirect else ""
        inner = 'echo "PID:$$"; exec "$@"' + io
        argv = ["/bin/sh", "-c", 'sh -c \'' + inner + '\' sh "$@"; echo "EXIT:$?"; exec sleep 60', "sh"] + argv
        self.master, self.slave = os.openpty()
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
        self.cooked = termios.tcgetattr(self.slave)
        self.proc = subprocess.Popen(
            argv, stdin=self.slave, stdout=self.slave, stderr=self.slave, env=env(),
            start_new_session=True, preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0))
        procs.append(self.proc)
        self.out = b""

    def send(self, b):
        os.write(self.master, b)

    def expect(self, needle, timeout=10.0, since=0):
        timeout *= factor()
        end = time.time() + timeout
        while needle not in self.out[since:]:
            left = end - time.time()
            if left <= 0:
                fail(f"no {needle!r} within {timeout}s; last output: {self.out[-600:]!r}")
            r, _, _ = select.select([self.master], [], [], min(left, 0.1))
            if r:
                try:
                    d = os.read(self.master, 65536)
                except OSError:
                    d = b""
                if not d:
                    if needle not in self.out[since:]:
                        fail(f"terminal closed before {needle!r}; last output: {self.out[-600:]!r}")
                    break
                self.out += d
        return self.out.index(needle, since) + len(needle)

    def drain(self, secs):
        end = time.time() + secs
        while time.time() < end:
            r, _, _ = select.select([self.master], [], [], 0.05)
            if r:
                try:
                    d = os.read(self.master, 65536)
                except OSError:
                    return
                if not d:
                    return
                self.out += d

    def child_pid(self):
        i = self.expect(b"PID:")
        j = self.expect(b"\r\n", since=i)
        return int(self.out[i:j - 2])

    def mark(self):
        return len(self.out)

    def raw(self):
        """True when the terminal is in the console's raw mode."""
        lflag = termios.tcgetattr(self.slave)[3]
        return lflag & (termios.ICANON | termios.ECHO) == 0

    def restored(self):
        # PENDIN is the kernel's own (macOS sets it on going back to
        # canonical mode); everything else must be as it was.
        pendin = getattr(termios, "PENDIN", 0)
        a = termios.tcgetattr(self.slave)
        return a[:3] == self.cooked[:3] and a[3] & ~pendin == self.cooked[3] & ~pendin


def fail(msg):
    print("FAIL", msg)
    sys.exit(1)


def wait_exit(t, timeout):
    """The child's exit status, or None if it is still running."""
    end = time.time() + timeout * factor()
    while time.time() < end:
        t.drain(0.1)
        i = t.out.rfind(b"EXIT:")
        if i >= 0:
            j = i + 5
            while j < len(t.out) and t.out[j:j + 1].isdigit():
                j += 1
            if j > i + 5:
                return int(t.out[i + 5:j])
    return None


def running(t):
    return b"EXIT:" not in t.out


def check_console(t, start, label):
    """The console is up (alternate screen, raw mode) and answers keys."""
    at = t.expect(ALT_ON, since=start)
    t.expect(b"live", since=at)
    if not t.raw():
        fail(f"{label}: the terminal is not in raw mode")
    m = t.mark()
    t.send(b"/he")
    t.drain(0.3)
    t.send(b"lp\r")
    # /help lists the views; /runtime is one of them.
    t.expect(b"/runtime", since=m)
    # Arrows and paging are keys too; the console must stay up.
    t.send(b"\x1b[A\x1b[B\x1b[5~\x1b[6~")
    t.drain(0.3)
    if ALT_OFF in t.out[at:]:
        fail(f"{label}: the console left on an arrow key")


def start_app():
    srv = subprocess.Popen([REST, "127.0.0.1:0"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, env=env(), start_new_session=True)
    procs.append(srv)
    # Wait for the control socket line.
    end = time.time() + 20
    seen = b""
    while b"anole console" not in seen:
        if time.time() > end or srv.poll() is not None:
            fail(f"attach: the app did not start: {seen[-600:]!r}")
        r, _, _ = select.select([srv.stdout], [], [], 0.2)
        if r:
            seen += os.read(srv.stdout.fileno(), 65536)
    return srv


def attach(srv, how):
    """how: "ctrl-c"; "redirected" (stdio not the terminal, only /dev/tty
    is: on macOS poll cannot wait on it, so the console waits with select);
    "sigterm" (the terminal is restored on the way out, exit 130)."""
    label = f"attach ({how})"
    t = Pty([ANOLE, "console", str(srv.pid)], redirect=how == "redirected")
    check_console(t, 0, label)
    m = t.mark()
    if how == "sigterm":
        os.kill(t.child_pid(), signal.SIGTERM)
    else:
        t.send(b"\x03")  # Ctrl-C leaves the console
    t.expect(ALT_OFF, since=m)
    code = wait_exit(t, 10)
    if code is None:
        fail(f"{label}: `anole console` did not exit")
    if code != (130 if how == "sigterm" else 0):
        fail(f"{label}: `anole console` exited {code}")
    if not t.restored():
        fail(f"{label}: the terminal was not restored: {termios.tcgetattr(t.slave)[:4]} vs {t.cooked[:4]}")
    if srv.poll() is not None:
        fail(f"{label}: leaving the console stopped the app")
    print(f"ok {label}: keys reach the console, it leaves, terminal restored, app still running")


def in_process():
    t = Pty([REST, "127.0.0.1:0"])
    t.expect(b"press c + Enter", timeout=20)
    t.drain(0.3)
    # Open, keys, Esc back to the logs.
    m = t.mark()
    t.send(b"c\n")
    check_console(t, m, "in-process")
    m = t.mark()
    t.send(b"\x1b")  # Esc with nothing typed: back to the logs
    t.expect(ALT_OFF, since=m)
    t.drain(0.5)
    if not t.restored():
        fail("in-process: Esc did not restore the terminal")
    if not running(t):
        fail("in-process: Esc stopped the server")
    # Again, then /quit.
    m = t.mark()
    t.send(b"c\n")
    t.expect(ALT_ON, since=m)
    t.drain(0.3)
    m = t.mark()
    t.send(b"/quit\r")
    t.expect(ALT_OFF, since=m)
    t.drain(0.5)
    if not t.restored() or not running(t):
        fail("in-process: /quit did not return to the logs")
    # Again, then Ctrl-C stops the server.
    m = t.mark()
    t.send(b"c\n")
    t.expect(ALT_ON, since=m)
    t.drain(0.3)
    m = t.mark()
    t.send(b"\x03")
    t.expect(ALT_OFF, since=m)
    code = wait_exit(t, 20)
    if code is None:
        fail(f"in-process: Ctrl-C did not stop the server; last output: {t.out[-600:]!r}")
    if not t.restored():
        fail("in-process: the terminal was not restored after Ctrl-C")
    print("ok in-process: c + Enter opens, keys work, Esc and /quit return to the logs, Ctrl-C stops the server")


try:
    app = start_app()
    for how in ("ctrl-c", "redirected", "sigterm"):
        attach(app, how)
    if os.path.exists("/.dockerenv") or os.path.exists("/run/.containerenv"):
        # The development hotkey is off in containers by design.
        print("skip in-process: in a container, where `c` + Enter is off")
    else:
        in_process()
finally:
    for p in procs:
        if p.poll() is None:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except OSError:
                p.kill()
            p.wait()

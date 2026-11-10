"""PocketIDE runs Google's gcloud unchanged, except for one thing, made here: where the tunnel of
`gcloud cloud-shell ssh` listens on the phone.

gcloud opens a tunnel to Cloud Shell and has its ssh connect to it through a TCP port on the
computer's own address (localhost). On a computer that port is the owner's; on a phone every app
shares that address, so any app could reach Cloud Shell through it while it is open. Here the
tunnel listens on a Unix socket file in PocketIDE's private storage instead ($POCKETIDE_TUNNEL),
which only this app can open, and ssh reaches it with `nc -U` (its ProxyCommand). gcloud's
sign-in, its requests to Google and its ssh stay its own.

gcloud's CLOUDSDK_PYTHON is /opt/pocketide/bin/gcloud-python, which runs
    python3 [flags] private_tunnel.py <gcloud.py> <arguments>
and `private_tunnel.py --check <gcloud.py>` says whether the gcloud in place still opens its
tunnel the way this file expects: after gcloud updates itself, PocketIDE keeps the update only
when it does. When the tunnel cannot be made private, gcloud stops instead of opening a port.
"""

import importlib.abc
import importlib.machinery
import os
import runpy
import socket
import stat
import sys
import types

TUNNEL_MODULE = "googlecloudsdk.command_lib.cloud_shell.tunnel"
UNSUPPORTED = "PocketIDE: this gcloud opens its Cloud Shell tunnel in a new way; update PocketIDE."


class PhoneProblem(OSError):
    """The phone, not gcloud, stopped the tunnel (its folder, its socket file): said as it is."""


def _remove(path):
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass


class PrivateListener:
    """What the tunnel gets when it asks for a listening socket: a Unix socket at the private path."""

    def __init__(self, path):
        self._path = path
        self._socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)

    def setsockopt(self, *_args):
        pass

    def bind(self, _address):
        try:
            os.makedirs(os.path.dirname(self._path), mode=0o700, exist_ok=True)
            _remove(self._path)
            old = os.umask(0o077)
            try:
                self._socket.bind(self._path)
            finally:
                os.umask(old)
        except OSError as error:
            raise PhoneProblem(f"{self._path}: {error.strerror or error}") from error

    def listen(self, backlog):
        self._socket.listen(backlog)

    def getsockname(self):
        # gcloud passes this port to ssh, which reaches the socket through its ProxyCommand instead.
        return ("localhost", 22)

    def accept(self):
        return self._socket.accept()

    def close(self):
        self._socket.close()
        _remove(self._path)

    def __getattr__(self, name):
        return getattr(self._socket, name)


class SocketModule(types.ModuleType):
    """The tunnel module's `socket`: the real module, except that a new socket is a private listener."""

    def __init__(self, path):
        super().__init__("socket")
        self._path = path
        self.made = 0

    def socket(self, *_args, **_kwargs):
        self.made += 1
        return PrivateListener(self._path)

    def __getattr__(self, name):
        return getattr(socket, name)


def _make_private(module, path):
    if not isinstance(getattr(module, "socket", None), types.ModuleType) or not hasattr(module, "CloudShellTunnel"):
        raise ImportError(UNSUPPORTED)
    module.socket = SocketModule(path)


class _Loader(importlib.abc.Loader):
    def __init__(self, loader, path):
        self._loader = loader
        self._path = path

    def create_module(self, spec):
        return self._loader.create_module(spec)

    def exec_module(self, module):
        self._loader.exec_module(module)
        _make_private(module, self._path)

    def __getattr__(self, name):
        return getattr(self._loader, name)


class _Finder(importlib.abc.MetaPathFinder):
    """Finds the tunnel module where Python would, and makes it private as it loads."""

    def __init__(self, path):
        self._path = path

    def find_spec(self, fullname, path, target=None):
        if fullname != TUNNEL_MODULE:
            return None
        spec = importlib.machinery.PathFinder.find_spec(fullname, path, target)
        if spec is None or spec.loader is None:
            return None
        spec.loader = _Loader(spec.loader, self._path)
        return spec


def _gcloud_path(gcloud_py):
    """The folders gcloud.py puts first on the path, in its order."""
    lib = os.path.dirname(os.path.abspath(gcloud_py))
    third_party = os.path.join(lib, "third_party")
    return [third_party, lib] if os.path.isdir(third_party) else [lib]


def check(gcloud_py, path):
    """None when this gcloud's tunnel listens on the private socket and nowhere else; else why not.

    Whatever goes wrong inside gcloud's own code (its tunnel moved, renamed, opened another way, or
    gcloud is damaged) is reported as UNSUPPORTED, so PocketIDE puts back a gcloud it knows; only
    a problem on the phone itself (PhoneProblem) is reported as it is.
    """
    sys.path[0:0] = _gcloud_path(gcloud_py)
    sys.meta_path.insert(0, _Finder(path))
    try:
        tunnel = importlib.import_module(TUNNEL_MODULE)
        made = tunnel.socket
        connection = tunnel.CloudShellTunnel(host="localhost", jwt="check")
        connection.Start()
        try:
            listening = os.path.exists(path) and stat.S_ISSOCK(os.stat(path).st_mode) and made.made == 1
        finally:
            connection.Stop()
    except PhoneProblem:
        raise
    except Exception as error:  # any failure inside gcloud's own code: not the gcloud this file knows
        said = str(error)
        return said if UNSUPPORTED in said else f"{UNSUPPORTED} ({type(error).__name__}: {said})"
    if not listening or os.path.exists(path):
        # The tunnel did not take its listener from PocketIDE: gcloud opens it another way now.
        return UNSUPPORTED
    return None


def main(argv):
    path = os.environ.get("POCKETIDE_TUNNEL", "")
    if len(argv) >= 2 and argv[0] == "--check":
        if not path:
            print("private tunnel: POCKETIDE_TUNNEL is not set")
            return 1
        try:
            why = check(argv[1], path)
        except Exception as error:  # the check itself is the answer: anything unexpected is "no", with its reason
            why = f"{type(error).__name__}: {error}"
        print("private tunnel: " + (why or "ok"))
        return 0 if why is None else 1
    if not argv:
        print("usage: private_tunnel.py <gcloud.py> <arguments>", file=sys.stderr)
        return 2
    gcloud_py, rest = argv[0], argv[1:]
    if path:
        sys.meta_path.insert(0, _Finder(path))
    sys.argv = [gcloud_py] + rest
    sys.path[0] = os.path.dirname(os.path.abspath(gcloud_py))
    runpy.run_path(gcloud_py, run_name="__main__")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

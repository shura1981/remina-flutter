"""Disposable loopback-only SSH echo fixture; requires Paramiko in a separate venv.

No OS accounts, login shell, external hosts or existing SSH configuration are used.
The test password is public and is deliberately valid only for this fixture.
"""

import json
import socket
import threading

import paramiko


class EchoServer(paramiko.ServerInterface):
    def __init__(self):
        self.shell = threading.Event()
        self.channel = None
        self.size = (80, 24)

    def get_allowed_auths(self, username):
        if username == "interactive":
            return "keyboard-interactive"
        return "password"

    def check_auth_interactive(self, username, submethods):
        if username == "interactive":
            return paramiko.InteractiveQuery(
                "Fixture authentication", "Disposable local test", ("Password:", False)
            )
        return paramiko.AUTH_FAILED

    def check_auth_interactive_response(self, responses):
        if responses == ["fixture-password"]:
            return paramiko.AUTH_SUCCESSFUL
        return paramiko.AUTH_FAILED

    def check_auth_password(self, username, password):
        if username == "fixture" and password == "fixture-password":
            return paramiko.AUTH_SUCCESSFUL
        return paramiko.AUTH_FAILED

    def check_channel_request(self, kind, channel_id):
        if kind == "session":
            return paramiko.OPEN_SUCCEEDED
        return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_pty_request(self, channel, term, width, height, *args):
        self.channel = channel
        self.size = (width, height)
        return term == b"xterm-256color"

    def check_channel_window_change_request(self, channel, width, height, *args):
        self.size = (width, height)
        if self.shell.is_set():
            channel.sendall(f"fixture-size={width}x{height}\r\n".encode())
        return True

    def check_channel_shell_request(self, channel):
        self.shell.set()
        return True


listener = socket.socket()
listener.bind(("127.0.0.1", 0))
listener.listen(4)
host_key = paramiko.RSAKey.generate(2048)
print(json.dumps({"port": listener.getsockname()[1]}), flush=True)

while True:
    peer, _ = listener.accept()
    transport = paramiko.Transport(peer)
    transport.add_server_key(host_key)
    server = EchoServer()
    try:
        transport.start_server(server=server)
        channel = transport.accept(10)
        if channel is None or not server.shell.wait(10):
            continue
        channel.sendall(b"fixture-ready\r\n")
        pending = b""
        while transport.is_active():
            data = channel.recv(4096)
            if not data:
                break
            pending += data
            while b"\r" in pending:
                command, pending = pending.split(b"\r", 1)
                if command == b"exit":
                    channel.send_exit_status(0)
                    channel.close()
                    break
                channel.sendall(b"fixture-echo:" + command + b"\r\n")
    except (EOFError, OSError, paramiko.SSHException):
        pass
    finally:
        transport.close()
        print(json.dumps({"disconnected": True}), flush=True)

#!/usr/bin/env python3
"""Exercise the same macOS profile shape used by the bundled Monero child."""
import errno
import socket
import subprocess
import sys

with socket.socket() as permitted, socket.socket() as forbidden:
    permitted.bind(("127.0.0.1", 0)); permitted.listen()
    forbidden.bind(("127.0.0.1", 0)); forbidden.listen()
    permitted_port = permitted.getsockname()[1]
    forbidden_port = forbidden.getsockname()[1]
    profile = f'(version 1)(allow default)(deny network*)(deny mach-lookup)(allow network-outbound (remote ip "localhost:{permitted_port}"))'
    program = '''import errno, socket, sys
for host, port, allowed in [("127.0.0.1", int(sys.argv[1]), True), ("127.0.0.1", int(sys.argv[2]), False), ("1.1.1.1", 443, False)]:
    with socket.socket() as connection:
        connection.settimeout(2)
        outcome = connection.connect_ex((host, port))
        assert (outcome == 0) if allowed else (outcome in (errno.EPERM, errno.EACCES))
print("Monero sandbox: allowed proxy loopback reachable; other local and external connections denied")
'''
    subprocess.run(["/usr/bin/sandbox-exec", "-p", profile, sys.executable, "-c", program, str(permitted_port), str(forbidden_port)], check=True)

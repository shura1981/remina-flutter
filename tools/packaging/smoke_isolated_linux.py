#!/usr/bin/env python3
"""Launch the bundled app + RDP engine without host libraries or installations.
Requires Docker, Xvfb, xwininfo and optionally ImageMagick on the TEST machine only.
No network and no user profiles/credentials are used.
"""
import argparse
import os
from pathlib import Path
import select
import re
import time
import subprocess
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('bundle', type=Path)
parser.add_argument('--image', default='ubuntu:24.04')
parser.add_argument('--screenshot', type=Path)
args = parser.parse_args()
xserver = subprocess.Popen(['Xvfb', '-displayfd', '1', '-screen', '0', '1280x800x24', '-ac', '-nolisten', 'tcp'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
container_name = 'remina-portability-' + uuid.uuid4().hex[:12]
try:
    if not select.select([xserver.stdout], [], [], 8)[0]:
        raise RuntimeError('Xvfb did not start')
    display = ':' + xserver.stdout.readline().strip()
    common = ['docker', 'run', '--rm', '--init', '--network', 'none',
        '-v', f'{args.bundle.resolve()}:/relocated Remina:ro',
        '-v', '/tmp/.X11-unix:/tmp/.X11-unix:ro',
        '-e', f'DISPLAY={display}', '-e', 'NO_AT_BRIDGE=1', '-e', 'LIBGL_ALWAYS_SOFTWARE=1']
    engine = subprocess.run([*common, '-i', args.image, '/relocated Remina/rdp/bin/remina-rdp',
        '/v:127.0.0.1:1', '/u:fixture', '/from-stdin:force', '/cert:deny',
        '-auto-reconnect', '/log-level:WARN'], input='fixture-only-password\n',
        capture_output=True, text=True, timeout=20)
    if 'ERRCONNECT_CONNECT_FAILED' not in engine.stderr and 'failed to connect' not in engine.stderr:
        raise RuntimeError('Engine did not reach the expected loopback connection failure:\n' + engine.stdout + engine.stderr)
    print('PASS: bundled RDP engine accepted credentials via stdin and attempted only the closed loopback port.')
    process = subprocess.Popen([*common, '--name', container_name, args.image,
        'timeout', '-k', '2s', '10s', '/relocated Remina/remina'], stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True)
    # The runner maps the GTK window only after Flutter's first frame. Do not
    # count an idle process or an unmapped black window as a working GUI.
    visible = False
    for _ in range(32):
        time.sleep(0.2)
        tree = subprocess.run(['xwininfo', '-display', display, '-root', '-tree'], capture_output=True, text=True).stdout
        match = re.search(r'(0x[0-9a-f]+) "Remina(?: Desktop)?"', tree)
        if match:
            window = subprocess.run(['xwininfo', '-display', display, '-id', match[1]], capture_output=True, text=True).stdout
            if 'Map State: IsViewable' in window:
                visible = True
                break
    if not visible:
        raise RuntimeError('No mapped Flutter window appeared in the isolated container')
    if args.screenshot:
        args.screenshot.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['import', '-display', display, '-window', 'root', str(args.screenshot)], check=True)
    stdout, stderr = process.communicate(timeout=25)
    bad = ['Failed to start Flutter engine', 'Failed to create OpenGL', 'cannot open shared object', 'Couldn\'t open', 'Unhandled exception']
    if process.returncode not in (124, 137, 143) or any(message in stderr + stdout for message in bad):
        raise RuntimeError(f'Isolated GUI failed (exit {process.returncode}):\n{stdout}\n{stderr}')
    print(f'PASS: graphical Flutter app ran from a different path in {args.image} without installing packages.\n{stderr.strip()}')
finally:
    subprocess.run(['docker', 'rm', '-f', container_name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
    xserver.terminate()
    xserver.wait(timeout=5)

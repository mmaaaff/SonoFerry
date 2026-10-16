#!/usr/bin/env python3
"""Offline cancellation checks: neither helper may touch Bluetooth before ACL."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
helpers = root / 'dist/SonoFerry.app/Contents/Helpers/SonoFerry Engine.app/Contents/Helpers'
for command, expected in [(b'close\n', 0), (b'wrong\n', 4), (b'', 4)]:
    read_fd, write_fd = os.pipe()
    try:
        result = subprocess.run([
            helpers / 'MediaTransport', '--media', '--await-prepare', '--pcm-fd', str(read_fd),
            '--address', '00-00-00-00-00-00', '--codec', 'lhdcV5', '--sample-rate', '44100'
        ], input=command, capture_output=True, pass_fds=(read_fd,), timeout=5)
        assert result.returncode == expected, result.stdout.decode()
        assert b'MEDIA_WAITING_FOR_ACL' in result.stdout
        assert b'BEFORE ' not in result.stdout and b'OPEN_BEGIN' not in result.stdout
    finally:
        os.close(read_fd); os.close(write_fd)

with tempfile.TemporaryDirectory(prefix='sonoferry-deferred-signaling-') as directory:
    for command, expected in [(b'stop\n', 0), (b'wrong\n', 5), (b'', 5)]:
        result = subprocess.run([
            helpers / 'AVDTPSignaling', '--capabilities-disconnected', str(Path(directory) / 'raw.bin'),
            '--address', '00-00-00-00-00-00', '--await-acl'
        ], input=command, capture_output=True, timeout=5)
        assert result.returncode == expected, result.stdout.decode()
        assert b'SIGNAL_PREPARED' in result.stdout
        assert b'BEFORE ' not in result.stdout and b'OPEN_BEGIN' not in result.stdout
print('Deferred helper startup: cancellation, invalid command and EOF before ACL PASS (6 cases)')

# Accelerated restoration is an explicit, scoped combination. Invalid requests
# must be rejected before device lookup or any Bluetooth operation.
classic = helpers / 'ClassicConnection'
for args in [
    ['--reconfigure'],
    ['--reconfigure', '--restore'],
    ['--reconfigure', '--disconnect'],
    ['--reconfigure', '--restore', '--disconnect'],
    ['--reconfigure', '--restore', '--disconnect', '--expected-handle', 'FFFF'],
    ['--reconfigure', '--restore', '--disconnect', '--expected-handle', '0000', '--watch-parent']
]:
    result = subprocess.run([str(classic), '--address', '00-00-00-00-00-00', *args],
                            capture_output=True, text=True, timeout=5)
    assert result.returncode == 2 and 'BEFORE ' not in result.stdout, result
print('RECONFIGURE_ARGS PASS: 6 malformed/underspecified requests rejected before Bluetooth lookup')

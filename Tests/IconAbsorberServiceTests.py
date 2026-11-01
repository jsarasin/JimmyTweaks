"""Exercise the real service protocol without hiding any application."""
import json
import subprocess
import sys

agent = sys.argv[1]


def run(payload):
    process = subprocess.Popen([agent], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    output, errors = process.communicate(payload, timeout=8)
    messages = [json.loads(line) for line in output.splitlines()]
    assert messages and messages[0].get("available") is True, (messages, errors.decode(errors="replace"))
    return process.returncode, messages


code, messages = run(b'{"id":1,"hidden":[]}\n')
assert code == 0 and any(m.get("id") == 1 and m.get("ok") and m.get("held") is False for m in messages), (code, messages)
for payload in [b"not-json\n", b'{"id":2,"hidden":["com.apple.controlcenter"]}\n', b"x" * 65537]:
    code, _ = run(payload)
    assert code == 2, code
print("Icon Absorber service: clear/EOF, invalid JSON, Apple-control rejection, and input bounds passed. No application was hidden.")

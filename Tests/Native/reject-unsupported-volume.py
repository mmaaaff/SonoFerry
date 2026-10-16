"""Reject a legacy bound-volume request before any audio/Bluetooth side effects."""
import json, pathlib, subprocess, uuid
root = pathlib.Path(__file__).resolve().parents[2]
engine = root/'dist/SonoFerry.app/Contents/Helpers/SonoFerry Engine.app/Contents/MacOS/SonoFerryEngine'
session = str(uuid.uuid4())
request = dict(version=1, kind='start', sessionID=session,
               device=dict(address='00:11:22:33:44:55', name='Offline regression', connected=False, a2dpSink=True),
               gain=0.75, linkHardwareVolume=True)
commands = '\n'.join(json.dumps(c) for c in [request,dict(version=1,kind='quit')])+'\n'
result = subprocess.run([str(engine)],input=commands,text=True,capture_output=True,timeout=10,check=True)
events = [json.loads(line) for line in result.stdout.splitlines()]
assert len(events)==1, events
assert events[0]['kind']=='failed' and events[0]['sessionID'].upper()==session.upper(), events
assert events[0]['volumeLinkState']=='unavailable', events
assert '独立硬件音量' in events[0]['message'], events
print('VOLUME_GUARD PASS: explicit session-scoped rejection before preparation; immediate clean exit.')

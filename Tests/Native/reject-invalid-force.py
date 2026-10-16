"""Invalid overrides must fail before HAL ownership or Bluetooth activity."""
import json, pathlib, subprocess, uuid

root = pathlib.Path(__file__).resolve().parents[2]
engine = root/'dist/SonoFerry.app/Contents/Helpers/SonoFerry Engine.app/Contents/MacOS/SonoFerryEngine'
base = dict(codec='lhdcV5', sampleRate=48000, quality='low', bits=24,
            endpoint=3, minimumBitrate=64, maximumBitrate=1000, probeOnly=False)
cases = [dict(sampleRate=88200, forceSampleRate=True),
         dict(bits=32, forceSampleRate=True),
         dict(forceBitrate=True),
         dict(forceBitrate=True, fixedBitrateKbps=1100),
         dict(forceBitrate=True, fixedBitrateKbps=1000, quality='auto'),
         dict(forceSampleRate=True, endpoint=0)]
cases += [dict(buffering=dict(catchupLimitTenths=t, prefillMilliseconds=p))
          for t,p in [(0,250),(151,250),(50,9),(50,1001)]]
for override in cases:
    session = str(uuid.uuid4())
    request = dict(version=1, kind='start', sessionID=session, configuration=base | override,
                   device=dict(address='00:11:22:33:44:55', name='Offline regression', connected=False, a2dpSink=True), gain=0)
    commands = '\n'.join(json.dumps(c) for c in [request, dict(version=1,kind='quit')])+'\n'
    result = subprocess.run([str(engine)],input=commands,text=True,capture_output=True,timeout=10,check=True)
    events = [json.loads(line) for line in result.stdout.splitlines()]
    assert len(events)==1 and events[0]['kind']=='failed', events
    assert events[0]['sessionID'].upper()==session.upper(), events
print(f'CONFIGURATION_GUARD PASS: {len(cases)} invalid overrides/buffering settings rejected before audio/Bluetooth preparation.')

# The deliberately invalid descriptor stops valid configurations before any
# Bluetooth lookup. This verifies the actual native argument parser as well.
media = engine.parent.parent/'Helpers/MediaTransport'
base_args = [str(media), '--media', '--pcm-fd', '99999', '--address', '00:11:22:33:44:55']
for codec, rates in [('ldac', [44100,48000,88200,96000]), ('lhdcV5', [44100,48000,96000,192000])]:
    for rate in rates:
        for duration, prefill in [(100,10),(5000,250),(15000,1000)]:
            result = subprocess.run(base_args + ['--codec',codec,'--sample-rate',str(rate),'--catchup-limit-ms',str(duration),'--prefill-ms',str(prefill)], capture_output=True,text=True,timeout=5)
            assert result.returncode == 2 and 'reason=invalid-read-pipe' in result.stderr and not result.stdout, result
for args in [['--catchup-limit-ms',str(v)] for v in [0,99,101,15001]] + [['--prefill-ms',str(v)] for v in [9,1001]] + [['--prefill-ms','250','--prefill-ms','250']]:
    result = subprocess.run(base_args + args,capture_output=True,text=True,timeout=5)
    assert result.returncode == 2 and 'Usage:' in result.stderr and not result.stdout, result
print('NATIVE_BUFFER_ARGS PASS: 24 valid range/rate cases and 7 invalid values; no Bluetooth lookup.')

#!/usr/bin/env python3
"""Versioned engine client. Probe/play require the installed matching HAL driver."""
import argparse,json,pathlib,subprocess,sys,time,uuid,selectors,os,math,struct,tempfile,wave
from build_settings import PRODUCT_NAME, ENGINE_EXECUTABLE_PATH
ROOT=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser()
p.add_argument('command',choices=['devices','doctor','audio-state','probe','play'])
p.add_argument('--device',help='Exact paired address or exact display name')
p.add_argument('--codec',choices=['ldac','lhdcV5'],default='ldac')
p.add_argument('--capabilities',type=pathlib.Path,help='JSONL from a successful probe; required for playback')
p.add_argument('--rate',type=int)
p.add_argument('--quality',choices=['auto','low','mid','high'],default='auto')
p.add_argument('--bitrate',type=int,help='Exact fixed LHDC V5 bitrate in kbps; requires non-auto quality')
p.add_argument('--force-unreported',action='store_true',help='Attempt explicit rates/bitrates outside advertised capabilities; always starts muted')
p.add_argument('--gain',type=float,default=0)
p.add_argument('--catchup-seconds',type=float,default=5.0,help='Continuous catch-up limit, 0.1 to 15.0 seconds, step 0.1')
p.add_argument('--prefill-ms',type=int,default=250,help='Startup and post-skip buffer target, 10 to 1000 ms, step 1')
p.add_argument('--bind-volume',action='store_true',help='Unavailable in 0.1.2; reject before changing the audio route')
p.add_argument('--seconds',type=float,default=30)
p.add_argument('--test-tone',action='store_true',help='After active: low-level left 440 Hz, right 660 Hz, both, silence; repeats every 8 seconds')
p.add_argument('--output',type=pathlib.Path)
p.add_argument('--app',type=pathlib.Path,default=ROOT/'dist'/(PRODUCT_NAME+'.app'))
a=p.parse_args();engine=a.app/ENGINE_EXECUTABLE_PATH
if not math.isfinite(a.catchup_seconds) or not .1<=a.catchup_seconds<=15 or abs(a.catchup_seconds*10-round(a.catchup_seconds*10))>1e-8:p.error('--catchup-seconds must be 0.1...15.0 in steps of 0.1')
if not 10<=a.prefill_ms<=1000:p.error('--prefill-ms must be 10...1000')
if a.command in ['devices','doctor']: sys.exit(subprocess.call([str(engine),'--'+a.command]))
if not a.device:p.error('--device is required')
listing=json.loads(subprocess.check_output([str(engine),'--devices'],text=True))
found=[d for d in listing['devices'] if a.device in [d['address'],d['name']]]
if len(found)!=1:p.error('Device did not resolve uniquely; run devices first')
d=found[0]
if a.command=='audio-state':sys.exit(subprocess.call([str(engine),'--audio-state',d['address']]))
config={'codec':a.codec,'sampleRate':a.rate or 48000,'quality':a.quality,'bits':24,'endpoint':0,'minimumBitrate':64,'maximumBitrate':1000,'probeOnly':a.command=='probe'}
config['buffering']={'catchupLimitTenths':round(a.catchup_seconds*10),'prefillMilliseconds':a.prefill_ms}
if a.command=='play':
    if not a.capabilities:p.error('--capabilities is required; playback never assumes support')
    events=[json.loads(line) for line in a.capabilities.read_text().splitlines() if line.strip()]
    completed=[e for e in events if e.get('kind')=='stopped' and e.get('details',{}).get('probeComplete')=='true']
    if not completed:p.error('No successfully completed probe')
    caps=[c for c in completed[-1].get('capabilities',[]) if c.get('codec')==a.codec]
    if not caps:p.error('Codec was not advertised in this probe')
    cap=caps[0];rates=[v for v in cap['sampleRates'] if v in ([44100,48000,88200,96000] if a.codec=='ldac' else [44100,48000,96000,192000])]
    if not rates:p.error('No common sample rate')
    rate=a.rate or (48000 if 48000 in rates else 44100 if 44100 in rates else min(rates))
    if rate not in ([44100,48000,88200,96000] if a.codec=='ldac' else [44100,48000,96000,192000]):p.error('Rate not implemented by this codec')
    if rate not in rates:
        if not a.force_unreported:p.error('Requested rate was not advertised; use --force-unreported to attempt it')
        config['forceSampleRate']=True
    config.update(sampleRate=rate,endpoint=cap['endpoint'],minimumBitrate=cap.get('minimumBitrate') or 64,maximumBitrate=cap.get('maximumBitrate') or 1000)
    if a.codec=='lhdcV5':
        if not cap.get('frame5ms') or not (cap.get('version',0)&1):p.error('LHDC V5 5ms configuration unavailable')
        depths=cap.get('bitDepths',[]);config['bits']=24 if 24 in depths else 16 if 16 in depths else 0
        if not config['bits']:p.error('No implemented integer input format')
    if a.bitrate is not None:
        table=[64,160,192,240 if rate==44100 else 256,320,400,480 if rate==44100 else 500,900,1000]
        if a.codec!='lhdcV5' or a.quality=='auto' or a.bitrate not in table:
            p.error('Fixed bitrate must be implemented by LHDC and use non-auto quality')
        if not config['minimumBitrate']<=a.bitrate<=config['maximumBitrate']:
            if not a.force_unreported:p.error('Requested bitrate was not advertised; use --force-unreported to attempt it')
            config['forceBitrate']=True
            config['minimumBitrate']=min(config['minimumBitrate'],max(v for v in [64,160,256,400] if v<=a.bitrate))
            config['maximumBitrate']=max(config['maximumBitrate'],min(v for v in [400,500,900,1000] if v>=a.bitrate))
        config['fixedBitrateKbps']=a.bitrate
if config.get('forceSampleRate') or config.get('forceBitrate'):
    if a.gain!=0:p.error('Forced CLI sessions start muted; use the app to raise volume after negotiation')
if not 0<=a.gain<=1 or a.seconds<=0:p.error('Invalid gain/duration')
if a.test_tone and a.command!='play':p.error('--test-tone requires play')
tone_file=None;player=None
if a.test_tone:
    tone_file=tempfile.NamedTemporaryFile(prefix='sonoferry-tone-',suffix='.wav',delete=False)
    tone_file.close()
    with wave.open(tone_file.name,'wb') as w:
        w.setnchannels(2);w.setsampwidth(2);w.setframerate(48000)
        block=bytearray()
        for n in range(int((a.seconds+1)*48000)):
            phase=n//96000%4;position=n%96000
            ramp=min(1,position/960,(96000-position)/960)
            left=.1*ramp*math.sin(2*math.pi*440*n/48000) if phase in [0,2] else 0
            right=.1*ramp*math.sin(2*math.pi*660*n/48000) if phase in [1,2] else 0
            block+=struct.pack('<hh',round(left*32767),round(right*32767))
            if len(block)>=192000:w.writeframesraw(block);block.clear()
        if block:w.writeframesraw(block)
def stop_tone():
    global player
    if player and player.poll() is None:player.terminate();player.wait(timeout=3)
    player=None
child=subprocess.Popen([str(engine)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,bufsize=0)
session=str(uuid.uuid4());out=a.output.open('w') if a.output else None
selector=selectors.DefaultSelector();selector.register(child.stdout,selectors.EVENT_READ)
def send(kind,**kw):
    child.stdin.write((json.dumps(dict(version=1,kind=kind,sessionID=session,**kw))+'\n').encode());child.stdin.flush()
send('probe' if a.command=='probe' else 'start',device=d,configuration=config,gain=a.gain,linkHardwareVolume=a.bind_volume)
deadline=time.monotonic()+120;stopping=False;success=False;pending=b''
try:
    while child.poll() is None:
        if time.monotonic()>deadline:
            if stopping:raise TimeoutError('Engine did not finish cleanup; inspect local session logs')
            stop_tone()
            send('stop');stopping=True;deadline=time.monotonic()+90
        for key,_ in selector.select(.2):
            data=os.read(key.fileobj.fileno(),65536)
            if not data:continue
            pending+=data
            while b'\n' in pending:
                line,pending=pending.split(b'\n',1);line=line.decode()+'\n'
                event=json.loads(line);print(line,end='',flush=True)
                if out:out.write(line);out.flush()
                if event['kind']=='active':
                    deadline=time.monotonic()+a.seconds
                    if tone_file and player is None:player=subprocess.Popen(['/usr/bin/afplay',tone_file.name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                if event['kind'] in ['stopping','error','stopped','failed']:stop_tone()
                if event['kind'] in ['stopped','failed']:
                    success=event['kind']=='stopped';send('quit');child.stdin.close();child.wait(timeout=10);break
except KeyboardInterrupt:
    stop_tone()
    send('stop');send('quit');child.stdin.close();child.wait(timeout=90)
finally:
    stop_tone()
    if tone_file:os.unlink(tone_file.name)
    if child.poll() is None:
        try:send('quit');child.stdin.close();child.wait(timeout=90)
        except (BrokenPipeError,subprocess.TimeoutExpired):child.terminate()
    if out:out.close()
sys.exit(0 if success else 1)

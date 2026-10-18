# coding: utf-8
from pathlib import Path
import json,subprocess,tempfile,time,statistics,hashlib,sys,argparse
parser=argparse.ArgumentParser(description='Paired product callback diagnostics impact comparison; no global input')
parser.add_argument('--capture-only',action='store_true')
parser.add_argument('--executable',type=Path,required=True);parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args();root=Path(__file__).resolve().parents[3];out=args.output.resolve();out.mkdir(parents=True,exist_ok=False)
stage=Path(tempfile.mkdtemp(prefix='hanq-impact-final-',dir='/private/tmp'))
plans=[('paced8','paced',320,8000,6),('paced20','paced',128,20000,4),('paced40','paced',64,40000,4),('buffered','buffered',256,2000,6),('blocked','blocked',512,200,6),('storage','storage',1024,1000,4)]
if args.capture_only:plans=[('capture','capture',1024,1000,4)]
protocol=dict(executable_sha256=hashlib.sha256(args.executable.read_bytes()).hexdigest(),stage=str(stage),plans=plans,thresholds=dict(max_median_paired_added_p99_us=1000,callback_stall_us=50000,blocked_callback_return_us=10000),acceptance=['exact per-pair input outcomes including order, consumption, replay, retained events, AX/source read counts','median added p99 below 1ms; any >1ms pair retained and investigated if repeated','no diagnostic-induced >=50ms callback stall','callbacks return during independently held60ms diagnostic lock','actual independent disk rotation and same diagnostic writer overlap under storage profile'],source_sha256={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path('Sources/HanQ/InputDiagnostics.swift'),Path('Tests/Diagnostics/Impact/main.swift')]},compiler_flags='same app target arm64 macOS13 Swift default unoptimized plus test-only lock accessor',sampling_timer_enabled=True,scope='product callbacks and injected snapshots; no global keys, real AX, editor or system source changes')
(out/'protocol.json').write_text(json.dumps(protocol,indent=2)+'\n');(out/'stage.txt').write_text(str(stage)+'\n')
rows=[]
for label,profile,count,gap,repeats in plans:
 for round in range(repeats):
  pair={}
  for enabled in ([False,True] if round%2==0 else [True,False]):
   name=f'{label}-{round:02d}-'+('on' if enabled else 'off');trial=stage/name;trial.mkdir();result=trial/'result.json'
   cmd=[str(args.executable.resolve()),'--profile',profile,'--keys',str(count),'--gap-us',str(gap),'--result',str(result)]
   if enabled:cmd+=['--diagnose-input-incidents',str(trial/'incidents')]
   started=time.monotonic();r=subprocess.run(cmd,capture_output=True,text=True,timeout=20)
   (trial/'stdout.log').write_text(r.stdout);(trial/'stderr.log').write_text(r.stderr)
   if r.returncode:raise RuntimeError(f'{name} return={r.returncode}: {r.stderr}')
   value=json.loads(result.read_text());value['trial']=name;value['wall_seconds']=time.monotonic()-started
   pair[enabled]=value;rows.append(value)
   expected=2*count+(count//32*16+2 if profile=='buffered' else 0)
   assert value['outcome']['submitted']==expected and value['outcome']['failures']==0 and value['outcome']['down_passed']==value['outcome']['up_passed']==count
   if profile=='buffered':assert value['outcome']['retained']==2 and value['outcome']['replayed']==count//32*16 and value['outcome']['gate_replay_seen']==value['outcome']['replayed']
   if profile=='blocked':assert value['held_diagnostic_callback']['count']>0 and value['diagnostic_hold_us']>=50000
   if profile=='capture' and enabled:assert value['capture_pressure']['deferred_phases']>0 and value['capture_pressure']['requests']>=64
   if profile=='storage' and enabled:assert value['pressure_storage']['saved']==48 and value['pressure_storage']['evictedFiles']==42 and value['pressure_storage']['unavailable']==0
   print(name,'p99_us',value['callback']['p99_us'],'max_us',value['callback']['max_us'],flush=True)
  assert pair[False]['outcome']==pair[True]['outcome'],(label,round,pair[False]['outcome'],pair[True]['outcome'])
  delta=pair[True]['callback']['p99_us']-pair[False]['callback']['p99_us'];print('PAIR',label,round,'same outcome; added p99 us',delta,flush=True)
  (out/'results-progress.json').write_text(json.dumps(rows,indent=2)+'\n')
summary=[]
for label,profile,count,gap,repeats in plans:
 group=[v for v in rows if v['trial'].startswith(label+'-')];off=[v for v in group if not v['diagnostics']];on=[v for v in group if v['diagnostics']]
 deltas=[next(v for v in on if v['trial'].split('-')[1]==o['trial'].split('-')[1])['callback']['p99_us']-o['callback']['p99_us'] for o in off]
 entry=dict(profile=label,pairs=repeats,callbacks_per_mode=sum(v['outcome']['submitted'] for v in on),off_median_p99_us=statistics.median(v['callback']['p99_us'] for v in off),on_median_p99_us=statistics.median(v['callback']['p99_us'] for v in on),paired_added_p99_us=deltas,median_paired_added_p99_us=statistics.median(deltas),off_max_us=max(v['callback']['max_us'] for v in off),on_max_us=max(v['callback']['max_us'] for v in on),all_outcomes_identical=True)
 entry['pairs_above_1ms']=sum(d>=1000 for d in deltas)
 assert entry['median_paired_added_p99_us']<1000 and entry['pairs_above_1ms']<2
 assert not any(v['callback']['max_us']>=50000 for v in on)
 if profile=='blocked':assert max(v['held_diagnostic_callback']['max_us'] for v in on)<10000
 summary.append(entry)
(out/'results.json').write_text(json.dumps(rows,indent=2)+'\n');(out/'summary.json').write_text(json.dumps(dict(pass_all=True,profiles=summary),indent=2)+'\n')
print('PASS all paired input outcomes and predeclared callback latency criteria',flush=True)

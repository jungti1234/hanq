"""Compare passive diagnostic cost; no editor, global keys or AX queries."""
import argparse,json,pathlib,statistics,subprocess
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--baseline',type=pathlib.Path,required=True)
p.add_argument('--candidate',type=pathlib.Path,required=True)
p.add_argument('--output',type=pathlib.Path,required=True)
a=p.parse_args();a.output.mkdir(parents=True,exist_ok=False)
order=[(False,False),(True,False),(False,True),(True,True),(True,True),(False,True),(True,False),(False,False)]*2
(a.output/'protocol.json').write_text(json.dumps({'order':order,'callbacksPerTrial':16384,'maximumAddedP99Micros':1000,'candidateStallMicros':50000,'actualEditorTest':False},indent=2)+'\n')
rows=[]
for candidate,on in order:
 executable=a.candidate if candidate else a.baseline
 r=subprocess.run([str(executable.resolve())]+(['--on'] if on else []),capture_output=True,text=True,check=True)
 row=json.loads(r.stdout);row['candidate']=candidate
 assert row['callbacks']==16384
 if candidate:assert (row['cpu_frames']>0 and row['motion_frames']>0) if on else row['work_frames']==0
 rows.append(row);(a.output/'trials.json').write_text(json.dumps(rows,indent=2)+'\n')
 print('candidate' if candidate else 'baseline','ON' if on else 'OFF','p99_us',row['p99_us'],'cpu_us',row['cpu_us'],flush=True)
summary=[]
for on in [False,True]:
 groups=[[r for r in rows if r['candidate']==c and r['enabled']==on] for c in [False,True]]
 median=lambda group,k:statistics.median(r[k] for r in group)
 delta=median(groups[1],'p99_us')-median(groups[0],'p99_us')
 assert delta<1000 and max(r['max_us'] for r in groups[1])<50000
 summary.append(dict(enabled=on,trials_each=len(groups[0]),baseline_median_p99_us=median(groups[0],'p99_us'),candidate_median_p99_us=median(groups[1],'p99_us'),added_median_p99_us=delta,baseline_median_cpu_us=median(groups[0],'cpu_us'),candidate_median_cpu_us=median(groups[1],'cpu_us'),candidate_max_callback_us=max(r['max_us'] for r in groups[1])))
(a.output/'summary.json').write_text(json.dumps({'pass':True,'comparisons':summary,'scope':'scalar callbacks and injected snapshots; no editor/IME latency or causal attribution'},indent=2)+'\n')
print('PASS bounded passive diagnostic cost; see scope in summary.json')

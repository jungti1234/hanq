#!/usr/bin/env python3
"""Summarize local incident metadata. Never declares an unmatched event lost."""
import argparse
import collections
import json
import pathlib


def summarize(data):
    if data.get('schema') != 1 or not isinstance(data.get('frames'), list):
        raise ValueError('unsupported incident schema')
    lanes={1:'hid',2:'main',3:'onset',4:'mismatch',5:'annotated_boundary',6:'onset_ax',7:'mismatch_ax',8:'source_boundary'}
    triggers={1:'manual',2:'callback_delay',3:'ax_delay',4:'possible_length_shrink',5:'source_boundary_interrupted'}
    counts=collections.defaultdict(collections.Counter)
    active={}
    completed=[]
    unpaired_ends=0
    state_counts=collections.defaultdict(collections.Counter)
    pending_max=collections.defaultdict(int)
    ordinary=collections.defaultdict(dict)
    peak=0
    overlap_starts=0
    maxima=collections.defaultdict(int)
    boundary_stages=collections.Counter()
    wait_reasons={13:'snapshot',14:'text',15:'caret',16:'repair',17:'repair_receipt',18:'onset_receipt',19:'replay_receipt',20:'focus',21:'selection_commit',22:'source_commit'}
    boundary_waits=collections.Counter()
    editor_outcomes=collections.Counter()
    editor_stages={23:"input_resumed_without_switch",24:"insertion_style_matched",25:"terminal_lf_matched",26:"terminal_lf_and_style_matched",27:"delivered_prefix_pending",28:"initial_body_removal_matched"}
    maximum_boundary_queue=0
    maximum_unconfirmed_onsets=0
    for frame in data['frames']:
        lane=lanes.get(frame['lane'],'unknown')
        maxima[lane]=max(maxima[lane],frame['durationMicros'])
        if frame['kind']==1 and frame['edge']==1:
            kind={1:'ordinary_or_external',2:'repair',3:'state_only'}.get(frame['inputOrigin'],'unknown')
            counts[lane][kind+'_downs']+=1
            counts[lane]['consumed_downs' if frame['consumed'] else 'passed_downs']+=1
            if frame['inputOrigin']==1:ordinary[frame['event']].setdefault(lane,frame['milliseconds'])
        if frame['kind']==6:
            state_counts[lane][str(frame['category'])]+=1
            pending_max[lane]=max(pending_max[lane],frame.get('count',0))
        if frame['kind']==7:
            boundary_stages[str(frame['category'])]+=1
            if frame['category'] in wait_reasons:boundary_waits[wait_reasons[frame['category']]]+=1
            if frame['category'] in editor_stages:editor_outcomes[editor_stages[frame['category']]]+=1
            maximum_boundary_queue=max(maximum_boundary_queue,frame.get('count',0))
            maximum_unconfirmed_onsets=max(maximum_unconfirmed_onsets,frame['event'])
        if frame['kind']==2:
            if frame['category']==1:active[frame['event']]=(lane,frame['milliseconds'])
            else:
                start=active.pop(frame['event'],None)
                if start is None:unpaired_ends+=1
                else:completed.append((start[0],start[1],frame['milliseconds']))
    # Missing end records must not manufacture continuing overlap. Use only
    # complete spans; millisecond-rounded endpoints remain approximate.
    edges=[]
    for lane,start,end in completed:
        if end>start:edges.extend([(start,1,lane),(end,-1,lane)])
    live=collections.Counter()
    for _,delta,lane in sorted(edges):
        if delta>0:
            if any(value>0 and key!=lane for key,value in live.items()):overlap_starts+=1
            live[lane]+=1;peak=max(peak,sum(live.values()))
        else:live[lane]-=1
    transport_max=collections.defaultdict(int)
    for stages in ordinary.values():
        if 'hid' not in stages:continue
        for lane,milliseconds in stages.items():
            if lane!='hid' and milliseconds>=stages['hid']:
                transport_max[lane]=max(transport_max[lane],milliseconds-stages['hid'])
    return {'build':data.get('build'),'incident':data.get('incident'),'phase':data.get('phase'),
            'trigger':triggers.get(data['trigger'],'unknown'),'frames':len(data['frames']),
            'discarded_old_frames':data.get('discardedOldFrames'),'best_effort':True,
            'recipient_receipt_verified':False,'event_correlation_is_heuristic':True,
            'observed_keydown_counts':dict(counts),'maximum_correlated_hid_to_stage_ms':dict(transport_max),'maximum_observed_duration_us':dict(maxima),
            'peak_observed_ax_reads':peak,'cross_lane_ax_overlap_starts':overlap_starts,
            'open_or_unpaired_ax_reads':len(active)+unpaired_ends,'recovery_state_counts':dict(state_counts),'maximum_observed_owned_pending_events':dict(pending_max),
            'source_boundary_stage_counts':dict(boundary_stages),'maximum_source_boundary_queue':maximum_boundary_queue,'maximum_unconfirmed_onset_receipts':maximum_unconfirmed_onsets,
            'source_boundary_wait_reasons':dict(boundary_waits),'source_boundary_editor_outcomes':dict(editor_outcomes),
            'skipped_event_observations':{lanes.get(int(k),'unknown'):v for k,v in data.get('skippedEvents',{}).items()},
            'skipped_auxiliary_observations':{lanes.get(int(k),'unknown'):v for k,v in data.get('skippedAuxiliary',{}).items()},'loss_counters_may_lag':data.get('lossCountersMayLag',True),
            'interpretation':'Suspected timing/shape evidence only. Counts differ legitimately across consumers; missing records or delayed reads do not prove text loss.'}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('incident',type=pathlib.Path,nargs='+')
    args=parser.parse_args()
    for path in args.incident:
        with path.open() as stream:data=json.load(stream)
        print(json.dumps(summarize(data),ensure_ascii=False,indent=2))


if __name__=='__main__':main()

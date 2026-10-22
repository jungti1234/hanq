#!/usr/bin/env python3
"""Summarize local incident metadata. Never declares an unmatched event lost."""
import argparse
import collections
import json
import pathlib
import re


STORAGE_FIELDS=set(['maximumAutomaticFiles', 'maximumAutomaticBytes', 'automaticFiles', 'automaticBytes', 'attempts', 'saved', 'limited', 'retired', 'unavailable', 'encodingFailures', 'evictedGroups', 'evictedFiles', 'evictedBytes', 'lastIncident', 'lastPhase', 'lastAutomatic', 'lastResult', 'lastFailureStage', 'lastErrno', 'lastWriteMicros', 'maxWriteMicros', 'writeTimingClipped', 'statusWriteFailures'])

def storage_status(value):
    if not isinstance(value,dict) or set(value)!=STORAGE_FIELDS or type(value['lastAutomatic']) is not bool or any(type(n) is not int or n<0 for k,n in value.items() if k!='lastAutomatic'):
        raise ValueError('invalid storage status')
    v=value
    if v['maximumAutomaticFiles']<=0 or v['maximumAutomaticBytes']<=0 or v['automaticFiles']>v['maximumAutomaticFiles'] or v['automaticBytes']>v['maximumAutomaticBytes']:
        raise ValueError('invalid storage policy/usage')
    counts=[v[k] for k in ['saved','limited','retired','unavailable','encodingFailures']]
    if sum(counts)!=v['attempts'] or v['evictedGroups']>v['evictedFiles'] or v['lastPhase']>1 or v['lastResult']>5 or v['lastFailureStage']>6 or v['lastErrno']>2147483647 or v['lastWriteMicros']>v['maxWriteMicros'] or v['maxWriteMicros']>60000000 or v['writeTimingClipped']>v['attempts'] or v['statusWriteFailures']>v['attempts']:
        raise ValueError('inconsistent storage status')
    if v['attempts']==0:
        if any(v[k]!=0 for k in ['lastResult','lastIncident','lastFailureStage','lastErrno','automaticFiles','automaticBytes','evictedFiles','evictedBytes']):raise ValueError('invalid empty storage status')
    elif not (1<=v['lastResult']<=5 and v['lastIncident']>0 and counts[v['lastResult']-1]>0):raise ValueError('invalid storage result')
    if v['lastResult']==4:
        if not 1<=v['lastFailureStage']<=5:raise ValueError('missing storage failure stage')
    elif v['lastResult']==5:
        if v['lastFailureStage']!=6 or v['lastErrno']!=0:raise ValueError('invalid encoding failure')
    elif v['lastFailureStage']!=0 or v['lastErrno']!=0:raise ValueError('unexpected storage failure')
    results=['none','saved','limit','retired','unavailable','encoding_failed']
    stages=['none','arguments','directory','ownership','publication','pruning','encoding']
    return dict(v,last_result_name=results[v['lastResult']],last_failure_stage_name=stages[v['lastFailureStage']])

def summarize_storage_document(data):
    if not isinstance(data,dict) or set(data)!={'schema','build','status'} or type(data['schema']) is not int or data['schema']!=1 or not isinstance(data['build'],str) or not re.fullmatch(r'(?:[0-9]{1,9}|test)',data['build']):raise ValueError('invalid storage document')
    return dict(build=data['build'],storage_after_write=storage_status(data['status']))


def ax_evidence(value):
    limits={'valueClass':5,'placeholder':4,'label':4,'characterCount':3,'representation':2,'route':3,'owner':9_000_000_000_000_000,'window':9_000_000_000_000_000,'fieldRelation':2,'windowRelation':2,'identityEpoch':9_000_000_000_000_000}
    if not isinstance(value,dict) or set(value)!=set(limits) or any(type(value[k]) is not int or not 0<=value[k]<=v for k,v in limits.items()):raise ValueError('invalid AX evidence')
    if value['owner']==0 or value['identityEpoch']==0 or (value['window']==0 and value['windowRelation']!=0):raise ValueError('invalid AX identity evidence')
    return value


def describe_ax(value):
    ax_evidence(value)
    return dict(value_class=['unknown','empty','newline_only','whitespace_only','nonblank','scan_budget_exceeded'][value['valueClass']],
                placeholder=['unmeasured','unavailable','empty_attribute','different','trimmed_match_hint'][value['placeholder']],
                label=['unmeasured','unavailable','empty_attribute','different','trimmed_match_hint'][value['label']],
                character_count=['unmeasured','unavailable','agrees','disagrees'][value['characterCount']],
                representation=['unmeasured','agrees','differs'][value['representation']],
                route=['unknown','system','frontmost_application_fallback','changed_within_read'][value['route']],
                field_relation=['first_or_unknown','cf_equal','different'][value['fieldRelation']],
                window_relation=['unknown','cf_equal','different'][value['windowRelation']],
                document_truth='unverified_AX_provider_only')


def shape_evidence(value):
    flags={'comparisonKnown','contentChanged','selectionChanged','editingChanged','gap','editing'}
    numbers={'phase','firstMilliseconds','lastMilliseconds','observations','coalesced','baselineSequence'}
    if not isinstance(value,dict) or set(value)-{'ax','caretPrecedingClass'}!=flags|numbers:raise ValueError('invalid shape evidence fields')
    if 'caretPrecedingClass' in value and (type(value['caretPrecedingClass']) is not int or not 0<=value['caretPrecedingClass']<=5):raise ValueError('invalid caret class')
    if any(type(value[k]) is not bool for k in flags) or any(type(value[k]) is not int for k in numbers):raise ValueError('invalid shape evidence types')
    if value['phase'] not in [1,2,3] or not 0<=value['firstMilliseconds']<=value['lastMilliseconds']<=9_000_000_000_000_000 or not 0<=value['coalesced']<value['observations'] or value['baselineSequence']<=0:raise ValueError('invalid shape span')
    if (not value['comparisonKnown'] and (value['contentChanged'] or value['selectionChanged'])) or (value['gap'] and value['comparisonKnown']):raise ValueError('invalid shape comparison')
    if value['phase']==1 and (value['observations']!=1 or value['coalesced']!=0 or value['firstMilliseconds']!=value['lastMilliseconds']):raise ValueError('invalid shape baseline')
    if 'ax' in value:ax_evidence(value['ax'])
    return value


def shape_baselines(values):
    if not isinstance(values,list) or len(values)>8:raise ValueError('invalid shape baselines')
    def point(value):
        if not isinstance(value,dict) or set(value)!={'field','count','selected','evidence'} or type(value['field']) is not int or value['field']<=0 or type(value['count']) is not int or value['count']<0 or type(value['selected']) is not bool:raise ValueError('invalid shape point')
        shape_evidence(value['evidence'])
        return value
    seen=set()
    for value in values:
        if not isinstance(value,dict) or set(value)-{'previous'}!={'lane','active','current'} or type(value['lane']) is not int or value['lane'] not in range(1,9) or value['lane'] in seen or type(value['active']) is not bool:raise ValueError('invalid shape lane')
        seen.add(value['lane']);current=point(value['current'])
        if current['evidence']['phase']!=2:raise ValueError('invalid current shape phase')
        if 'previous' in value:
            previous=point(value['previous'])
            if previous['evidence']['phase']!=3 or previous['evidence']['lastMilliseconds']>current['evidence']['firstMilliseconds'] or previous['evidence']['baselineSequence']>=current['evidence']['baselineSequence']:raise ValueError('invalid previous shape span')
    return values


def source_evidence(value):
    required={'selected','confirmed','target','committed','deferred','candidatePreserved','historyPreserved','observedAtMilliseconds','ageClipped'}
    optional={'targetEventMilliseconds','confirmedAtMilliseconds','targetAtMilliseconds','confirmedAgeMicros','targetAgeMicros'}
    if not isinstance(value,dict) or set(value)-optional!=required:raise ValueError('invalid source evidence fields')
    if any(type(value[k]) is not int or not 0<=value[k]<=7 for k in ['selected','confirmed','target']):raise ValueError('invalid source kind')
    if any(type(value[k]) is not bool for k in ['committed','deferred','candidatePreserved','historyPreserved','ageClipped']):raise ValueError('invalid source evidence flags')
    for key in (optional | {'observedAtMilliseconds'}) & set(value):
        maximum=60_000_000 if key.endswith('Micros') else 9_000_000_000_000_000
        if type(value[key]) is not int or not 0<=value[key]<=maximum:raise ValueError('invalid source evidence time')
    for name in ['confirmed','target']:
        if (name+'AtMilliseconds' in value)!=(name+'AgeMicros' in value):raise ValueError('incomplete source evidence time')
    return value

CONTROL_ROUTES = dict(enumerate(['passed', 'tap_disabled', 'permission_denied', 'update_restricted', 'manual_marker', 'replay_marker', 'mirror_marker', 'mirror_inactive', 'recipient_moved_early', 'candidate_consumed', 'candidate_panel', 'barrier_queued', 'external_consumed', 'filter_consumed', 'recipient_moved_late', 'hid_tag_ignored', 'hid_consumed', 'hid_passed', 'onset_lock_timeout', 'onset_stopped', 'onset_stale', 'onset_deadline', 'onset_pointer', 'onset_shortcut', 'onset_first_release', 'onset_unclaimed', 'onset_buffer_limit', 'onset_buffered', 'onset_passed', 'recovery_redirect', 'secure_suppressed'],start=1))
CONTROL_ROLES={0:"health",1:"right_command",2:"right_option",3:"configured_korean",4:"configured_hanja"}
KEY_CLASSES={1:'space',2:'letter_position',3:'editing_or_navigation',4:'modifier',5:'pointer',6:'other'}
CARET_CLASSES={0:'unavailable_or_no_preceding_character',1:'ascii_letter',2:'hangul_syllable',3:'jamo',4:'whitespace',5:'other'}
HUD_STAGES={1:'requested',2:'ordered',3:'first_appkit_draw',4:'suppressed',5:'unavailable'}

def event_evidence(value):
    if not isinstance(value,dict) or set(value)!={'observedAtMicros','timestampMicros','keyClass'} or any(type(x) is not int for x in value.values()):raise ValueError('invalid event evidence fields')
    if value['keyClass'] not in KEY_CLASSES or any(not 0<=value[k]<=9_000_000_000_000_000 for k in ['observedAtMicros','timestampMicros']):raise ValueError('invalid event evidence values')
    return value

def switch_timelines(sources,controls,keys,hud,shapes):
    # Reporting only. No missing frame, selected source or draw call proves IME receipt.
    unique={}
    for row in keys:
        if row['kind']==1 and row['edge']==1 and row['inputOrigin']==1 and row['keyClass'] in [1,2,6]:
            if row['event'] not in unique or row['lane']=='hid':unique[row['event']]=row
    ordinary=sorted(unique.values(),key=lambda x:x['observedAtMicros'])
    result=[]
    requests=[r for r in sources if r['action']=='requested']
    for i,request in enumerate(requests):
        at=request['milliseconds']
        end=min(at+1000,requests[i+1]['milliseconds']) if i+1<len(requests) else at+1000
        presses=[c for c in controls if c['lane']=='main' and c['filterEdge']==1 and c['filterConsumed'] and abs(c['milliseconds']-at)<=10]
        def matches(c):
            return any(k['event']==c['event'] and k['timestampMicros']>0 and k['timestampMicros']//1000==request.get('targetEventMilliseconds') for k in keys)
        press=next((c for c in presses if matches(c)),None)
        boundary=next((k for k in keys if press and k['event']==press['event'] and k['lane']=='hid'),None)
        if boundary is None:boundary=next((k for k in keys if press and k['event']==press['event'] and k['kind']==11),None)
        t=boundary['observedAtMicros'] if boundary else at*1000
        before=[k for k in ordinary if t-1_000_000<=k['observedAtMicros']<t]
        after=[k for k in ordinary if t<=k['observedAtMicros']<end*1000]
        def key(row):
            if row is None:return None
            v=dict(row,observed_relative_to_switch_us=row['observedAtMicros']-t)
            v['os_relative_to_switch_us']=row['timestampMicros']-boundary['timestampMicros'] if boundary and row['timestampMicros']>0 and boundary['timestampMicros']>0 else None
            return v
        commit=next((s for s in sources if s['sequence']>request['sequence'] and s['action']=='committed' and s.get('targetEventMilliseconds')==request['targetEventMilliseconds'] and s['target']==request['target']),None) if 'targetEventMilliseconds' in request else None
        result.append(dict(request_sequence=request['sequence'],milliseconds=at,target=request['target'],control_event=press['event'] if press else None,
                           previous_key=key(before[-1] if before else None),following_keys=[key(k) for k in after[:3]],
                           selection_confirmed_after_ms=commit['milliseconds']-at if commit else None,
                           hud=[h for h in hud if at<=h['milliseconds']<end],
                           changed_shapes=[s for s in shapes if at<=s['milliseconds']<end and s.get('contentChanged') and not s['editing']],
                           interpretation='OS event order, source selection, AX provider observation and AppKit drawing are distinct; exact letters and editor/IME receipt are unverified'))
    return result
def control_evidence(value):
    ranges={'role': 4, 'eventType': 4, 'route': 31, 'runtime': 127, 'incomingFlags': 7, 'filterFlags': 7, 'filterBefore': 3, 'filterAfter': 3, 'filterEdge': 2, 'filterReason': 7, 'externalDevice': 6, 'externalHandling': 4, 'externalRole': 4, 'hidAcceptance': 10, 'querySite': 3, 'queryStatus': 5, 'currentClass': 4, 'targetClass': 4, 'availableCount': 4096, 'koreanCount': 4096, 'englishCount': 4096, 'queryMicros': 60000000}
    flags=['filterMeasured', 'filterAccepted', 'filterConsumed', 'queryClipped']
    if not isinstance(value,dict) or set(value)-{"priorQuery"}!=set(ranges)|set(flags):raise ValueError("invalid control fields")
    if any(type(value[k]) is not int or not 0<=value[k]<=v for k,v in ranges.items()) or any(type(value[k]) is not bool for k in flags):raise ValueError("invalid control values")
    if value["route"]==0 or value["koreanCount"]>value["availableCount"] or value["englishCount"]>value["availableCount"]:raise ValueError("invalid control ranges")
    if value["queryStatus"]==0 and any(value[k] for k in ["querySite","currentClass","targetClass","availableCount","koreanCount","englishCount","queryMicros","queryClipped"]):raise ValueError("unmeasured control query")
    if not value["filterMeasured"] and any(value[k] for k in ["filterBefore","filterAfter","filterEdge","filterFlags","filterReason","filterAccepted","filterConsumed"]):raise ValueError("unmeasured control filter")
    if 'priorQuery' in value:
        q=value['priorQuery'];ranges=dict(site=3,status=5,current=4,target=4,available=4096,korean=4096,english=4096,micros=60000000)
        if not isinstance(q,dict) or set(q)!=set(ranges)|{'clipped'} or any(type(q[k]) is not int or not 0<=q[k]<=v for k,v in ranges.items()) or type(q['clipped']) is not bool or q['site']==0 or q['status']==0 or q['korean']>q['available'] or q['english']>q['available'] or value['queryStatus']==0:raise ValueError('invalid prior control query')
    return value

def capture_preservation(value):
    keys={'deferred','requests','postCapacity','postOmittedFrames','closed','endedOnShutdown'}
    if not isinstance(value,dict) or set(value)-{'closedMilliseconds'}!=keys:raise ValueError('invalid capture preservation')
    if any(type(value[k]) is not bool for k in ['deferred','closed','endedOnShutdown']) or type(value['postCapacity']) is not int or not 1<=value['postCapacity']<=16384 or type(value['postOmittedFrames']) is not int or value['postOmittedFrames']<0:raise ValueError('invalid capture preservation bounds')
    closed=value.get('closedMilliseconds')
    if value['closed']!=(closed is not None) or (closed is not None and (type(closed) is not int or closed<0)) or value['endedOnShutdown'] and not value['closed']:raise ValueError('invalid capture closing state')
    requests=value['requests']
    if not isinstance(requests,list) or not 1<=len(requests)<=32:raise ValueError('invalid capture requests')
    for row in requests:
        if not isinstance(row,dict) or set(row)!={'trigger','milliseconds','afterSequence','lane','detail','event','inputOrigin'} or any(type(n) is not int for n in row.values()) or not 1<=row['trigger']<=6 or not 1<=row['lane']<=8 or not 0<=row['detail']<=31 or not 0<=row['inputOrigin']<=3 or min(row['milliseconds'],row['afterSequence'],row['event'])<0:raise ValueError('invalid capture request')
        if row['trigger']==6 and not (row['event']==0 and row['inputOrigin']==0 and ((row['lane']==4 and row['detail'] in [1,2,3,4,5,6,10]) or (row['lane']==3 and row['detail'] in [7,8,9]))):raise ValueError('invalid recovery detection')
    return value

def capture_backlog(value):
    groups=['requested','merged','deferred','requestOverflow','windowOverflow','postOverflow','discardedOnDisable']
    keys={'automaticCapacity','manualCapacity','requestCapacityPerTrigger','requestsPerWindow','pendingAutomatic','pendingManual','submittedWindows','completedWindows'}|set(groups)
    if not isinstance(value,dict) or set(value)!=keys:raise ValueError('invalid capture backlog')
    if any(type(value[k]) is not int or value[k]<0 for k in keys-set(groups)) or (value['automaticCapacity'],value['manualCapacity'],value['requestCapacityPerTrigger'],value['requestsPerWindow'])!=(16,4,16,32) or value['pendingAutomatic']>16 or value['pendingManual']>4 or value['completedWindows']>value['submittedWindows']:raise ValueError('invalid capture backlog bounds')
    for key in groups:
        d=value[key]
        if not isinstance(d,dict) or len(d)>6 or any(k not in ['1','2','3','4','5','6'] or type(v) is not int or v<=0 for k,v in d.items()):raise ValueError('invalid capture backlog counters')
    return value

def summarize(data):
    if data.get('schema') != 1 or not isinstance(data.get('frames'), list):
        raise ValueError('unsupported incident schema')
    run_id=data.get('runID')
    clock_origin=data.get('clockOriginMicros')
    if 'clockOriginMicros' in data and (type(clock_origin) is not int or not 0<=clock_origin<=9_000_000_000_000_000):raise ValueError('invalid clock origin')
    if 'runID' in data and (not isinstance(run_id,str) or not re.fullmatch(r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}',run_id)):
        raise ValueError('invalid diagnostic run ID')
    lanes={1:'hid',2:'main',3:'onset',4:'mismatch',5:'annotated_boundary',6:'onset_ax',7:'mismatch_ax',8:'source_boundary'}
    triggers={1:'manual',2:'callback_delay',3:'ax_delay',4:'possible_length_shrink',5:'source_boundary_interrupted',6:'recovery_started'}
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
    manual_edit_stages=collections.Counter()
    wait_reasons={13:'snapshot',14:'text',15:'caret',16:'repair',17:'repair_receipt',18:'onset_receipt',19:'replay_receipt',20:'focus',21:'selection_commit',22:'source_commit'}
    boundary_waits=collections.Counter()
    editor_outcomes=collections.Counter()
    editor_stages={23:"input_resumed_without_switch",24:"insertion_style_matched",25:"terminal_lf_matched",26:"terminal_lf_and_style_matched",27:"delivered_prefix_pending",28:"initial_body_removal_matched"}
    maximum_boundary_queue=0
    maximum_unconfirmed_onsets=0
    decision_sites={1:'event',2:'sample',3:'eligibility',4:'handoff',5:'repair'}
    decision_reasons=dict(enumerate([
        'roman_source','observation_blocked','pre_switch_key','snapshot_unavailable',
        'candidate_rejected_key','candidate_cancelled_navigation','candidate_recorded','no_candidate','candidate_expired','candidate_text_mismatch',
        'repair_blocked','repair_source_unsupported','repair_text_mismatch','selection_not_writable',
        'handoff_busy','handoff_not_ready','handoff_external_edit','handoff_selection','handoff_field','handoff_source','handoff_boundary',
        'handoff_no_history','handoff_expired','handoff_text_mismatch','handoff_accepted',
        'manual_edit','keyboard_capture','onset_repair','onset_reservation','handoff_uninitialized','observation_allowed'],start=1))
    storage=storage_status(data['storageBeforeWrite']) if 'storageBeforeWrite' in data else None
    preservation=capture_preservation(data['capturePreservation']) if 'capturePreservation' in data else None
    backlog=capture_backlog(data['captureBacklog']) if 'captureBacklog' in data else None
    delivery=data.get('decisionDelivery')
    queue_overflow=[]
    if delivery is not None:
        if not isinstance(delivery,dict) or set(delivery)-{'waits','coalesced'}!={'capacity','overflow'} or type(delivery['capacity']) is not int or not 2<=delivery['capacity']<=16384 or not isinstance(delivery['overflow'],dict):
            raise ValueError('invalid decision delivery')
        for key,count in delivery['overflow'].items():
            try:code=int(key)
            except (ValueError,TypeError):raise ValueError('invalid overflow code')
            if str(code)!=key or not 0<=code<310 or type(count) is not int or count<=0:raise ValueError('invalid overflow counter')
            decision,has_event=divmod(code,2)
            site,reason=divmod(decision,31)
            queue_overflow.append(dict(site=decision_sites[site+1],reason=decision_reasons[reason+1],event_bound=bool(has_event),count=count))
    decision_coalesced=None
    if delivery is not None and 'coalesced' in delivery:
        values=delivery['coalesced']
        if not isinstance(values,dict) or len(values)>310:raise ValueError('invalid decision coalesced counters')
        decision_coalesced=[]
        for key,count in values.items():
            try:code=int(key)
            except (ValueError,TypeError):raise ValueError('invalid coalesced decision code')
            if str(code)!=key or not 0<=code<310 or type(count) is not int or count<=0:raise ValueError('invalid coalesced decision count')
            decision,has_event=divmod(code,2);site,reason=divmod(decision,31)
            decision_coalesced.append(dict(site=decision_sites[site+1],reason=decision_reasons[reason+1],event_bound=bool(has_event),count=count))
    timing_totals=None
    if delivery is not None and 'waits' in delivery:
        waits=delivery['waits']
        if not isinstance(waits,dict) or len(waits)>310:raise ValueError('invalid decision wait stats')
        timing_totals=[]
        for key,value in waits.items():
            try:code=int(key)
            except (ValueError,TypeError):raise ValueError('invalid wait code')
            fields={'processed','contended','totalLockWaitMicros','maxLockWaitMicros','maxQueueMicros','clipped'}
            if str(code)!=key or not 0<=code<310 or not isinstance(value,dict) or set(value)!=fields or any(type(n) is not int or n<0 for n in value.values()):raise ValueError('invalid wait stats')
            if value['processed']<=0 or value['contended']>value['processed'] or value['clipped']>value['processed'] or value['maxLockWaitMicros']>60_000_000 or value['maxQueueMicros']>60_000_000 or value['maxLockWaitMicros']>value['totalLockWaitMicros'] or (value['contended']==0 and value['totalLockWaitMicros']!=0):raise ValueError('inconsistent wait stats')
            decision,has_event=divmod(code,2);site,reason=divmod(decision,31)
            timing_totals.append(dict(site=decision_sites[site+1],reason=decision_reasons[reason+1],event_bound=bool(has_event),**value))
    observations=data.get('observationDelivery')
    observation_summary=None
    if 'observationDelivery' in data:
        required={'capacity','readCapacity','processed','overflow','omitted','coalesced'}
        if not isinstance(observations,dict) or set(observations)-{'waits'}!=required or type(observations['capacity']) is not int or not 4<=observations['capacity']<=16384 or type(observations['readCapacity']) is not int or not 1<=observations['readCapacity']<=128:raise ValueError('invalid observation delivery')
        observation_summary={'capacity':observations['capacity'],'read_capacity':observations['readCapacity']}
        names=['event','read_start','read_end','shape','state','context','source_boundary','marker','timer','capture']
        for group in ['processed','overflow','omitted','coalesced']:
            values=observations[group]
            if not isinstance(values,dict) or len(values)>2560:raise ValueError('invalid observation counters')
            result=[]
            for key,n in values.items():
                try:code=int(key)
                except (ValueError,TypeError):raise ValueError('invalid observation code')
                if str(code)!=key or not 0<=code<2560 or type(n) is not int or n<=0:raise ValueError('invalid observation code/count')
                operation,rest=divmod(code,256);lane,detail=divmod(rest,32)
                valid=detail in ([1,2,3,5,6,7] if operation==0 else range(1,9) if operation==4 else ([0]+list(range(1,8)) if lane==3 else ([0]+list(range(8,13))+list(range(17,22)) if lane==1 else [0]+list(range(8,13)) if lane<3 else [0])) if operation==5 else range(1,32) if operation==6 else [1,2,3,4,5,6,9,10,11,12,13,14,17,25,26,27,28,29,30] if operation==9 else [0])
                if not valid or (group=='coalesced' and not (operation==3 or (operation==5 and lane==3 and detail>0))):raise ValueError('invalid observation detail')
                row=dict(operation=names[operation],lane=lanes[lane+1],detail=detail,count=n)
                if operation==5 and lane<3 and 8<=detail<=12:row.update(control_role=CONTROL_ROLES[detail-8])
                if operation==0:row.update(edge={1:'down',2:'up',3:'other'}[detail%4],consumed=detail>=4)
                if operation==9:row.update(trigger=triggers[detail%8],reason=('post_capture' if detail>=24 else 'capture') if group=='processed' else 'pending_capture' if detail<8 else 'automatic_interval' if detail<16 else 'manual_limit')
                result.append(row)
            observation_summary[group]=result
    def valid_timing(timing):
        return isinstance(timing,dict) and set(timing)=={'queueMicros','lockWaitMicros','contended','clipped'} and type(timing['queueMicros']) is int and type(timing['lockWaitMicros']) is int and type(timing['contended']) is bool and type(timing['clipped']) is bool and 0<=timing['queueMicros']<=60_000_000 and 0<=timing['lockWaitMicros']<=60_000_000 and (timing['contended'] or timing['lockWaitMicros']==0)
    observation_totals=None
    if observations is not None and 'waits' in observations:
        waits=observations['waits']
        if not isinstance(waits,dict) or set(waits)!=set(observations['processed']):raise ValueError('invalid observation waits')
        observation_totals=[]
        for row,(key,value) in zip(observation_summary['processed'],observations['processed'].items()):
            value=waits[key]
            fields={'processed','contended','totalLockWaitMicros','maxLockWaitMicros','maxQueueMicros','clipped'}
            if not isinstance(value,dict) or set(value)!=fields or any(type(n) is not int or n<0 for n in value.values()):raise ValueError('invalid observation wait stats')
            if value['processed']!=observations['processed'][key] or value['contended']>value['processed'] or value['clipped']>value['processed'] or value['maxLockWaitMicros']>60_000_000 or value['maxQueueMicros']>60_000_000 or value['maxLockWaitMicros']>value['totalLockWaitMicros'] or (value['contended']==0 and value['totalLockWaitMicros']!=0):raise ValueError('inconsistent observation waits')
            if row['operation']=='capture' and row['detail'] not in [1,2,3,4,5,6,25,26,27,28,29,30]:raise ValueError('invalid capture wait code')
            observation_totals.append(dict(row,**value))
    capture_timing=data.get('captureTiming')
    if 'captureTiming' in data and not valid_timing(capture_timing):raise ValueError('invalid capture timing')
    observation_lock_waits=[]
    observation_delays=[]
    decision_delays=[]
    lock_waits=[]
    decision_counts=collections.defaultdict(collections.Counter)
    event_decisions=[]
    control_rows=[]
    source_evidence_rows=[]
    shape_rows=[]
    key_rows=[]
    hud_rows=[]
    baselines=shape_baselines(data['shapeBaselines']) if 'shapeBaselines' in data else None
    source_actions=dict(enumerate(["observed","requested","committed","deferred","resumed","rejected","roman_skipped"],start=1))
    for frame in data['frames']:
        lane=lanes.get(frame['lane'],'unknown')
        if 'eventEvidence' in frame:
            value=event_evidence(frame['eventEvidence'])
            if frame['kind'] not in [1,11] or frame['lane'] not in [1,2] or frame['event']<=0 or value['observedAtMicros']//1000!=frame['milliseconds']:raise ValueError('invalid event evidence frame')
            key_rows.append(dict(sequence=frame['sequence'],milliseconds=frame['milliseconds'],event=frame['event'],kind=frame['kind'],edge=frame['edge'],inputOrigin=frame['inputOrigin'],lane=lane,key_class_name=KEY_CLASSES[value['keyClass']],**value))
            key_rows[-1]['os_to_observation_us']=clock_origin+value['observedAtMicros']-value['timestampMicros'] if clock_origin is not None and value['timestampMicros']>0 else None
        if frame['kind']==12:
            if any(type(frame[k]) is not int for k in ['lane','edge','category','event']) or frame['lane']!=2 or frame['edge'] not in HUD_STAGES or frame['category'] not in range(5) or frame['event']<0 or not frame.get('observationTiming') or any(frame.get(k,0)!=0 for k in ['inputOrigin','durationMicros','count','field']) or frame.get('consumed',False) or frame.get('selected',False) or any(k in frame for k in ['controlEvidence','sourceEvidence','shapeEvidence','eventEvidence']):raise ValueError('invalid HUD frame')
            hud_rows.append(dict(sequence=frame['sequence'],milliseconds=frame['milliseconds'],presentation_id=frame['event'],stage=HUD_STAGES[frame['edge']],source_class=frame['category']))
        if 'shapeEvidence' in frame:
            evidence=shape_evidence(frame['shapeEvidence'])
            if frame['kind']!=3 or frame.get('field',0)<=0 or evidence['baselineSequence']>frame['sequence'] or frame['milliseconds']!=evidence['lastMilliseconds'] or (evidence['phase']==1 and evidence['baselineSequence']!=frame['sequence']):raise ValueError('invalid shape frame')
            shape_rows.append(dict(sequence=frame['sequence'],milliseconds=frame['milliseconds'],lane=lane,field=frame['field'],count=frame['count'],selected=frame['selected'],**evidence,**({'ax_interpretation':describe_ax(evidence['ax'])} if 'ax' in evidence else {})))
            if 'caretPrecedingClass' in evidence:shape_rows[-1]['caret_preceding_class_name']=CARET_CLASSES[evidence['caretPrecedingClass']]
        maxima[lane]=max(maxima[lane],frame['durationMicros'])
        timing=frame.get('decisionTiming')
        if 'decisionTiming' in frame:
            if frame['kind']!=8 or not isinstance(timing,dict) or set(timing)!={'queueMicros','lockWaitMicros','contended','clipped'} or type(timing['queueMicros']) is not int or type(timing['lockWaitMicros']) is not int or type(timing['contended']) is not bool or type(timing['clipped']) is not bool or not 0<=timing['queueMicros']<=60_000_000 or not 0<=timing['lockWaitMicros']<=60_000_000 or (not timing['contended'] and timing['lockWaitMicros']!=0):raise ValueError('invalid decision timing')
        observed=frame.get('observationTiming')
        if 'observationTiming' in frame:
            if frame['kind']==8 or not valid_timing(observed):raise ValueError('invalid observation timing')
            if observed['contended'] or observed['clipped'] or observed['queueMicros']>=50_000:
                observation_delays.append(dict(sequence=frame['sequence'],milliseconds=frame['milliseconds'],lane=lane,kind=frame['kind'],event=frame['event'],edge=frame['edge'],category=frame['category'],**observed))
            if observed['contended']:
                observation_lock_waits.append(dict(sequence=frame['sequence'],milliseconds=frame['milliseconds'],lane=lane,kind=frame['kind'],event=frame['event'],edge=frame['edge'],category=frame['category'],**observed))
        if 'controlEvidence' in frame or frame['kind']==11:
            value=control_evidence(frame.get('controlEvidence'))
            if frame['kind']!=11 or frame['lane'] not in [1,2,3] or frame['edge']!=value['role'] or frame['category']!=value['route'] or not observed or frame['event']<0 or frame['inputOrigin'] not in range(4) or any(frame.get(k,0)!=0 for k in ['durationMicros','count','field']) or frame.get('selected',False):raise ValueError('invalid control frame')
            control_rows.append(dict(sequence=frame['sequence'],milliseconds=frame['milliseconds'],event=frame['event'],lane=lane,consumed=frame['consumed'],role_name=CONTROL_ROLES[value['role']],route_name=CONTROL_ROUTES[value['route']],query_status_name=['unqueried','current_unavailable','list_unavailable','target_missing','resolved','current_only'][value['queryStatus']],filter_reason_name=['unmeasured','down_accepted','up_drained','no_right_bit','already_down','disallowed','consuming','other_event'][value['filterReason']],**value))
        if 'sourceEvidence' in frame or frame['kind']==10:
            value=source_evidence(frame.get('sourceEvidence'))
            if frame['kind']!=10 or frame['lane']!=4 or frame['edge'] not in source_actions or frame['category']!=value['selected'] or not observed or frame['event']<0 or frame['inputOrigin'] not in range(4) or any(frame.get(k,0)!=0 for k in ['durationMicros','count','field']) or frame.get('consumed',False) or frame.get('selected',False):raise ValueError('invalid source evidence frame')
            source_evidence_rows.append(dict(sequence=frame['sequence'],milliseconds=frame['milliseconds'],event=frame['event'],action=source_actions[frame['edge']],**value))
        if frame['kind']==9:
            op=frame['category'];detail=frame['edge']
            allowed=[1,2,3,5,6,7] if op==1 else range(1,9) if op==5 else ([0]+list(range(1,8)) if frame["lane"]==4 else ([0]+list(range(8,13))+list(range(17,22)) if frame['lane']==2 else [0]+list(range(8,13)) if frame['lane'] in [1,2,3] else [0])) if op==6 else range(1,32) if op==7 else [1,2,3,4,5,6,25,26,27,28,29,30] if op==10 else [0]
            if not observed or not 1<=op<=10 or detail not in allowed or any(frame.get(k,0)!=0 for k in ['event','inputOrigin','durationMicros','count','field']) or frame.get('consumed',False) or frame.get('selected',False):raise ValueError('invalid observation wait frame')
        if frame['kind']==8:
            site=decision_sites.get(frame['edge'],'unknown')
            reason=decision_reasons.get(frame['category'],'unknown')
            decision_counts[site][reason]+=1
            detail=dict(event=frame['event'],milliseconds=frame['milliseconds'],site=site,reason=reason)
            if timing is not None:
                detail.update(timing)
                if timing['contended']:lock_waits.append(detail)
                if timing['contended'] or timing['clipped'] or timing['queueMicros']>=50_000:decision_delays.append(detail)
            if frame['event']:event_decisions.append(detail)
        if frame['kind']==1 and frame['edge']==1:
            kind={1:'ordinary_or_external',2:'repair',3:'state_only'}.get(frame['inputOrigin'],'unknown')
            counts[lane][kind+'_downs']+=1
            counts[lane]['consumed_downs' if frame['consumed'] else 'passed_downs']+=1
            if frame['inputOrigin']==1:ordinary[frame['event']].setdefault(lane,frame['milliseconds'])
        if frame['kind']==6:
            state_counts[lane][str(frame['category'])]+=1
            pending_max[lane]=max(pending_max[lane],frame.get('count',0))
        if frame['kind']==7:
            if frame['category'] in [29,30,31]:manual_edit_stages[{29:'started',30:'verified',31:'unverified'}[frame['category']]]+=1
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
    return {'build':data.get('build'),'diagnostic_run_id':run_id,'clock_origin_micros':clock_origin,'incident':data.get('incident'),'phase':data.get('phase'),
            'trigger':triggers.get(data['trigger'],'unknown'),'frames':len(data['frames']),
            'recovery_detections':None if preservation is None else [dict(r,lane_name=lanes[r['lane']],reason={1:'roman_mismatch',2:'mixed_insertion',3:'decomposed_jamo',4:'interrupted_composition',5:'fragmented_composition',6:'verified_replacement',7:'first_consonant',8:'late_sequence',9:'committed_late_sequence',10:'unspecified_mismatch'}[r['detail']],interpretation='detector_branch_only_not_root_cause') for r in preservation['requests'] if r['trigger']==6],
            'discarded_old_frames':data.get('discardedOldFrames'),'best_effort':True,
            'recipient_receipt_verified':False,'event_correlation_is_heuristic':True,
            'observed_keydown_counts':dict(counts),'maximum_correlated_hid_to_stage_ms':dict(transport_max),'maximum_observed_duration_us':dict(maxima),
            'peak_observed_ax_reads':peak,'cross_lane_ax_overlap_starts':overlap_starts,
            'open_or_unpaired_ax_reads':len(active)+unpaired_ends,'recovery_state_counts':dict(state_counts),'maximum_observed_owned_pending_events':dict(pending_max),
            'key_event_evidence':key_rows,'hud_stages':hud_rows,'switch_timelines':switch_timelines(source_evidence_rows,control_rows,key_rows,hud_rows,shape_rows),
            'shape_observations':shape_rows,'shape_baselines':baselines,'control_decisions':control_rows,'source_evidence':source_evidence_rows,'manual_edit_boundary_counts':dict(manual_edit_stages),'source_boundary_stage_counts':dict(boundary_stages),'maximum_source_boundary_queue':maximum_boundary_queue,'maximum_unconfirmed_onset_receipts':maximum_unconfirmed_onsets,
            'decision_coalesced':decision_coalesced,'decision_queue_capacity':delivery['capacity'] if delivery is not None else None,'decision_queue_overflow':queue_overflow,
            'observation_delivery':observation_summary,'storage_before_write':storage,
            'capture_preservation':preservation,'capture_backlog':backlog,
            'observation_wait_totals':observation_totals,'observation_lock_waits':observation_lock_waits,'capture_timing':capture_timing,
            'decision_wait_totals':timing_totals,'decision_lock_waits':lock_waits,'decision_delays':decision_delays,'observation_delays':observation_delays,
            'detection_decision_counts':dict(decision_counts),'correlated_detection_decisions':event_decisions,
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
        print(json.dumps(summarize_storage_document(data) if 'status' in data else summarize(data),ensure_ascii=False,indent=2))


if __name__=='__main__':main()

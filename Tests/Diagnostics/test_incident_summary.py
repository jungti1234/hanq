import importlib.util
import pathlib
import unittest

spec=importlib.util.spec_from_file_location('summary',pathlib.Path(__file__).resolve().parents[2]/'scripts/summarize-input-incident.py')
summary=importlib.util.module_from_spec(spec);spec.loader.exec_module(summary)

def frame(lane,kind,event=0,category=0,ms=0,origin=1,consumed=False):
    return dict(lane=lane,kind=kind,event=event,category=category,milliseconds=ms,durationMicros=0,edge=1,inputOrigin=origin,consumed=consumed)

class IncidentSummaryTests(unittest.TestCase):
    def test_switch_evidence_and_hud_privacy(self):
        timing=dict(queueMicros=0,lockWaitMicros=0,contended=False,clipped=False)
        evidence=dict(observedAtMicros=20000,timestampMicros=100020000,keyClass=1)
        row=dict(frame(1,1,event=1,ms=20),sequence=1,eventEvidence=evidence)
        hud=dict(frame(2,12,category=1,ms=50,origin=0),sequence=2,edge=3,observationTiming=timing)
        result=summary.summarize(dict(schema=1,trigger=1,frames=[row,hud]))
        self.assertEqual(result['key_event_evidence'][0]['key_class_name'],'space')
        self.assertEqual(result['hud_stages'][0]['stage'],'first_appkit_draw')
        self.assertEqual(summary.summarize(dict(schema=1,trigger=1,frames=[]))['key_event_evidence'],[])
        for bad in [dict(evidence,keyCode=17),dict(evidence,keyClass=True),dict(evidence,keyClass=7),dict(evidence,observedAtMicros=-1),dict(evidence,timestampMicros='private')]:
            with self.assertRaises(ValueError):summary.summarize(dict(schema=1,trigger=1,frames=[dict(row,eventEvidence=bad)]))
        for bad in [dict(lane=3),dict(kind=3),dict(event=0),dict(milliseconds=21)]:
            with self.assertRaises(ValueError):summary.summarize(dict(schema=1,trigger=1,frames=[dict(row,**bad)]))
        for bad in [dict(edge=6),dict(category=5),dict(lane=1),dict(event=-1),dict(edge=True),dict(category=True),dict(event=True),dict(inputOrigin=1),dict(eventEvidence=evidence)]:
            with self.assertRaises(ValueError):summary.summarize(dict(schema=1,trigger=1,frames=[dict(hud,**bad)]))
        for origin in [None,True,-1,9_000_000_000_000_001,'private']:
            with self.assertRaises(ValueError):summary.summarize(dict(schema=1,trigger=1,frames=[],clockOriginMicros=origin))
        zero=summary.summarize(dict(schema=1,trigger=1,frames=[dict(row,eventEvidence=dict(evidence,timestampMicros=0))],clockOriginMicros=100000000))
        self.assertIsNone(zero['key_event_evidence'][0]['os_to_observation_us'])

    def test_switch_report_distinguishes_space_and_latin_observation_without_claiming_cause(self):
        request=dict(sequence=4,milliseconds=30,action='requested',target=1,targetEventMilliseconds=100030)
        commit=dict(sequence=6,milliseconds=40,action='committed',target=1,targetEventMilliseconds=100030)
        control=dict(event=2,lane='main',milliseconds=30,filterEdge=1,filterConsumed=True)
        keys=[dict(event=1,kind=1,edge=1,inputOrigin=1,lane='hid',observedAtMicros=20000,timestampMicros=100020000,keyClass=1),
              dict(event=2,kind=11,edge=1,inputOrigin=1,lane='hid',observedAtMicros=30000,timestampMicros=100030000,keyClass=4),
              dict(event=3,kind=1,edge=1,inputOrigin=1,lane='hid',observedAtMicros=200000,timestampMicros=100190000,keyClass=2)]
        hud=[dict(milliseconds=50,stage='requested'),dict(milliseconds=80,stage='first_appkit_draw')]
        shapes=[dict(milliseconds=220,contentChanged=True,editing=False,caretPrecedingClass=1)]
        r=summary.switch_timelines([request,commit],[control],keys,hud,shapes)[0]
        self.assertEqual(r['previous_key']['keyClass'],1)
        self.assertEqual(r['previous_key']['os_relative_to_switch_us'],-10000)
        self.assertEqual(r['following_keys'][0]['observed_relative_to_switch_us'],170000)
        self.assertEqual(r['following_keys'][0]['os_relative_to_switch_us'],160000)
        self.assertEqual(r['selection_confirmed_after_ms'],10)
        self.assertEqual(r['changed_shapes'][0]['caretPrecedingClass'],1)
        self.assertIn('unverified',r['interpretation'])
        self.assertEqual(summary.switch_timelines([request],[],[],[],[])[0]['following_keys'],[])

    def test_recovery_start_cause_and_strict_compatibility(self):
        request=dict(trigger=6,milliseconds=100,afterSequence=10,lane=4,detail=4,event=0,inputOrigin=0)
        preserved=dict(deferred=True,requests=[request],postCapacity=4096,postOmittedFrames=0,closed=True,closedMilliseconds=1100,endedOnShutdown=False)
        data=dict(schema=1,trigger=6,frames=[],capturePreservation=preserved)
        result=summary.summarize(data)
        self.assertEqual(result['trigger'],'recovery_started')
        self.assertEqual(result['recovery_detections'][0]['reason'],'interrupted_composition')
        self.assertEqual(result['recovery_detections'][0]['milliseconds'],100)
        self.assertIsNone(summary.summarize(dict(schema=1,trigger=1,frames=[]))['recovery_detections'])
        for lane,details in [(4,[1,2,3,4,5,6,10]),(3,[7,8,9])]:
            for detail in details:
                r=dict(request,lane=lane,detail=detail)
                self.assertEqual(len(summary.summarize(dict(data,capturePreservation=dict(preserved,requests=[r])))['recovery_detections']),1)
        for change in [dict(detail=0),dict(detail=11),dict(detail=7),dict(lane=2),dict(event=1),dict(text='PRIVATE')]:
            with self.assertRaises(ValueError):summary.summarize(dict(data,capturePreservation=dict(preserved,requests=[dict(request,**change)])))

    def test_capture_preservation_backlog_and_privacy(self):
        request=dict(trigger=5,milliseconds=20,afterSequence=10,lane=8,detail=31,event=0,inputOrigin=0)
        preserved=dict(deferred=True,requests=[request],postCapacity=4096,postOmittedFrames=0,closed=True,closedMilliseconds=1020,endedOnShutdown=False)
        backlog=dict(automaticCapacity=16,manualCapacity=4,requestCapacityPerTrigger=16,requestsPerWindow=32,pendingAutomatic=1,pendingManual=0,requested={'5':1},merged={},deferred={'5':1},requestOverflow={},windowOverflow={},postOverflow={},discardedOnDisable={},submittedWindows=1,completedWindows=0)
        data=dict(schema=1,trigger=5,frames=[],capturePreservation=preserved,captureBacklog=backlog)
        result=summary.summarize(data)
        self.assertEqual(result['capture_preservation']['requests'][0]['detail'],31)
        self.assertEqual(result['capture_backlog']['deferred'],{'5':1})
        old=summary.summarize(dict(schema=1,trigger=1,frames=[]))
        self.assertIsNone(old['capture_preservation']);self.assertIsNone(old['capture_backlog'])
        for bad in [None,dict(preserved,text='private'),dict(preserved,postCapacity=0),dict(preserved,postOmittedFrames=True),dict(preserved,closed=False),dict(preserved,requests=[dict(request,keyCode=1)]),dict(preserved,requests=[dict(request,milliseconds='private')]),dict(preserved,requests=[request]*33)]:
            with self.assertRaises(ValueError):summary.summarize(dict(data,capturePreservation=bad))
        for bad in [None,dict(backlog,text='private'),dict(backlog,pendingAutomatic=17),dict(backlog,requestOverflow={'7':1}),dict(backlog,completedWindows=2),dict(backlog,merged={'05':1}),dict(backlog,requested={'5':True})]:
            with self.assertRaises(ValueError):summary.summarize(dict(data,captureBacklog=bad))

    def test_shape_spans_baselines_and_strict_privacy(self):
        evidence=dict(phase=1,comparisonKnown=True,contentChanged=True,selectionChanged=False,editingChanged=False,gap=False,editing=False,firstMilliseconds=20,lastMilliseconds=20,observations=1,coalesced=0,baselineSequence=4)
        row=dict(frame(7,3,ms=20),sequence=4,field=1,count=1,selected=False,shapeEvidence=evidence)
        current=dict(field=1,count=1,selected=False,evidence=dict(evidence,phase=2,lastMilliseconds=100,observations=5,coalesced=4))
        baseline=dict(lane=7,active=True,current=current)
        data=dict(schema=1,trigger=1,frames=[row],shapeBaselines=[baseline])
        result=summary.summarize(data)
        self.assertTrue(result['shape_observations'][0]['contentChanged'])
        self.assertEqual(result['shape_baselines'][0]['current']['evidence']['lastMilliseconds'],100)
        self.assertIsNone(summary.summarize(dict(schema=1,trigger=1,frames=[]))['shape_baselines'])
        for bad in [dict(text='private'),dict(editing=1),dict(gap=True),dict(observations=0),dict(firstMilliseconds=21),dict(phase=4),dict(coalesced=1),dict(comparisonKnown=False),dict(editing=None)]:
            with self.assertRaises(ValueError):summary.summarize(dict(data,frames=[dict(row,shapeEvidence=dict(evidence,**bad))]))
        for bad in [dict(kind=1),dict(sequence=3),dict(milliseconds=21),dict(field=0)]:
            with self.assertRaises(ValueError):summary.summarize(dict(data,frames=[dict(row,**bad)]))
        for bad in [None,[baseline,baseline],[dict(baseline,active=1)],[dict(baseline,private='text')],[dict(baseline,previous=None)]]:
            with self.assertRaises(ValueError):summary.summarize(dict(data,shapeBaselines=bad))

    def test_source_evidence_is_typed_and_old_records_remain_compatible(self):
        timing=dict(queueMicros=0,lockWaitMicros=0,contended=False,clipped=False)
        evidence=dict(selected=6,confirmed=1,target=1,observedAtMilliseconds=100010,targetEventMilliseconds=100000,ageClipped=False,confirmedAtMilliseconds=100000,targetAtMilliseconds=99900,confirmedAgeMicros=10000,targetAgeMicros=110000,committed=True,deferred=True,candidatePreserved=False,historyPreserved=True)
        record=dict(frame(4,10,event=42,category=6),sequence=1,edge=4,sourceEvidence=evidence,observationTiming=timing)
        result=summary.summarize(dict(schema=1,trigger=1,frames=[record]))['source_evidence'][0]
        self.assertEqual(result['action'],'deferred');self.assertEqual(result['event'],42)
        self.assertEqual(result['confirmedAtMilliseconds'],100000)
        self.assertEqual(summary.summarize(dict(schema=1,trigger=1,frames=[]))['source_evidence'],[])
        for bad in [dict(selected='private source'),dict(confirmed=8),dict(targetAgeMicros=60000001),dict(confirmedAtMilliseconds=None),dict(private='typed input'),dict(committed=1),dict(ageClipped=0)]:
            with self.assertRaises(ValueError):summary.summarize(dict(schema=1,trigger=1,frames=[dict(record,sourceEvidence=dict(evidence,**bad))]))
        for bad in [dict(kind=1),dict(lane=2),dict(edge=8),dict(category=1)]:
            with self.assertRaises(ValueError):summary.summarize(dict(schema=1,trigger=1,frames=[dict(record,**bad)]))

    def test_run_identity_is_optional_and_strict(self):
        data=dict(schema=1,trigger=1,frames=[])
        self.assertIsNone(summary.summarize(data)['diagnostic_run_id'])
        run='12345678-1234-1234-1234-123456789ABC'
        self.assertEqual(summary.summarize(dict(data,runID=run))['diagnostic_run_id'],run)
        for bad in ['',None,42,True,'PRIVATE_TEXT',run+'!']:
            with self.assertRaises(ValueError):summary.summarize(dict(data,runID=bad))

    def test_decision_repeat_suppression_is_typed_and_optional(self):
        result=summary.summarize(dict(schema=1,trigger=1,frames=[],decisionDelivery=dict(capacity=4096,overflow={},coalesced={'76':9})))
        self.assertEqual(result['decision_coalesced'],[dict(site='sample',reason='no_candidate',event_bound=False,count=9)])
        self.assertIsNone(summary.summarize(dict(schema=1,trigger=1,frames=[]))['decision_coalesced'])
        for value in [{'076':1},{'310':1},{'76':True},{'76':0},[]]:
            with self.assertRaises(ValueError):summary.summarize(dict(schema=1,trigger=1,frames=[],decisionDelivery=dict(capacity=4096,overflow={},coalesced=value)))

    def test_queue_only_delayed_idle_decision_and_fallback_are_visible(self):
        timing=dict(queueMicros=50000,lockWaitMicros=0,contended=False,clipped=False)
        decision=dict(frame(4,8,category=8,origin=0),edge=2,decisionTiming=timing)
        fallback=dict(frame(2,9,category=9,origin=0),sequence=1,edge=0,observationTiming=timing)
        data=dict(schema=1,trigger=1,frames=[decision,fallback])
        result=summary.summarize(data)
        self.assertEqual(len(result['decision_delays']),1)
        self.assertEqual(result['decision_delays'][0]['event'],0)
        self.assertEqual(result['decision_delays'][0]['reason'],'no_candidate')
        self.assertEqual(len(result['observation_delays']),1)
        self.assertEqual(result['decision_lock_waits'],[])
        self.assertEqual(result['observation_lock_waits'],[])

    def test_storage_prior_and_current_status_are_distinct_and_strict(self):
        value={key:0 for key in summary.STORAGE_FIELDS}
        value.update(maximumAutomaticFiles=64,maximumAutomaticBytes=67108864,lastAutomatic=False)
        old=summary.summarize(dict(schema=1,trigger=1,frames=[]))
        self.assertIsNone(old['storage_before_write'])
        prior=summary.summarize(dict(schema=1,trigger=1,frames=[],storageBeforeWrite=value))
        self.assertEqual(prior['storage_before_write']['last_result_name'],'none')
        current=dict(value,attempts=3,saved=1,limited=1,unavailable=1,lastResult=4,lastFailureStage=4,lastErrno=13,lastIncident=3,automaticFiles=1,automaticBytes=500,evictedFiles=2,evictedGroups=1,evictedBytes=100)
        result=summary.summarize_storage_document(dict(schema=1,build='244',status=current))
        self.assertEqual(result['storage_after_write']['last_failure_stage_name'],'publication')
        self.assertEqual(result['storage_after_write']['evictedFiles'],2)
        for key,n in [('text','PRIVATE'),('attempts',True),('automaticBytes',67108865),('saved',4),('lastResult',0),('lastFailureStage',0),('lastAutomatic',1),('lastWriteMicros',60000001),('statusWriteFailures',4),('lastErrno',2147483648)]:
            with self.assertRaises(ValueError):summary.summarize_storage_document(dict(schema=1,build='244',status=dict(current,**{key:n})))
        for doc in [dict(schema=1,build='private text',status=current),dict(schema=True,build='244',status=current),dict(schema=1,build='244',status=current,text='PRIVATE')]:
            with self.assertRaises(ValueError):summary.summarize_storage_document(doc)

    def test_general_observation_timing_and_capture_are_distinct(self):
        timing=dict(queueMicros=10000,lockWaitMicros=40000,contended=True,clipped=False)
        stats=dict(processed=3,contended=1,totalLockWaitMicros=40000,maxLockWaitMicros=40000,maxQueueMicros=50000,clipped=0)
        obs=dict(capacity=4096,readCapacity=128,processed={'1124':3},overflow={},omitted={},coalesced={},waits={'1124':stats})
        record=dict(frame(4,6,category=4),sequence=1,observationTiming=timing)
        result=summary.summarize(dict(schema=1,trigger=1,frames=[record],observationDelivery=obs,captureTiming=timing))
        self.assertEqual(result['observation_lock_waits'][0]['lockWaitMicros'],40000)
        self.assertEqual(result['observation_wait_totals'][0]['operation'],'state')
        self.assertEqual(result['observation_wait_totals'][0]['processed'],3)
        self.assertEqual(result['capture_timing'],timing)
        old=summary.summarize(dict(schema=1,trigger=1,frames=[],observationDelivery={k:v for k,v in obs.items() if k!='waits'}))
        self.assertIsNone(old['observation_wait_totals'])
        for bad in [dict(timing,lockWaitMicros=-1),dict(timing,contended=False),dict(timing,text='PRIVATE')]:
            with self.assertRaises(ValueError):summary.summarize(dict(schema=1,trigger=1,frames=[dict(record,observationTiming=bad)]))
            with self.assertRaises(ValueError):summary.summarize(dict(schema=1,trigger=1,frames=[],captureTiming=bad))
        for invalid in [dict(obs,waits={}),dict(obs,waits={'1124':dict(stats,processed=2)}),dict(obs,waits={'1124':dict(stats,clipped=4)}),dict(obs,waits={'1124':dict(stats,text='PRIVATE')})]:
            with self.assertRaises(ValueError):summary.summarize(dict(schema=1,trigger=1,frames=[],observationDelivery=invalid))
        with self.assertRaises(ValueError):summary.summarize(dict(schema=1,trigger=1,frames=[dict(record,kind=8)]))
        post=dict(capacity=4096,readCapacity=128,processed={'2361':3},overflow={},omitted={},coalesced={},waits={'2361':stats})
        self.assertEqual(summary.summarize(dict(schema=1,trigger=1,frames=[],observationDelivery=post))['observation_wait_totals'][0]['reason'],'post_capture')

    def test_observation_overflow_and_omission_are_typed_and_optional(self):
        delivery=dict(capacity=8,readCapacity=1,processed={'6':4,'896':1},overflow={'6':1,'1124':2},omitted={'2657':1},coalesced={'960':1})
        # event/hid consumed up=6; state/mismatch retained=1124; capture/main callback=2338
        delivery['omitted']={'2338':1}
        result=summary.summarize(dict(schema=1,trigger=1,frames=[],observationDelivery=delivery))['observation_delivery']
        self.assertEqual(result['overflow'][0],dict(operation='event',lane='hid',detail=6,count=1,edge='up',consumed=True))
        self.assertEqual(result['overflow'][1]['operation'],'state')
        self.assertEqual(result['omitted'][0]['operation'],'capture')
        self.assertIsNone(summary.summarize(dict(schema=1,trigger=1,frames=[]))['observation_delivery'])
        for invalid in [dict(delivery,capacity=3),dict(delivery,readCapacity=0),dict(delivery,overflow={'2560':1}),dict(delivery,overflow={'06':1}),dict(delivery,overflow={'4':1}),dict(delivery,overflow={'6':True}),dict(delivery,coalesced={'6':1}),dict(delivery,text='PRIVATE')]:
            with self.assertRaises(ValueError):summary.summarize(dict(schema=1,trigger=1,frames=[],observationDelivery=invalid))

    def test_lock_timing_and_cumulative_stats_are_distinct_from_queue_delay(self):
        timing=dict(queueMicros=10000,lockWaitMicros=40000,contended=True,clipped=False)
        row=dict(frame(4,8,event=42,category=3),decisionTiming=timing)
        stats=dict(processed=3,contended=1,totalLockWaitMicros=40000,maxLockWaitMicros=40000,maxQueueMicros=50000,clipped=0)
        result=summary.summarize(dict(schema=1,trigger=1,frames=[row],decisionDelivery=dict(capacity=4096,overflow={},waits={'5':stats})))
        self.assertEqual(result['decision_lock_waits'],[dict(event=42,milliseconds=0,site='event',reason='pre_switch_key',**timing)])
        self.assertEqual(result['correlated_detection_decisions'][0]['lockWaitMicros'],40000)
        self.assertEqual(result['decision_wait_totals'],[dict(site='event',reason='pre_switch_key',event_bound=True,**stats)])
        old=summary.summarize(dict(schema=1,trigger=1,frames=[frame(4,8,event=42,category=3)]))
        self.assertIsNone(old['decision_wait_totals'])
        self.assertEqual(old['decision_lock_waits'],[])
        free=dict(row,decisionTiming=dict(timing,lockWaitMicros=0,contended=False))
        self.assertEqual(summary.summarize(dict(schema=1,trigger=1,frames=[free]))['decision_lock_waits'],[])
        for invalid in [dict(timing,lockWaitMicros=-1),dict(timing,queueMicros=60000001),dict(timing,contended=1),dict(timing,contended=False),dict(timing,text='PRIVATE')]:
            with self.assertRaises(ValueError):summary.summarize(dict(schema=1,trigger=1,frames=[dict(row,decisionTiming=invalid)]))
        for invalid in [dict(stats,processed=0),dict(stats,contended=4),dict(stats,maxLockWaitMicros=50000),dict(stats,clipped=True),dict(stats,text='PRIVATE')]:
            with self.assertRaises(ValueError):summary.summarize(dict(schema=1,trigger=1,frames=[],decisionDelivery=dict(capacity=4096,overflow={},waits={'5':invalid})))

    def test_decision_queue_overflow_is_distinct_from_trace_contention(self):
        delivery=dict(capacity=8,overflow={'5':10,'184':5000,'268':3})
        result=summary.summarize(dict(schema=1,trigger=1,frames=[],decisionDelivery=delivery))
        self.assertEqual(result['decision_queue_capacity'],8)
        self.assertEqual(result['decision_queue_overflow'],[
            dict(site='event',reason='pre_switch_key',event_bound=True,count=10),
            dict(site='eligibility',reason='observation_allowed',event_bound=False,count=5000),
            dict(site='repair',reason='repair_blocked',event_bound=False,count=3)])
        self.assertIsNone(summary.summarize(dict(schema=1,trigger=1,frames=[]))['decision_queue_capacity'])
        for invalid in [dict(capacity=1,overflow={}),dict(capacity=8,overflow={'310':1}),dict(capacity=8,overflow={'05':1}),dict(capacity=8,overflow={'5':-1}),dict(capacity=8,overflow={'5':True}),dict(capacity=8,overflow={},text='PRIVATE')]:
            with self.assertRaises(ValueError):summary.summarize(dict(schema=1,trigger=1,frames=[],decisionDelivery=invalid))

    def test_detection_decisions_correlate_without_claiming_loss(self):
        records=[dict(frame(4,8,event=42,category=category),edge=1) for category in [1,2,3]]
        records.append(dict(frame(4,8,category=30),edge=4))
        result=summary.summarize(dict(schema=1,trigger=1,frames=records))
        self.assertEqual(result['detection_decision_counts'],{'event':{'roman_source':1,'observation_blocked':1,'pre_switch_key':1},'handoff':{'handoff_uninitialized':1}})
        self.assertEqual([r['event'] for r in result['correlated_detection_decisions']],[42,42,42])
        self.assertFalse(result['recipient_receipt_verified'])
        old=summary.summarize(dict(schema=1,trigger=1,frames=[]))
        self.assertEqual(old['detection_decision_counts'],{})
        self.assertEqual(old['correlated_detection_decisions'],[])

    def test_editor_equivalence_and_resumed_input_are_not_source_commits(self):
        records=[dict(frame(8,7,category=category),count=0) for category in [23,24,25,26,27,28]]
        result=summary.summarize(dict(schema=1,trigger=5,frames=records))
        self.assertEqual(result['source_boundary_editor_outcomes'],{'input_resumed_without_switch':1,'insertion_style_matched':1,'terminal_lf_matched':1,'terminal_lf_and_style_matched':1,'delivered_prefix_pending':1,'initial_body_removal_matched':1})
        self.assertFalse(result['recipient_receipt_verified'])
        old=summary.summarize(dict(schema=1,trigger=5,frames=[]))
        self.assertEqual(old['source_boundary_editor_outcomes'],{})

    def test_wait_reasons_are_metadata_not_receipt(self):
        records=[dict(frame(8,7,category=category),count=0) for category in [14,15,13]]
        result=summary.summarize(dict(schema=1,trigger=5,frames=records))
        self.assertEqual(result['source_boundary_wait_reasons'],{'text':1,'caret':1,'snapshot':1})
        self.assertFalse(result['recipient_receipt_verified'])

    def test_boundary_retention_and_observation_loss_remain_distinct(self):
        record=frame(8,7,event=2,category=6);record['count']=13
        data=dict(schema=1,trigger=5,frames=[record],skippedEvents={'5':1},skippedAuxiliary={'8':2})
        result=summary.summarize(data)
        self.assertEqual(result['trigger'],'source_boundary_interrupted')
        self.assertEqual(result['maximum_source_boundary_queue'],13)
        self.assertEqual(result['maximum_unconfirmed_onset_receipts'],2)
        self.assertEqual(result['skipped_event_observations'],{'annotated_boundary':1})
        self.assertFalse(result['recipient_receipt_verified'])

    def test_partial_read_does_not_fabricate_overlap(self):
        data=dict(schema=1,trigger=1,frames=[frame(6,2,1,1,0),frame(7,2,2,1,1),frame(7,2,2,2,2)])
        result=summary.summarize(data)
        self.assertEqual(result['peak_observed_ax_reads'],1)
        self.assertEqual(result['cross_lane_ax_overlap_starts'],0)
        self.assertEqual(result['open_or_unpaired_ax_reads'],1)

    def test_complete_overlap_is_observed_not_causal(self):
        data=dict(schema=1,trigger=3,frames=[frame(6,2,1,1,0),frame(7,2,2,1,1),frame(6,2,1,2,3),frame(7,2,2,2,4)])
        result=summary.summarize(data)
        self.assertEqual(result['peak_observed_ax_reads'],2)
        self.assertEqual(result['cross_lane_ax_overlap_starts'],1)
        self.assertFalse(result['recipient_receipt_verified'])
        self.assertTrue(result['event_correlation_is_heuristic'])

    def test_correlated_transport_is_not_app_receipt(self):
        data=dict(schema=1,trigger=1,frames=[frame(1,1,event=1,ms=2),frame(2,1,event=1,ms=8),frame(5,1,event=1,ms=18)])
        result=summary.summarize(data)
        self.assertEqual(result['maximum_correlated_hid_to_stage_ms']['annotated_boundary'],16)
        self.assertFalse(result['recipient_receipt_verified'])

    def test_state_only_boundary_is_not_application_input(self):
        data=dict(schema=1,trigger=1,frames=[frame(5,1,origin=3,consumed=True)])
        result=summary.summarize(data)
        counts=result['observed_keydown_counts']['annotated_boundary']
        self.assertEqual(counts['state_only_downs'],1)
        self.assertNotIn('ordinary_or_external_downs',counts)

class AXSemanticTests(unittest.TestCase):
    def evidence(self):
        return dict(valueClass=2,placeholder=1,label=4,characterCount=2,representation=1,route=2,owner=1,window=2,fieldRelation=1,windowRelation=1,identityEpoch=1)
    def test_descriptions_preserve_uncertainty(self):
        result=summary.describe_ax(self.evidence())
        self.assertEqual(result['value_class'],'newline_only')
        self.assertEqual(result['placeholder'],'unavailable')
        self.assertEqual(result['label'],'trimmed_match_hint')
        self.assertEqual(result['document_truth'],'unverified_AX_provider_only')
    def test_unknown_is_not_false(self):
        value=self.evidence();value.update(placeholder=0,label=0,characterCount=0,representation=0,window=0,windowRelation=0)
        self.assertEqual(summary.describe_ax(value)['placeholder'],'unmeasured')
    def test_strict_scalar_fields(self):
        for key,bad in [('valueClass',6),('placeholder',True),('owner',0),('windowRelation',3),('text','private'),('route',None)]:
            value=self.evidence();value[key]=bad
            with self.assertRaises(ValueError):summary.ax_evidence(value)

class ControlSummaryTests(unittest.TestCase):
    def evidence(self):
        numbers=['role','eventType','runtime','incomingFlags','filterFlags','filterBefore','filterAfter','filterEdge','filterReason','externalDevice','externalHandling','externalRole','hidAcceptance','querySite','queryStatus','currentClass','targetClass','availableCount','koreanCount','englishCount','queryMicros']
        value=dict.fromkeys(numbers,0);value.update(route=1,filterMeasured=False,filterAccepted=False,filterConsumed=False,queryClipped=False)
        return value
    def test_control_privacy_and_unmeasured(self):
        value=self.evidence();self.assertEqual(summary.control_evidence(value)['queryStatus'],0)
        for key,bad in [('text','private'),('rawFlags',1),('role',True),('hidAcceptance',11),('querySite',1),('filterBefore',1)]:
            with self.assertRaises(ValueError):summary.control_evidence(dict(value,**{key:bad}))
    def test_control_summary(self):
        v=self.evidence();v.update(role=1,eventType=1,route=14,querySite=1,queryStatus=1)
        row=dict(frame(2,11,category=14),sequence=1,edge=1,controlEvidence=v,observationTiming=dict(queueMicros=51000,lockWaitMicros=0,contended=False,clipped=False))
        result=summary.summarize(dict(schema=1,trigger=1,frames=[row]))
        self.assertEqual(result['control_decisions'][0]['query_status_name'],'current_unavailable')
        self.assertEqual(result['control_decisions'][0]['route_name'],'filter_consumed')

class ManualEditBoundarySummaryTests(unittest.TestCase):
    def test_manual_edit_phases(self):
        rows=[dict(frame(8,7,category=k),count=0) for k in [29,30,31]]
        result=summary.summarize(dict(schema=1,trigger=1,frames=rows))
        self.assertEqual(result['manual_edit_boundary_counts'],dict(started=1,verified=1,unverified=1))

if __name__=='__main__':unittest.main()

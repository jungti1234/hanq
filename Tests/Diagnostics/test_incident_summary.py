import importlib.util
import pathlib
import unittest

spec=importlib.util.spec_from_file_location('summary',pathlib.Path(__file__).resolve().parents[2]/'scripts/summarize-input-incident.py')
summary=importlib.util.module_from_spec(spec);spec.loader.exec_module(summary)

def frame(lane,kind,event=0,category=0,ms=0,origin=1,consumed=False):
    return dict(lane=lane,kind=kind,event=event,category=category,milliseconds=ms,durationMicros=0,edge=1,inputOrigin=origin,consumed=consumed)

class IncidentSummaryTests(unittest.TestCase):
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

if __name__=='__main__':unittest.main()

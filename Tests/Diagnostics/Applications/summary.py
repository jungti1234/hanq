import copy, importlib.util, json, pathlib, sys
spec=importlib.util.spec_from_file_location('summary',pathlib.Path(__file__).resolve().parents[3]/'scripts/summarize-input-incident.py')
summary=importlib.util.module_from_spec(spec);spec.loader.exec_module(summary)
original=json.loads(pathlib.Path(sys.argv[1]).read_text());result=summary.summarize(original)
assert len(result['application_info']['records'])==2
assert any(row['target']!=row['owner'] for row in result['application_observations'] if row['kind']=='read')
assert any(row['kind']=='shape' for row in result['application_observations'])
checks=3
for mutate in [
    lambda d:d['applicationInfo'].update(schema=True),
    lambda d:d['applicationInfo']['records'][0].update(pid=0),
    lambda d:d['applicationInfo']['records'][0].update(name='a'*1025),
    lambda d:d['applicationInfo']['records'][0].update(name='secret\ntext'),
    lambda d:d['applicationInfo']['records'][0].update(documentPath='/excluded'),
    lambda d:d['applicationInfo'].update(unavailableReferences=[9,9]),
    lambda d:d['applicationInfo'].update(unavailableReferences=[d['applicationInfo']['records'][0]['id']]),
    lambda d:next(f for f in d['frames'] if 'applications' in f)['applications'].update(owner=999),
    lambda d:next(f for f in d['frames'] if 'applications' in f)['applications'].update(target=True),
]:
    value=copy.deepcopy(original);mutate(value)
    try:summary.summarize(value)
    except ValueError:checks+=1
    else:raise AssertionError('malformed identity accepted')
legacy=copy.deepcopy(original);legacy.pop('applicationInfo')
for frame in legacy['frames']:
    frame.pop('applications',None)
    frame.get('shapeEvidence',{}).pop('applications',None)
for baseline in legacy.get('shapeBaselines',[]):
    for point in [baseline.get('current'),baseline.get('previous')]:
        if point:point['evidence'].pop('applications',None)
assert summary.summarize(legacy)['application_info'] is None;checks+=1
pathlib.Path(sys.argv[2]).write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
print(f'PASS application summary {checks} checks')

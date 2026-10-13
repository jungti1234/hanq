import pathlib
import runpy

here = pathlib.Path(__file__).resolve()
source = here.with_name('retry.py')
if not source.exists():
    source = here.parent.parent / 'Live/retry.py'
owned = runpy.run_path(str(source))['owned_request']
root = pathlib.Path('/private/tmp/hanq-source-live.unit')
request = {'nonce': 'a' * 36, 'pid': 12, 'generation': 2}
progress = {'pid': 12, 'generation': 2, 'active': True,
            'firstResponderIsField': True, 'observedAt': 10.0}
identity = (str(root / 'SourceInteractionFixture.app/Contents/MacOS/SourceInteractionFixture'), 'start')
assert owned(root, request, progress, identity, 10.2)
for key, value in [('pid', 13), ('generation', 3), ('nonce', 'bad')]:
    bad = dict(request); bad[key] = value
    assert not owned(root, bad, progress, identity, 10.2)
for key, value in [('active', False), ('firstResponderIsField', False), ('observedAt', 1.0)]:
    bad = dict(progress); bad[key] = value
    assert not owned(root, request, bad, identity, 10.2)
assert not owned(root, request, progress, ('/some/other/app', 'start'), 10.2)
assert not owned(root, request, progress, None, 10.2)
print('PASS: 9 retry ownership, generation, nonce, focus, age and executable guards; no app actions')

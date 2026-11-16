# Settled prefix timing fixture

Run through `bash scripts/test-onset-recovery.sh`. The timing target requires
`-D PREFIX_TIMING_TEST`; compiling it without that flag fails explicitly.
The normal application build does not contain the injected platform providers.

The fixture uses the product engine, proof acquisition, complete key history,
plan, atomic gate claim, prefix coordinator, acknowledgment and input drain.
It substitutes OS-facing snapshots, menu availability, target/secure state and
native range requests. It never starts a global event tap or posts OS input.
This is an in-memory editor test, not an IME or real-application test.

The first key is the timing origin. The first pair appears at195ms, beyond the
unchanged150ms fast proof deadline. Original down/up times through1300ms are
preserved. The added Space down/publication/up is1370/1380/1400ms. Literal
editor publications are independent of the product's composition implementation.
Each non-expiry case also checks that the schedule is not silently loosened.

The28 cases cover:

- Prefix correction only after the actual Space is visible and all keys are up;
  a marked-range hint or idle alone must leave all original text/input untouched.
- Nonempty pre-key representation and empty-field baseline proofs; exact body,
  field, source, caret, key revision and the original2s history boundary.
- One native first-pair request; unchanged suffix; one restored caret request;
  asynchronous/uncertain responses;25ms stability before releasing held input.
- Original following keys delivered once in order, or retained on changed body,
  caret, source, front target or secure state and on an unapplied selection.
- Existing Space recovery when the prefix candidate is OFF or unavailable.
  Immediate and delayed native completion must deliver the original Space up
  exactly once, whether it naturally passes or is retained and drained.

The fixture does not directly install a proof/ticket, invoke a preclaimed edit,
relax a production condition, or model native Undo/Redo. Those commands require
separate real-editor validation. Fixed failure expectations and independent
mutation checks should accompany changes to this fixture.

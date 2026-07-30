# ZCR19 — Pre-gate corrections for PR #19

You are fixing **lucaspprates/Zoe-Coder-Router PR #19** in the existing isolated worktree:

```text
/home/ubuntu/worktrees/zoe-coder-router-18-factory-scheduler
```

## Immutable execution context

- Branch: `type/18-factory-scheduler-maintenance`
- Starting SHA: `d80ed678333dc70d1b92479a821bf2d1467c4424`
- PR: `https://github.com/lucaspprates/Zoe-Coder-Router/pull/19`
- Base branch: `fix/16-opencode-result-provenance`
- Production timer must remain `inactive`.
- Do not modify `/etc/zoe-coder-router`, `/usr/local/lib/zoe-coder-router`, `/var/lib/zoe-coder-router`, systemd units, runtime database, credentials, secrets, or production profiles.
- Do not merge, deploy, restart the timer, mark the PR ready, or push until every local gate passes.
- Work only inside the existing worktree.
- Use `/tmp/zcr18-builder-venv/bin/python` for Python and pytest.

Before editing, fail closed unless all are true:

```bash
systemctl is-active zoe-coder-reconcile.timer || true
# must be: inactive

git branch --show-current
# must be: type/18-factory-scheduler-maintenance

git rev-parse HEAD
# must be: d80ed678333dc70d1b92479a821bf2d1467c4424

git status --porcelain=v1
# must be empty
```

## Why the current SHA is CHANGES_REQUIRED

The current implementation makes wake execution asynchronous, but jobs submitted by Hermes can become ordinary `queued` jobs before `GLOBAL_CAPACITY_PLAN` is validated. The reconciler can therefore dispatch unvalidated work. If validation fails, those jobs remain live and a retry can duplicate work.

Additional gaps:

1. Capacity-plan validation checks IDs/counts but does not fully prove authorized project, safe status, capacity class, independent verifier identity, exact SHA, clean worktree, or no-fallback state.
2. All `read_only` jobs are effectively treated as gate capacity, even when the task is not gate/QA/release validation.
3. Native `requeue` recalculates the prompt hash without proving the original durable prompt was not altered, and its lane check/CAS mutation are not serialized in one write transaction.
4. Wake timeout requests `systemctl stop --no-block`, but has no deterministic escalation and lease release when the unit remains active.
5. Symlink rejection occurs after path resolution and therefore does not reliably reject a symlink input. Durable rename also lacks parent-directory fsync.

## Required correction contract

### A. Admission barrier tied to a durable plan ID

Implement a unique `plan_id` for each wake lease.

Jobs submitted while that wake is active must:

- persist `admission_plan_id` and `admission_source_job_id`;
- enter `awaiting_capacity_plan`, never `queued`;
- count against reserved capacity while quarantined;
- never be dispatched by `reconcile` before validation.

The wake process must pass the plan context to child `zoe-coder submit` calls through explicit environment variables or another durable, testable mechanism. Reject missing, mismatched, stale, or orphaned plan context.

On a valid plan:

- validate all quarantined jobs associated with exactly that `plan_id`;
- atomically release only the declared jobs from `awaiting_capacity_plan` to `queued`;
- emit durable release events.

On malformed, rejected, orphaned, timed-out, or nonzero-exit wake:

- deterministically compensate every quarantined job for that `plan_id`;
- move them to a terminal, non-executable blocked state;
- do not set `wake_pending` on compensated child jobs;
- emit durable compensation events with the reason;
- ensure a retry cannot reuse or dispatch those children.

The terminal marker must include the exact `plan_id`:

```text
GLOBAL_CAPACITY_PLAN {"plan_id":"<id>","writer_job_ids":[],"gate_job_ids":[],"writer_reasons":{},"gate_reasons":{},"free_slots":0}
```

### B. Strict capacity classes

Use explicit capacity classes:

- `writer`: `mode=write`;
- `gate`: only independent `read_only` tasks such as `gate`, `qa`, `release_validation`, or an explicitly documented gate-prefixed task;
- other read-only work must not silently consume a reserved gate slot.

A non-gate read-only job must either use a separately defined policy or fail closed as unclassified. Do not allow ordinary analysis/control-plane work to masquerade as one of the two reserved gates.

The planner must enforce:

```text
total = 6
writers <= 4
gates <= 2
writers + gates + other executable work <= 6
```

Quarantined admissions count toward the corresponding reservation.

### C. Exact-SHA independent gate contract

For independent gates on `factory-console` and `zoe-coder-router`:

- require an explicit 40-character `expected_head_sha` at admission;
- require a clean Git worktree at that SHA;
- require a distinct coder profile with `role="independent_gate"` and `mode="read_only"`;
- require a unitary route and `no_fallback`;
- persist the expected SHA and capacity class;
- repeat the SHA/cleanliness/identity/no-fallback checks immediately before execution, not only at submission;
- reject a dirty worktree, moved HEAD, writer identity, fallback chain, missing SHA, or unauthorized project.

Do not use configured model preference as proof of effective runtime model. Preserve the provenance contract from PR #17.

### D. Serializable native requeue

Strengthen `requeue` so that:

- it verifies the stored durable prompt still hashes to the stored `prompt_sha256` when reusing it;
- an altered prompt requires an explicit new prompt import and cannot silently replace historical evidence;
- DB backup is created before mutation;
- after the backup, acquire a SQLite write lock (`BEGIN IMMEDIATE` or equivalent);
- reread and fingerprint the original status, execution ID, updated timestamp, prompt identity, PID identity, worktree, and branch;
- perform live-process, lane-conflict, branch/worktree, prompt, and exact-SHA gate checks under the serialized mutation window;
- update with a strong compare-and-set predicate;
- reset only fields required for a new attempt;
- clear any previous admission-plan correlation;
- emit an audited event containing the precondition fingerprint and backup path.

Continue refusing succeeded jobs as new material missions.

### E. Bounded wake termination

Add a two-stage timeout lifecycle:

1. request `systemctl stop --no-block` once and persist `stop_requested_at`;
2. after a configured stop grace, escalate deterministically (`systemctl kill` or equivalent), compensate quarantined jobs, mark the source wake failed/timeout, release the global lease, and schedule a retry only when attempts remain.

The same stale lease must not emit unlimited stop requests forever.

### F. Durable prompt hardening

- Check the original path with `lstat` before resolving it.
- Reject symlink inputs explicitly.
- Import through an exclusive temporary file in the durable prompt root.
- fsync file contents.
- chmod before publication.
- atomically rename.
- fsync the parent directory after rename.
- verify the final SHA.
- reject target symlink/collision.

## Required tests

Add deterministic tests for at least:

1. Wake-created jobs remain `awaiting_capacity_plan` and are not dispatched.
2. Valid plan with matching `plan_id` releases exactly the declared jobs.
3. Invalid/malformed/mismatched plan compensates all quarantined jobs.
4. Retry cannot dispatch or reuse compensated children.
5. Unauthorized project is rejected even when its job ID is declared.
6. Missing or mismatched `plan_id` is rejected.
7. Duplicate IDs across writer/gate lists are rejected.
8. Non-gate read-only work cannot consume reserved gate capacity.
9. Gate admission rejects missing SHA, moved HEAD, dirty worktree, writer identity, non-unitary route, and fallback-enabled admission.
10. Exact-SHA gate checks run again immediately before execution.
11. Requeue rejects an altered durable prompt.
12. Requeue CAS rejects a state change after backup/before mutation.
13. Requeue lane check is protected by the serialized write transaction.
14. Prompt symlink is rejected.
15. Wake stop escalation releases the lease and compensates children.
16. Existing provenance tests remain green.
17. The full original test suite remains green.

## Validation gates

Run all of these using the existing temporary venv:

```bash
/tmp/zcr18-builder-venv/bin/python -m compileall -q src scripts tests
/tmp/zcr18-builder-venv/bin/python -m pytest -q
git diff --check
```

Also run focused tests for the scheduler maintenance and terminal provenance modules.

Inspect the final diff for secrets and unexpected paths. Allowed scope should remain narrowly limited to router source, scheduler tests, provenance-test compatibility if necessary, sanitized example configuration, generated config-shape fixture, and documentation.

## Commit and publication

Only after all gates pass:

```bash
git add <explicit allowed files>
git diff --cached --check
git commit -m "fix(router): close scheduler pre-gate gaps"
```

Do **not** push automatically. Return only:

```text
ZCR19_PRE_GATE_CORRECTIONS_COMPLETE
starting_sha=d80ed678333dc70d1b92479a821bf2d1467c4424
new_sha=<sha>
tests=<passed count>
focused_tests=<results>
diff_stat=<summary>
timer=inactive
push_required=true
```

If any gate fails, do not commit. Return the first reproducible material blocker with file/function/test evidence and leave the timer inactive.

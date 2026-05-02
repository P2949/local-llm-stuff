# stutter project review addendum

Use this addendum whenever reviewing P2949/stutter. Treat it as systems-code review, not normal app review.

## Non-negotiable invariants

### eBPF / userspace ABI
- Every `#[repr(C)]` event struct change must be reflected in userspace parsing and compile-time size/layout expectations.
- Map names in the loader must match map names in `stutter-ebpf` exactly.
- eBPF map capacity and userspace guard constants must agree or fail safely.
- Tracepoint offset validation must happen before relying on offsets.
- Ring-buffer reads must not assume alignment unless proven.

### Scheduler accounting
- Every pending-wakeup increment needs a matching decrement on switch, migration, duplicate wakeup, and task exit.
- Failed map inserts or RingBuf reserves must update drop counters or fail clearly.
- Target filtering must remain per-TID; process-only filtering is not enough for Proton/Wine games.

### Process/cgroup tracking
- `/proc` races must be handled without panics.
- Process roots must expand into `/proc/<pid>/task/<tid>`.
- TID reuse must not merge unrelated logical tasks.
- Include/exclude filters and `--keep-missing-pid` must behave exactly as documented.
- Cgroup prepopulation must apply filters before enforcing task caps.

### Recording/reporting
- Large artifacts must be bounded or streamed.
- JSON schema changes must be explicit and documented.
- Optional artifacts must be handled as optional.
- `max` and threshold counters must remain exact even when percentiles are approximate.
- Reports must not silently overwrite duplicate worker-thread identities.

### Affinity/profile/tune
- Affinity restore records must include enough identity to avoid restoring the wrong task.
- Dead TIDs and identity mismatches must be skipped safely.
- `apply-profile --watch` must not poison restore state when threads churn.
- `tune` must never score empty data as a valid candidate.
- Warmup must be excluded from scoring.
- Candidate comparability must be checked before declaring a winner.

## Required reviewer behavior
- Reject broad rewrites that are not demanded by accepted items.
- Request tests for every changed invariant above.
- Treat formatter/clippy/test output as authoritative only when produced by the harness.
- Treat APPROVE as ready for human inspection, not merge permission.

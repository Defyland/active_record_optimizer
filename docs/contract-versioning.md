# Active Record Optimizer Contract Versioning Policy

This document defines how machine-readable contracts evolve in `active_record_optimizer`.

Current contracts:

- Report JSON: [`json-report-schema-v1.json`](json-report-schema-v1.json)
- Runtime query snapshot: [`runtime-query-snapshot-schema-v2.json`](runtime-query-snapshot-schema-v2.json)

Retained compatibility artifact:

- Runtime query snapshot v1: [`runtime-query-snapshot-schema-v1.json`](runtime-query-snapshot-schema-v1.json)

## Goals

- Keep CI and internal tooling predictable.
- Make breaking contract changes explicit.
- Allow implementation improvements without accidental schema drift.
- Preserve a narrow, evidence-first product surface.

## Versioning Rules

`schema_version` is the compatibility boundary for a published JSON contract.

Keep the same `schema_version` only when the emitted payload remains valid against the published schema for that version and existing field meanings do not change.

Create a new schema version when any of the following happens:

- a field is added, removed, renamed, or moved
- a field type changes
- nullability changes
- an existing field gains materially different semantics
- a contract becomes stricter in a way that can reject previously valid payloads
- compatibility support for an older accepted input shape is removed

Because the published schemas are intentionally strict, even "optional" new top-level fields are treated as breaking unless the current schema already allows them.

## Allowed Same-Version Evolution

The following may evolve without changing `schema_version` as long as they stay valid under the current schema:

- bug fixes in how evidence is gathered
- ordering changes where ordering is not part of the documented contract
- new finding `code` values in the final report
- new `details` keys inside findings
- clearer human-readable `evidence`, `problem`, or `recommendation` text
- planner-derived values that change because the database changed

## Emission Policy

- The gem emits exactly one current schema version for each contract.
- The gem does not attempt down-conversion to older versions.
- Every emitted version must have a corresponding schema file in `docs/`.

## Input Compatibility Policy

The runtime query loader has one compatibility exception:

- legacy unversioned runtime snapshots are accepted as migration input
- versioned runtime snapshots must declare a supported `schema_version`

Legacy unversioned support is input-only compatibility. The gem never emits new unversioned snapshots again.

Removing legacy unversioned support requires:

1. a new documented schema version or explicit deprecation note in this file
2. release notes or pull request context describing the removal
3. tests proving the new acceptance/rejection behavior

## Upgrade Procedure

When introducing schema version `N+1`:

1. Add a new schema file under `docs/`.
2. Update the emitting code constant.
3. Keep the old loader path only if intentional compatibility is still supported.
4. Add or update tests that pin the emitted version and acceptance behavior.
5. Update `README.md`.
6. Record the rationale and trade-offs in release notes or pull request context.

Published schemas are not documentation-only artifacts. The test suite should validate real emitted payloads against them.

## Failure Policy

- Unsupported versioned runtime snapshots must fail fast with a clear error.
- Missing configured runtime snapshot files must fail fast with a clear error.
- Invalid JSON must fail fast with a clear error.
- Silent fallback is not allowed once a runtime artifact path was explicitly configured.

# Technical Decisions

## 2026-06-29 - Keep The Product Evidence-First Instead Of Style-First

Context: Rails codebases already have style and smell tools. The project exists to catch Active Record and database risks that can be supported by model, schema, migration, source, runtime, or planner evidence.

Options considered:

- Build a broad Rails code-smell linter.
- Build an auto-index recommender.
- Build a narrow evidence-backed optimizer/auditor.

Choice: Build a narrow evidence-backed optimizer/auditor.

Pros:

- Findings are easier to trust in CI.
- Recommendations can point to concrete model/table/column/source evidence.
- The gem can stay useful without becoming subjective style enforcement.
- False positives are constrained by requiring a clear evidence source.

Cons:

- Some real performance problems remain out of scope.
- Complex dynamic Rails code is intentionally not inferred.
- Users may still need human judgment before creating indexes or constraints.

Consequences:

- Every new rule should name the evidence source it trusts.
- Rules should prefer omission over low-confidence speculation.
- README examples and JSON output should keep evidence visible.

Verification evidence:

- Rule grouping in `lib/active_record_optimizer/rules.rb`.
- Finding output examples in `README.md`.
- Tests under `test/*_rules_test.rb`.

## 2026-06-29 - Use A Single Runner Context For Scanners And Rules

Context: The gem needs to combine schema, model, source, migration, runtime, and optional planner evidence without coupling every rule to every scanner.

Options considered:

- Let every rule instantiate its own scanners.
- Build a shared mutable registry of evidence.
- Build a single immutable runner context and pass it to rules.

Choice: Build a single runner context in `ActiveRecordOptimizer::Runner`.

Pros:

- Scanner orchestration is visible in one place.
- Rules stay read-only and easier to test.
- Shared canonicalization, such as table-name resolution, happens once.
- Future evidence sources can be added without changing every rule constructor.

Cons:

- The runner becomes the central coordination object.
- Very large apps may pay scanner cost even for rules whose evidence is not needed.

Consequences:

- The runner should remain orchestration-only.
- Expensive optional evidence, such as runtime `EXPLAIN`, must stay opt-in.
- Rule classes should not mutate context.

Verification evidence:

- `lib/active_record_optimizer/runner.rb`.
- `test/runner_test.rb`.

## 2026-06-29 - Make Runtime Query Evidence Explicit And Artifact-Based

Context: Static analysis can miss hot paths, but always-on query capture would create privacy, performance, and operational risk. Runtime evidence also needs a durable artifact that can be inspected and validated.

Options considered:

- Always collect runtime SQL during command execution.
- Require users to paste query logs manually.
- Capture runtime queries only inside an explicit block and load a versioned snapshot later.

Choice: Use explicit runtime snapshots captured through `ActiveRecordOptimizer.capture_runtime_queries`.

Pros:

- Runtime evidence is opt-in.
- Snapshots can be stored, reviewed, and schema-validated.
- Plain snapshots avoid literalized bind values by default.
- CI can replay the same runtime evidence without needing a live workload.

Cons:

- Users must create representative workloads themselves.
- Snapshot files become artifacts that teams must handle carefully.
- Static-only runs remain incomplete for some performance questions.

Consequences:

- Missing or malformed configured runtime snapshots fail fast.
- Snapshot schema versions are part of the public contract.
- Literalized snapshots are documented as sensitive.

Verification evidence:

- `lib/active_record_optimizer/query_collector.rb`.
- `lib/active_record_optimizer/runtime_query_loader.rb`.
- `docs/runtime-query-snapshot-schema-v2.json`.
- `test/query_collector_test.rb`.
- `test/runtime_query_loader_test.rb`.

## 2026-06-29 - Keep PostgreSQL Planner Enrichment Opt-In

Context: PostgreSQL `EXPLAIN` can strengthen runtime findings, but planner output depends on live schema, data distribution, adapter behavior, and whether SQL contains literal values that can be explained.

Options considered:

- Run `EXPLAIN` for every captured query by default.
- Never use planner evidence.
- Run planner enrichment only when `--explain-runtime` is requested and the snapshot contains explainable SQL.

Choice: Make planner enrichment explicit through `--explain-runtime`.

Pros:

- Users control when live database planner calls happen.
- Findings can distinguish runtime-pattern evidence from planner-confirmed evidence.
- Non-explainable snapshots fail clearly instead of silently downgrading.
- Sensitive literalized SQL remains a deliberate choice.

Cons:

- The strongest evidence requires an extra capture mode.
- Only PostgreSQL has adapter-specific planner support today.

Consequences:

- `literalize_binds: true` is required for explainable runtime snapshots.
- `--explain-runtime` fails when configured without a usable runtime report.
- Planner row thresholds remain configuration, not a hard-coded universal truth.

Verification evidence:

- `lib/active_record_optimizer/query_plan_analyzer.rb`.
- `lib/active_record_optimizer/runner.rb`.
- `test/postgresql_integration_test.rb`.

## 2026-06-29 - Treat JSON Schemas As Product Contracts

Context: CI, scripts, and future cheap-model tooling need stable machine-readable output. If JSON shape drifts accidentally, downstream automation becomes unreliable.

Options considered:

- Document JSON output only in README.
- Emit best-effort JSON with no formal schema.
- Publish strict JSON schemas and version them explicitly.

Choice: Publish strict schemas and a contract-versioning policy.

Pros:

- Downstream tools can validate output.
- Breaking changes require explicit schema-version changes.
- Package verification can ensure contract files ship with the gem.
- Future model-driven automation gets a stable interface.

Cons:

- Small output changes require schema review.
- Optional top-level fields can become breaking unless explicitly modeled.

Consequences:

- New schema versions need docs, tests, and README updates.
- Contract files are packaged artifacts, not repo-only notes.

Verification evidence:

- `docs/json-report-schema-v1.json`.
- `docs/runtime-query-snapshot-schema-v2.json`.
- `docs/contract-versioning.md`.
- `test/report_test.rb`.
- `test/packaging_test.rb`.

## 2026-06-29 - Ship Review Docs Inside The Built Gem

Context: the project is not only a runtime tool; it is also a study artifact
for technical review. If the architecture, decisions, and engineering case
study live only in the checkout, the packaged release becomes less truthful
than the repository.

Options considered:

- Keep study docs only in the Git checkout.
- Publish study docs in the README only.
- Ship the study docs inside the built gem and verify them during package audit.

Choice: ship `docs/architecture.md`, `docs/decisions.md`, and
`docs/engineering-case-study.md` inside the built gem and treat them as public
docs in package verification.

Pros:

- Reviewers can inspect the product rationale from the packaged artifact, not
  only the repository tree.
- The release surface stays aligned with the educational/documentation promise.
- Package verification catches accidental drift where docs stop shipping.

Cons:

- Public docs become a maintained release surface.
- Packaging changes now need to consider documentation presence explicitly.

Consequences:

- The gemspec must package the study docs.
- Package audit must fail when those docs disappear or contain local-only links.
- README review instructions should point evaluators to the packaged-doc
  expectation directly.

Verification evidence:

- `active_record_optimizer.gemspec`.
- `lib/active_record_optimizer/package_audit.rb`.
- `test/packaging_test.rb`.

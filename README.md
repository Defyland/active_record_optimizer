# Active Record Optimizer

`active_record_optimizer` is a Rails gem that finds high-evidence Active Record and database risks before they become production performance or integrity incidents.

The tool starts static and schema-aware: it inspects loaded models, Active Record reflections, the database schema exposed by the connection, app source patterns, and migrations. Runtime query evidence is available as an opt-in captured snapshot, and PostgreSQL `EXPLAIN` evidence can be layered on top when you explicitly capture explainable SQL.

## Why This Exists

Rails makes database access productive, but it also makes expensive or unsafe query shapes easy to hide behind associations, scopes, callbacks, and service objects. Most teams discover missing foreign keys, missing child indexes, broad `dependent: :destroy`, and hot unindexed filters after production data grows.

This gem is intentionally narrower than a style linter: it looks for issues where it can show concrete model, schema, source, migration, runtime, or planner evidence. The goal is to give Rails teams a CI-friendly audit that points to database risks worth investigating, not to enforce subjective code style.

The engineering case study for the product and release shape lives in
[`docs/engineering-case-study.md`](docs/engineering-case-study.md).

## Real Use Cases

- Run before a Rails app grows past toy data volume to catch integrity and index gaps early.
- Add to CI with `--fail-on high` to prevent new high-evidence database risks.
- Capture a small runtime query snapshot from a staging or reproducible workload and combine it with static analysis.
- Use PostgreSQL `EXPLAIN` enrichment when planner evidence is needed before prioritizing an index change.
- Review legacy Rails apps where associations and migrations no longer tell the same story.

## Install

```ruby
gem "active_record_optimizer"
```

## Usage

```sh
bin/rails active_record:optimize
bin/rails active_record:optimize --fail-on high
bin/rails active_record:optimize --format json
bin/rails active_record:optimize --config config/active_record_optimizer.yml
bin/rails active_record:optimize --runtime-report tmp/active_record_optimizer.runtime.json --fail-on medium
bin/rails active_record:optimize --runtime-report tmp/active_record_optimizer.runtime.json --explain-runtime
```

The gem also installs a Rake task with the same name for compatibility with task-oriented workflows.

## Runtime Query Capture

Static evidence remains the default path, but you can feed runtime query patterns into the report with an explicit snapshot:

```ruby
ActiveRecordOptimizer.capture_runtime_queries(path: Rails.root.join("tmp/active_record_optimizer.runtime.json")) do
  Payment.where(status: 1).load
  Payment.where(status: 1).load
end
```

That default snapshot keeps the original SQL shape. If you also want PostgreSQL planner evidence later, opt in when capturing:

```ruby
ActiveRecordOptimizer.capture_runtime_queries(
  path: Rails.root.join("tmp/active_record_optimizer.runtime.json"),
  literalize_binds: true
) do
  Payment.where(status: 1).load
end
```

Then pass the artifact back into the command:

```sh
bin/rails active_record:optimize --runtime-report tmp/active_record_optimizer.runtime.json
bin/rails active_record:optimize --runtime-report tmp/active_record_optimizer.runtime.json --explain-runtime
bundle exec rake active_record:optimize RUNTIME_REPORT=tmp/active_record_optimizer.runtime.json
bundle exec rake active_record:optimize RUNTIME_REPORT=tmp/active_record_optimizer.runtime.json EXPLAIN_RUNTIME=1
```

This phase is intentionally conservative:

- it only reports patterns the SQL parser can map back to concrete table/column evidence
- it is opt-in, not an always-on collector
- PostgreSQL `EXPLAIN (FORMAT JSON)` is opt-in and runs only when the runtime snapshot contains explainable SQL

Important:

- plain runtime snapshots keep the original SQL shape and avoid literalizing bind values by default
- `literalize_binds: true` produces explainable SQL and should be treated as sensitive output
- runtime snapshots now carry versioned `metadata`, including whether they contain literalized binds
- `--explain-runtime` uses the current connected database and current schema/data distribution, so it should be run close to the environment shape that produced the captured traffic
- only PostgreSQL has adapter-specific `EXPLAIN` support today
- `--explain-runtime` now fails clearly when the runtime snapshot does not contain explainable SQL; re-capture with `literalize_binds: true` for planner enrichment
- `planner_row_threshold` controls when planner-confirmed scan/sort evidence is strong enough to promote a runtime finding to `high`
- an explicit `runtime_query_report_path` now fails clearly when the file is missing, malformed, or uses an unsupported snapshot schema version

The formal current runtime snapshot contract lives at [`docs/runtime-query-snapshot-schema-v2.json`](docs/runtime-query-snapshot-schema-v2.json).
The loader still accepts versioned v1 snapshots for compatibility.
The contract evolution policy for both machine-readable artifacts lives at [`docs/contract-versioning.md`](docs/contract-versioning.md).
Those published contract artifacts ship inside the gem package as well as the repository.

## Configuration

Project configuration can live in:

- `.active_record_optimizer.yml`
- `config/active_record_optimizer.yml`

You can also pass an explicit file with `--config`.

Configuration is strict by design:

- unknown keys fail fast
- invalid value types fail fast
- numeric thresholds must be integers greater than or equal to `1`
- an explicit missing config path fails fast
- YAML files must contain a top-level mapping

Example:

```yaml
dependent_destroy_row_threshold: 10000
planner_row_threshold: 10000
where_occurrence_threshold: 3
output_format: json
runtime_query_report_path: tmp/active_record_optimizer.runtime.json
explain_runtime_queries: true
ignored_tables:
  - legacy_events
ignored_findings:
  - code: default_scope
    model: LegacyRecord
  - code: recurring_where_without_index
    table: audit_logs
```

## Verification

For a technical review, start here:

```sh
bundle exec rake verify
```

`verify` runs:

- tests
- a disposable Rails host-app integration smoke test for `bin/rails active_record:optimize`
- schema-validation tests for published JSON contracts
- RuboCop
- `bundler-audit`
- built-gem package verification for public contract artifacts, public-doc hygiene, an isolated install/require smoke check, runtime snapshot capture rehearsal, schema validation of the emitted snapshot against the packaged contract file, and a disposable Rails host-app rehearsal that resolves the packaged gem through Bundler without falling back to the checkout

Additional PostgreSQL integration coverage is available with:

```sh
bundle exec rake verify_postgres
```

That PostgreSQL path now covers adapter-focused rule tests plus a disposable Rails host-app rehearsal that consumes the built gem package against a real PostgreSQL database, captures runtime SQL, and exercises `--explain-runtime`.

CI runs the default verification suite on Ruby `3.2`, `3.3`, and `3.4`, plus a dedicated PostgreSQL integration job on Ruby `3.4`.

## How To Evaluate This Repo

For a fast technical review:

```sh
bundle install
bundle exec rake verify
bundle exec rake verify_postgres
bundle exec rake build
ruby -e 'require "rubygems/package"; puts Gem::Package.new(Dir["pkg/active_record_optimizer-*.gem"].fetch(0)).contents.grep(%r{^(README|docs/)})'
```

Expected evidence:

- `verify` proves the default Ruby suite, RuboCop, `bundler-audit`, schema
  validation, built-gem package verification, and a disposable host-app smoke
  path for the packaged gem.
- `verify_postgres` proves the adapter-specific `--explain-runtime` path
  against a real PostgreSQL database.
- the built gem includes `README.md`,
  `docs/architecture.md`,
  `docs/contract-versioning.md`,
  `docs/decisions.md`,
  `docs/engineering-case-study.md`, and the published JSON schemas instead of
  leaving the review material only in the checkout.
- the packaged host-app smoke path captures a runtime snapshot and validates it
  against the packaged runtime-schema contract.

## Current Limits

- The gem reports evidence-backed risks; it does not decide whether every suggested index belongs in production.
- Static source analysis follows common, simple Active Record relation shapes. It intentionally avoids arbitrary Ruby execution and broad metaprogramming inference.
- Runtime capture is opt-in and writes query artifacts; snapshots with `literalize_binds: true` can contain sensitive values and should be handled like production data.
- PostgreSQL planner enrichment is adapter-specific today. Other databases still receive static, schema, model, migration, and runtime-pattern analysis without `EXPLAIN` promotion.

## Current Rules

- `belongs_to` column without an index.
- `belongs_to` column without a real database foreign key.
- Foreign key constraint without an index on the child column.
- Polymorphic association without a composite index.
- Risky `dependent: :destroy` on broad `has_many` relations when the child table has large-size evidence.
- `default_scope` usage.
- `has_many` missing `inverse_of` where autosave or dependent destroy makes identity consistency matter.
- Enum/status columns used in `where` without an index.
- JSONB columns queried without a matching index.
- Repeated `where` columns without an index.
- `order` columns without a compatible leading index or equality-filter composite index.
- Tables without primary keys or timestamp columns.
- Migrations that add reference-like columns without `foreign_key: true`.

## Output

Findings are grouped by severity and include the evidence, affected model/table/column, and an actionable recommendation.

```text
HIGH: Missing foreign key constraint
Model:
  Payment
Column:
  payments.user_id
Problem:
  Active Record association exists, but database integrity is not enforced.
Recommendation:
  add_foreign_key :payments, :users
Evidence:
  Payment belongs_to :user
```

JSON output is available for CI and machine consumers:

```json
{
  "metadata": {
    "schema_version": 1,
    "generator": {
      "name": "active_record_optimizer",
      "version": "0.1.0"
    }
  },
  "counts": {
    "high": 1
  },
  "findings": [
    {
      "severity": "high",
      "code": "missing_foreign_key_constraint",
      "title": "Missing foreign key constraint",
      "details": null
    },
    {
      "severity": "high",
      "code": "jsonb_query_without_index",
      "title": "JSONB query without matching index",
      "details": {
        "planner_confirmed": true,
        "planner_row_threshold": 10000,
        "plan_root_node_type": "Seq Scan",
        "plan_relation_node_type": "Seq Scan",
        "plan_relation_name": "payments",
        "plan_rows": 50000
      }
    }
  ]
}
```

`details` is intended for machine consumers. It carries structured planner and schema evidence when the finding has more than a plain text recommendation.

The formal JSON contract for this payload lives at [`docs/json-report-schema-v1.json`](docs/json-report-schema-v1.json).

## Design Constraint

This gem should not become a generic Rails style linter. A rule should fire only when the scanner can show concrete schema, model, source, or migration evidence.

## Evidence Model

- Schema and foreign key facts come from the live Active Record connection metadata.
- Query pattern evidence now comes from Ruby AST parsing with `Prism`, not line regexes.
- Static source scanning now follows simple relation flow through local variables, so `payments = Payment.where(...); payments.order(...)` and `payments.reorder(...)` still become concrete evidence.
- Static source scanning also propagates simple named-scope filter context from model AST, so `Payment.paid_only.order(...)` does not lose composite-index evidence just because the filter lives behind a scope boundary.
- Static source scanning also propagates simple `def self.foo` relation helpers from model AST, so common class-method query APIs keep their filter context during downstream index analysis.
- Static source scanning also supports simple `class << self` relation helpers on models, covering another common Rails class-method style without broadening into arbitrary metaprogramming.
- Static source scanning now accepts parameterized model relation helpers too, as long as the query shape is statically visible in the helper body and the evidence still stays concrete.
- Static source scanning now resolves simple delegated model relation helpers too, including helpers that call another statically visible helper defined later in the same model file.
- Runtime query evidence can be loaded from an explicit capture artifact generated through `ActiveSupport::Notifications`.
- Runtime query parsing now resolves aliased `FROM`/`JOIN` table references back to the canonical table identity before emitting evidence.
- Runtime query parsing keeps `WHERE` support scoped to the ordered alias, so self-joins do not borrow composite-index evidence from a different table alias.
- Runtime query parsing now accepts schema-qualified table references such as `"analytics"."payments"` and preserves that qualified identity for downstream matching.
- Runner-side table identity resolution now canonicalizes unqualified runtime table names through the current PostgreSQL `search_path` when the app explicitly models a schema-qualified table.
- PostgreSQL runtime findings can be enriched with `EXPLAIN (FORMAT JSON)` planner evidence when `explain_runtime_queries` is enabled.
- PostgreSQL planner metadata can promote runtime query findings to `high` when the plan confirms large sequential scans or large explicit sorts.
- `ORDER BY` findings account for equality-filter composite indexes such as `(status, created_at)` so the rule does not accuse a query shape that the schema already supports.
- PostgreSQL table row estimates inform the `dependent: :destroy` risk rule so it only fires with large-table evidence.
- JSON findings expose structured `details` so CI and internal tooling do not need to parse the human-readable `evidence` string.
- JSON reports expose versioned `metadata` so CI and internal tooling can target a stable schema.
- Migration reference evidence now comes from Ruby AST parsing with `Prism`, which avoids comment and string false positives.
- PostgreSQL expression indexes for JSONB paths are covered by dedicated integration tests.

## License

This gem is published under the MIT License. See
[LICENSE.txt](LICENSE.txt).

That keeps the analyzer, packaged study docs, and verification notes reusable
for study and internal experimentation.

# Engineering Case Study

`active_record_optimizer` exists because Rails teams usually discover database
integrity and query-shape problems too late: after data volume grows, after a
legacy app loses migration discipline, or after a hot path turns into a paging
incident. The product choice here was to stay evidence-first instead of trying
to become a generic Rails style linter.

That decision drives almost every boundary in the repo. Rules are grouped by
the evidence source they trust, the runner owns orchestration, runtime query
capture is explicit and artifact-based, and PostgreSQL planner enrichment is
opt-in. The project would be easier to market with broader claims, but it would
also be harder to trust. The narrower surface is deliberate.

The strongest portfolio signal in this gem is not the number of rule ids. It is
that each major promise is tied to executable proof:

- JSON output has versioned schemas and contract tests.
- runtime query capture produces a durable artifact that is schema-validated;
- package verification exercises the built gem inside a disposable Rails host
  app instead of trusting checkout-only behavior;
- PostgreSQL integration coverage proves the explainable runtime path against a
  real adapter-specific database.

The release shape is also intentional. The gem now ships the architecture,
decision log, and this case study inside the packaged artifact, so the public
release does not hide the reasoning that justified the implementation. That
matters for two audiences: a reviewer evaluating engineering judgment, and a
future maintainer trying to understand why the project avoided style-linter
scope, silent config fallback, always-on query capture, or automatic index
generation.

The next maturity bar is still evidence quality, not feature sprawl. Useful
future work would look like stronger adapter-specific runtime coverage or
better real-world snapshot tooling. It would not look like widening the gem
into a generic Rails doctor, auto-remediation engine, or speculative rules
framework.

# ControlKit implementation guide

## Scope and checkpoints

Normally implement one milestone at a time. The owner approved milestones 10–12 together, with review
at their combined completion. Raise findings that change architectural assumptions before building
further on those assumptions.

The current scope is milestones 10–12: app and artifact lifecycle, production simulator commands,
doctor/setup/run orchestration, local acceptance, compatibility/burst/soak evidence, help/docs, and
an agent skill. Milestones 1–9 and the milestone-2 contracts are approved. Physical devices, remote
access, distribution packaging, CI, arbitrary scripting, and BFF/proxy orchestration remain out of
scope. Document measured evidence separately from planned guarantees.

## Engineering rules

Follow https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md:
safety, performance, then developer experience.

- Use simple control flow and minimal domain-specific abstractions.
- Bound owned queues, buffers, traversal, retries, subprocess output, and operation lifetimes.
- Do not use recursive traversal. State transitions must not suspend.
- Assert internal invariants. Handle invalid input and operating failures as errors.
- Never replay a mutation after uncertain completion.
- Make ownership, units, coordinate spaces, and failure semantics explicit.
- Keep functions at most 70 lines, lines at most 100 columns, and indentation at four spaces.
- Explain why in comments. Keep compiler warnings enabled and fix them.
- Use public XCTest APIs only. Do not parse debug descriptions as an element-tree API.
- Never change global Xcode selection. Honor `DEVELOPER_DIR`.
- Never log credentials or put runtime credentials into repository files.
- No CI or distribution setup. Provide reproducible local verification.
- All implemented commands must have help, including nested help and `--help`.

Swift adaptations are intentional: ARC/framework allocations cannot be eliminated, asynchronous
Apple APIs are unavoidable, and Swift naming conventions apply. Bound resources we control;
do not claim to bound XCTest's internal memory or execution. Swift Argument Parser is the sole
approved third-party implementation dependency. Assertions should encode real invariants, not quotas.

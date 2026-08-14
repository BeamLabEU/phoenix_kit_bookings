# PR #2 Phase 1 Review — phoenix_kit_bookings
**Title:** Adopt core's put_slug/3 for service slugs
**Author:** Max Don (mdon)
**Reviewed:** 2026-08-14
**Verdict:** APPROVE WITH NOTES

---

## Summary

Clean, minimal adoption of `PhoenixKit.Utils.Slug.put_slug/3`. Deletes 22 lines of local slugify logic and replaces it with a single pipeline call to core. The implementation is correct; the code is merge-ready modulo two self-identified gates (unreleased core, missing version bump) that the author explicitly flagged in the PR body.

The PR fixes two real bugs in the process:
- **Cyrillic/Greek names** produced `""` from the ASCII-only local slugifier, which then failed the schema's own `validate_format(:slug, ...)` — such services could not be created at all.
- **Name collisions** hit a raw unique-constraint error instead of getting a `-2`/`-3` suffix, because the old code never probed before writing.

---

## Findings

### Blockers

**B1 — Merge gate: `put_slug/3` not in any published phoenix_kit Hex release**

The current pin `~> 2.0` resolves to published 2.3.0, which does not include `put_slug/3`. Merging this branch against Hex-resolved core causes every `Service.changeset/2` call to raise `UndefinedFunctionError` at runtime — a full production breakage. The author explicitly documents this: *"Do not merge before core ships `put_slug/3`."*

Action needed: hold until phoenix_kit#711 is published (expected as 2.4.0 or similar), then update the mix.exs pin if needed (current `~> 2.0` will auto-resolve once the release lands, so a pin bump may not be required — confirm at merge time).

**B2 — No version bump, no CHANGELOG entry**

Author self-flagged: *"No CHANGELOG.md, no @version."* Consistent with project practice (BeamLabEU packages track CHANGELOG + @version bumps before publish). Must be added before merge/release.

---

### Non-blockers

**N1 — max_length: 160 alignment**

`Slug.put_slug(:name, max_length: 160)` correctly matches both the column width (`migrations/schema.ex:107`) and the existing `validate_length(:slug, max: 160)`. The old `String.slice(0, 160)` could overflow when the suffix was added post-slice — core handles this correctly by reserving space for the suffix before capping.

**N2 — Rename semantics preserved**

PR description confirms and a test pins: `put_slug/3` skips slug generation when a slug already exists on the struct (mirrors the old `get_field` check in `maybe_generate_slug/1`). No behavior regression on rename.

**N3 — mix.exs dependency pin unchanged**

Pin stays `~> 2.0` per PR description ("per the conformance test"). This is acceptable — the pin will admit core 2.4.x once it ships. No mis-pin, just a timing dependency.

---

### Nitpicks

**P1 — Verbose inline comment in changeset pipeline**

The 7-line comment above `|> Slug.put_slug(...)` is thorough but unusual length for production changeset code. The reasoning belongs in the PR body (already there) or commit message. Consider trimming to a single line or none — `put_slug` is self-describing once core is a known dependency.

---

## Stats

| | |
|---|---|
| **Changed files** | 2 |
| **Additions** | 82 |
| **Deletions** | 22 |
| **Tests** | 4 new tests in `test/phoenix_kit_bookings/service_slug_test.exs` |
| **Migrations** | None |
| **Version bump** | None (required before merge — see B2) |
| **Dependency changes** | None in mix.exs; pin `~> 2.0` unchanged |

### Test coverage

All four test cases are meaningful:
1. Cyrillic name → valid slug (new capability, was broken before)
2. Existing slug preserved on rename (regression guard)
3. Name collision → `-2` suffix instead of constraint error (new capability)
4. Long name + suffix stays inside 160-char cap (edge case correctness)

Author notes 3 of 4 tests fail against the old code (verified by stashing). Good.
Transliteration output deliberately not pinned — avoids version-dependent assertions.

---

## Decision

Hold for merge until:
1. phoenix_kit#711 is published to Hex (≈ 2.4.0)
2. Version bump + CHANGELOG added to this repo

Code quality: no issues. Once the gates clear, this is a straight merge.

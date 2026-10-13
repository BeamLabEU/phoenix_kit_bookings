# PR #9 review follow-up

Codex review, 2026-10-13. Claude's review is preserved unchanged.

| Finding | Resolution |
|---|---|
| Stale Edit assigns, noted by Claude | Reproduced with existing client-patch support; clear both assigns on every URL reload. |
| Host layout retains the link after socket clearing | Added a compatibility adapter that propagates change flags for flattened Edit keys. Rendered navigation regressions pass. |
| Flow reload abandons a hold and retains old subscriptions | Release both before loading the next service; verified against real holds and PubSub registrations. |
| Queued notifications/events crash a missing-service page | Match notifications to the loaded service and ignore booking events without a service. |
| Three baseline admin redirect assertion failures | Use the same path helpers as the production redirects. Full integration suite passes. |
| Core-floor compatibility | Retained the `module_assigns` API; inspected 2.38.0 sources and ran the public suite with its helper and wrapper loaded. |
| English-only Edit label | Deferred to the existing translation work; no catalogue added. |

See [CODEX_REVIEW.md](CODEX_REVIEW.md) for evidence, severity, and validation
scope. Changes remain local; version and changelog are unchanged.

# Coda development instructions

## Project character

- Coda is a focused, largely feature-complete hobby project: a native macOS 26 client for Navidrome and OpenSubsonic servers, built with SwiftUI/AppKit and embedded libmpv/CoreAudio.
- Preserve its artwork-led dark UI, original streams, visible queue, and native macOS behavior. Prefer SwiftUI and small native integrations over custom infrastructure.
- Keep solutions proportional to the app's size and expected maintenance. Favor clear ownership and a small central policy/helper when several views must make the same semantic decision.
- Do not broaden a focused fix into a redesign without evidence that the current structure causes recurring bugs, duplicated policy, unclear ownership, or meaningful testing difficulty.

## Git workflow

- Work on the current branch. Do not create or switch branches unless the user explicitly asks.
- After completing and verifying a normal requested code change, create a commit unless the user explicitly says not to commit it.
- When the user explicitly creates or requests a prototype or experimental branch, commit each stable, working iteration as a checkpoint so experiments are easy to compare and revert.
- Leave an iteration uncommitted when the user explicitly calls it an experiment or prototype and asks not to commit it.
- Do not commit broken, incomplete, or unverified states merely to create a checkpoint.
- Preserve unrelated user changes and never include them in a commit without explicit permission.
- Do not merge, push, publish, tag, release, rewrite history, or delete a branch unless the user explicitly asks.

## Privacy and repository hygiene

- Never commit credentials, private server URLs, personal library data, or reports derived from a user's Navidrome library.
- Keep generated audits, benchmarks, profiling output, and one-off analysis artifacts under `.build/` or a temporary directory unless the user explicitly requests a reviewed, repository-safe fixture.
- Before committing, inspect the staged filenames and diff. Treat unexpected CSV, JSON, log, database, Python cache, benchmark, and report files as suspicious until their purpose and data are verified.
- If sensitive or personal data is discovered in Git history, stop unrelated work, avoid printing the data, and discuss containment and history cleanup with the user.

## Review workflow

- Reviews are read-only by default. Do not implement findings, reorganize code, alter documentation, or create commits unless the user also asks for changes.
- Begin by checking repository status, recent relevant history, the affected code paths, existing tests, and related documentation. Review the current tree; use history to understand intent, not to revive discarded prototypes.
- Lead with findings ordered by practical severity. For each finding, cite the exact file and line, explain the concrete impact or failure mode, and distinguish observed evidence from inference.
- Separate confirmed defects, credible risks, architectural options, and optional cleanup. Do not present personal style preferences as correctness issues.
- If no actionable findings are found, say so and identify any important verification gaps or areas not exercised.

## Review priorities

### Architecture fitness

- Judge the architecture against Coda's actual size, feature set, and likely development pace rather than an idealized large application.
- Look for duplicated semantic policy across views and controllers, especially theme/accent resolution, playback state, queue behavior, navigation, window state, persistence, and error handling. Textually different code can still be harmful duplication when it represents the same product rule.
- Check that mutable state and side effects have clear owners and that view code is not independently reconstructing shared domain decisions.
- Prefer the smallest centralization that prevents divergence. Introduce protocols, layers, dependency injection, or new modules only when multiple consumers, substitution needs, or recurring defects justify them.
- When a broader redesign may be warranted, compare the current design, a minimal refactor, and the larger redesign. Explain migration cost, regression risk, and the concrete benefit before recommending it.

### Correctness and implementation cleanliness

- Pay particular attention to Swift concurrency and `MainActor` isolation, task cancellation, stale asynchronous results, playback and queue transitions, window/focus behavior, persistence, credential handling, and Navidrome failure paths.
- Check boundary conditions around empty libraries, missing or oddly proportioned artwork, multi-disc albums, large queues, disconnected servers, inactive windows, and rapid selection or playback changes.
- Flag hidden coupling, contradictory state, swallowed errors, unsafe assumptions, and cleanup that depends on a view disappearing at exactly the right time.

### Code quality

- Treat large files and long functions as review signals, not automatic defects. Flag them when mixed responsibilities, repeated policy, difficult navigation, or change amplification causes a real maintenance problem.
- Look for semantic duplication before superficial repetition. Repeated layout constants can be harmless; repeated business or presentation rules that drift across screens are not.
- Prefer direct code with descriptive names and local reasoning. Avoid abstractions that have one caller, merely rename platform APIs, or make debugging harder.
- Recommend focused regression checks when fixing a bug that could plausibly reappear elsewhere.

### Performance

- Base performance findings on a credible hot path, measurement, or clear complexity issue. Do not recommend speculative micro-optimization.
- Focus on artwork fetching, decoding and caching; blocking work on the main actor; SwiftUI invalidation scope; large library/list rendering; network fan-out; queue updates; and libmpv/CoreAudio transitions.
- Recommend profiling before a substantial performance refactor, and keep benchmark scripts and results outside tracked source unless they are intentionally productized and scrubbed of personal data.

### Documentation and build workflow

- Verify documentation against the scripts and current runtime behavior, especially prerequisites, bundled libmpv, signing, debug versus release credential storage, `.build/Coda.app`, and available self-tests.
- Update documentation in the same change when user-facing behavior, required setup, build commands, or verification commands change.
- Keep build instructions reproducible for a fresh checkout. Do not preserve obsolete commands merely because they once worked.

### Experiment residue

- Look for dead UI variants, abandoned feature switches, stale preview/debug controls, unused styles, obsolete compatibility paths, and abstractions left behind by prototypes.
- Distinguish intentional diagnostics and self-tests from experiment residue. Do not delete useful instrumentation solely because it is not part of the visible product.
- Do not restore discarded designs or prototype behavior based only on Git history.

### Security, packaging, and native behavior

- Check that logs, errors, diagnostics, and generated reports do not expose credentials, private server details, or library contents.
- Review changes to signing, entitlements, Keychain access, bundled libraries, and license attribution as release-sensitive even in this hobby project.
- Preserve native keyboard, focus, inactive-window, accessibility, and first-click behavior. Treat regressions in these areas as product defects rather than cosmetic differences.

## Verification

- Match verification effort to the risk and scope of the change, and report checks that were not run.
- For documentation-only changes, run `git diff --check` and verify referenced commands and paths. A full build is not required unless build scripts or generated bundle behavior changed.
- For normal code changes, use `scripts/build-app.sh` and run `.build/Coda.app/Contents/MacOS/Coda --self-test` unless the change clearly cannot affect compilation or behavior.
- Use `--mpv-local-transition-test` or `--mpv-stream-test` only when the affected playback path warrants it and the required local media, server, and credentials are available. Do not silently substitute live tests for deterministic checks.
- UI self-tests do not validate visual quality. For visual changes, also describe the states and window sizes that need human inspection.

## Scope discipline

- Do not impose enterprise process on this project by default: no mandatory coverage target, CI matrix, linter migration, module split, dependency-injection framework, snapshot suite, or benchmark gate without a concrete payoff.
- Prefer targeted regression tests, small shared resolvers, and short comments explaining non-obvious product constraints over broad cleanup campaigns.
- Recommend automation when it removes a repeated manual failure mode or protects a high-risk path, not merely because automation is possible.

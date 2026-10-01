# Overboard Excellence: Implementation and Validation

Implemented on `nicky/overboard-excellence`, without a Jira ticket, remote push,
or merge request. This is an independent implementation under Overboard's MIT
license: no Tinycast source or assets were imported.

## Architecture and behavior

- **Clipboard delivery:** ordered, materialized representations carry original
  pasteboard-item identities; each reconstructed item owns its provider. A paste
  session cancels delayed dispatch, checks generation/ownership, and restores
  only the clipboard it still owns. Pending eligible external capture is flushed
  before internal publication. Outcomes distinguish copied, dispatched, cancelled,
  and failed; dispatched never means the target consumed the paste.
- **Stack:** reserve before delivery; commit only on dispatch, otherwise roll back.
  Clipboard usage is updated after successful publication, not before it.
- **Rich content:** deduplication covers secondary representations. Text transforms
  remove HTML/RTF only from changed items; unrelated rich items retain their bytes.
- **Recovery:** database migration takes a coherent pre-migration SQLite backup
  under `MigrationBackups`. Bootstrap failure presents explicit recovery, preserves
  the original database, and prevents normal capture and App Intent acquisition.
- **Privacy:** no remote link-preview fetcher or background backfill remains.
  Stored metadata and local assets remain useful. Explicit web search, browser
  opening, quicklinks, and existing user-invoked system integrations remain.
  Both sensitive pasteboard markers are checked before reading providers.
- **Secrets:** detected secrets survive automatic age/count retention and unpinning.
  Presentation is masked; raw secret bodies stay out of search, embeddings, and
  enrichment. Export excludes secrets unless the user explicitly accepts a
  plaintext warning. Storage remains plaintext, not encrypted.
- **Lifecycle:** capture is bounded by item/flavor/byte budgets. One enrichment
  worker owns a bounded queue and rejects obsolete publication. Search sessions
  carry immutable query and visibility identity; hidden or disabled sources cannot
  publish stale results. File watchers, Calendar, and Spotify stop with their sources.
  Capture admission is invalidated on pause/shutdown, including buffered snapshots
  and queued database writes; cancellation during a write rolls back its transaction.
- **Search:** all-term candidate validation, path/typo matching, exact-filename
  reservation, and learned ranking before final truncation. Canonical root
  ownership and package/exclusion policies agree between full and incremental
  scans. Individual changes and subtree deletion are coalesced with bounded delay;
  disk-backed search uses a WAL pool and bounded writer. App discovery is single-flight.
- **One product, two windows:** browser defaults to Clipboard with optional preview;
  query, selection, filter, and target application transfer both ways. Shared
  action metadata drives Return=paste, Cmd-Return=copy, Shift-Return=plain paste,
  and Cmd-Shift-Return=stack. Native editor/marked-text/dialog priority, accessible
  buttons, mounted search fields, bounded scrollable menus, and native palette
  focus replace fragile gesture/key routing.
- **Configuration:** typed settings coordination, validated structured aliases and
  quicklinks, advanced text editing, destination previews, and persistent invalid
  drafts. Disabling file results does not start indexing or watchers.
- **Backup:** versioned whole-library archive covers content, payloads, pins,
  snippets, preferences, quicklinks, aliases, hotkeys, and learned ranking, never
  OS permission grants. Streaming limits, canonical blob names, containment,
  symlink rejection, hashes, and references are checked before mutation.
  Export takes a coherent snapshot, stages and validates, then atomically publishes.
  Reimport repairs missing payloads instead of permanently deduplicating them away.
- **Features:** manual snippet arguments/defaults/date formats/token insertion,
  fixed invocation context, preview, cancellation without publication, revision-aware
  saves and conflict/draft errors. Selected-clipboard quicklinks use the full selected
  payload, not the ambient clipboard; the actual encoded destination is confirmed
  before opening. Copy Calculation reuses the existing evaluator/converter.
  Each legacy UUID placeholder retains its own UUID, stable across preview and
  publication for one invocation. Learned usage changes only after successful delivery.
- **Release:** frozen dependency resolution and reusable validation gate the exact
  release SHA before publication. Diagnostics and performance signposts redact
  payloads; no telemetry is added.

## Reproduction

Full Xcode is required; Command Line Tools alone do not provide the SDK/toolchain
needed by application and native-window checks. Locally Xcode 27.0 (27A266a) is
selected per command, without changing the user's global developer directory:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swiftformat --lint .
swiftlint lint --strict
swift test --package-path OverboardKit --disable-automatic-resolution \
  -Xswiftc -warnings-as-errors
swift run --package-path OverboardKit --disable-automatic-resolution \
  -c release file-index-benchmark
xcodebuild -project Overboard.xcodeproj -scheme Overboard \
  -configuration Release -derivedDataPath /tmp/overboard-validation \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO build
```

## Live-window validation

An isolated demo application was exercised on October 1, 2026, without touching
the running daily-driver instance or sending clipboard content to another application:

- Drawer/browser handoff preserves query, selection, and target in both directions.
- Browser starts with Clipboard results; preview toggling keeps the search editor mounted.
- Caret editing stays in the native text editor. Both action palettes receive filter
  focus; closing them restores search focus without changing the query.
- Calculator actions reuse the existing result. Typed settings navigation opens General.
- Structured quicklink editing validates its destination. Invocation shows the full
  selected payload's once-encoded URL in a bounded, accessible, scrollable confirmation;
  Cancel returns to results without opening the URL or publishing clipboard content.
- Onboarding explains copy-only operation when paste authorization is denied.
  Light/dark drawer and browser presentations were inspected in real windows.

Payload-redacted presentation signposts measured first browser presentation at
54 ms, first drawer presentation at 30 ms, and a warm browser presentation at 19 ms
on this host. These intervals measure window ordering/layout, not whole-process
startup. Native burst latency is not independently measured; automated bounded-queue
and indexing-burst tests cover the corresponding lifecycle behavior.

## Safety and remaining manual coverage

- Automated tests use scratch databases, named pasteboards, injected clocks and
  dispatch, isolated preferences, and fake file trees; they do not paste into a
  user's application. Demo-native validation uses `OVERBOARD_DEMO=1` with a unique
  test bundle and ephemeral preference suite, not the running daily-driver instance.
- Historical records whose pasteboard-item boundaries were flattened cannot
  reconstruct that lost boundary information. Payloads deleted before these
  retention changes require an existing backup; the new policy cannot recreate them.
- Native pasteboard clear/write is not atomic across processes. Ownership checks
  protect restoration but cannot turn AppKit publication into a cross-process transaction.
- Archive content is imported transactionally and settings are applied separately
  after validation; OS authorization is always managed by macOS, never an archive.
- Real VoiceOver speech, CJK input-method composition, multiple-monitor/Spaces
  configurations, and actual paste delivery into third-party applications require
  a manual acceptance run. Unit/hidden-window routing and snapshots do not substitute
  for those checks. No new OS grants or system accessibility preferences are changed
  for automated QA. Signing/notarization and a hosted release run are not performed.

## Automated workflow strategy

Deterministic automated checks are the primary validation layer; desktop interaction
is only a final smoke check, not the regression suite. `ClipboardWorkflowTests`
exercises capture, persistence, search, identity-based selection, handoff, pending
external capture, and copy/rich-paste/plain-paste delivery through the real modules.
It uses a named pasteboard and injected dispatch: no global clipboard replacement
or keystrokes are sent to a user's application. Assertions include each item's
text and rich representations, internal-marker suppression, truthful outcomes,
and post-publication usage. Fault-injection suites cover cancellation, obsolete
generations, transactional rollback, corrupt archives, failed publication, recovery,
and source shutdown. Hidden-window focus/routing tests and image snapshots cover
native layout without requiring desktop interaction.

## Validation results

- Frozen Swift package suite: **859 passing tests** across Core, Mac, FilePreview,
  and UI, including normal snapshot comparisons and three clipboard workflow cases.
- Full formatting check, strict SwiftLint, and `git diff --check` pass.
- Debug and unsigned Release application builds pass with full Xcode. The Release
  build emits a dependency-target App Intents metadata warning and three linker
  ambiguous-atom warnings; those warnings are not represented as errors or hidden.
- The 100,000-file benchmark measures warm p95 at **43.1 ms** and concurrent-indexing
  p95 at **43.1 ms** in the recorded pre-delivery run, below the 100 ms gate.
  The frozen suite, lint, unsigned Release build, and benchmark are rerun against
  the final committed revision; exact final measurements accompany delivery.
- Independent Standards and Spec reviews identified follow-up issues; all findings
  were addressed and the bounded follow-up reviews report none remaining.
- The release workflow independently verifies its checkout SHA and gates publication
  on that exact revision. Signing/notarization, hosted publication, and the manual
  coverage listed above remain unverified, not passing.

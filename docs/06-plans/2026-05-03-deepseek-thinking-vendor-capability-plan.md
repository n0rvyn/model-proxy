---
type: plan
status: active
tags: [deepseek, thinking-blocks, vendor-capability, client-settings]
refs: [docs/03-decisions/2026-03-29-thinking-block-layered-handling.md, docs/11-crystals/2026-03-06-proxy-routing-crystal.md, docs/11-crystals/2026-03-07-proxy-resilience-crystal.md, docs/11-crystals/2026-03-26-proxy-encoding-crystal.md]
---

# DeepSeek Thinking Capability Implementation Plan

**Goal:** Fix DeepSeek Anthropic-compatible thinking-mode failures and add vendor-level control for forwarding `thinking` blocks, while also making Client fallback models selectable from configured vendor models.

**Architecture:** Keep the accepted request-side-only thinking design: third-party responses still strip `thinking` before reaching clients, and Anthropic transparent replay remains byte-preserving. Add a vendor capability field that controls request projection for portable vendors, and split persistent branch lookup scope from in-flight coordination scope so Claude Code connection changes do not break thinking history replay.

**Tech Stack:** Swift 6, SwiftUI, JSONSerialization, Swift Testing, Xcode macOS test target.

**Design doc:** none.

**Design analysis:** none.

**Crystal file:** `docs/11-crystals/2026-03-06-proxy-routing-crystal.md`, `docs/11-crystals/2026-03-07-proxy-resilience-crystal.md`, `docs/11-crystals/2026-03-26-proxy-encoding-crystal.md`.

**Threat model:** not applicable.

**Pre-flight risks:**
- `ModelProxy/Services/TranscriptProjector.swift:202` currently treats `thinking` as vendor-safe for every portable third-party vendor; that creates regression risk for vendors that reject `thinking`.
- `ModelProxy/Proxy/ProxyForwarder.swift:447` currently derives persistent `sessionScopeKey` from the TCP channel when no explicit session fields exist; Claude Code connection changes break branch reuse and lose stored `thinking`.
- `ModelProxy/Services/BranchRequestCoordinator.swift:68` uses the same scope for persistent replay and in-flight coordination; removing channel scope from replay without adding coordination scope would make unrelated same-prefix requests block each other.
- `ModelProxy/Proxy/RoutingSnapshot.swift:9` exposes `RouteTarget` through many tests; adding a field needs a custom initializer with a default to avoid broad call-site churn.
- `ModelProxy/Views/RoutingTabView.swift:410` has a private `VendorModelField`; `ClientsTabView.swift:101` uses a plain `TextField`, so the fallback model UI cannot reuse configured `supportedModels` without extracting a shared component.
- Existing `SessionLineageBrokerTests.brokerStartsColdWhenPersistedLineageFileIsMalformed` intentionally writes invalid JSON; log entries from that test are not part of the DeepSeek failure path.
- Baseline command passed on 2026-05-03: `xcodebuild test -project ModelProxy.xcodeproj -scheme ModelProxy -destination platform=macOS -only-testing:ModelProxyTests/SessionLineageBrokerTests -only-testing:ModelProxyTests/TranscriptProjectorTests -only-testing:ModelProxyTests/BranchRequestCoordinatorTests -only-testing:ModelProxyTests/ModelProxyTests`.

**External evidence:**
- DeepSeek Anthropic-compatible endpoint is `https://api.deepseek.com/anthropic`; its compatibility table lists top-level `thinking` as supported and `content` array type `thinking` as supported. `redacted_thinking` is listed as unsupported. Source fetched 2026-05-03: `https://api-docs.deepseek.com/zh-cn/guides/anthropic_api`.
- Anthropic extended thinking docs state that tool-use continuations must pass back the last assistant turn's `thinking` blocks. Source fetched 2026-05-03: `https://docs.anthropic.com/en/docs/build-with-claude/extended-thinking`.
- System log evidence from 2026-05-03 10:10:18 +0800: DeepSeek returned HTTP 400 with `The content[].thinking in the thinking mode must be passed back to the API.`

---

<!-- section: task-1 keywords: Vendor, RoutingSnapshot, supportsThinkingBlocks -->
### Task 1: Add Vendor Thinking Capability To Config And Routes

**Files:**
- Modify: `ModelProxy/Models/Vendor.swift`
- Modify: `ModelProxy/Proxy/RoutingSnapshot.swift`
- Modify: `ModelProxy/Views/VendorEditSheet.swift`
- Test: `ModelProxyTests/ModelProxyTests.swift`

**Steps:**
1. Add `supportsThinkingBlocks: Bool` to `Vendor`.

   ```swift
   var supportsThinkingBlocks: Bool
   ```

2. Add an initializer parameter whose default follows DP-001:

   ```swift
   supportsThinkingBlocks: Bool = VendorDefaults.supportsThinkingBlocks
   ```

   If the implementation does not introduce a `VendorDefaults` helper, use the DP-001 selected literal directly in the initializer and legacy decoder.

3. Add `supportsThinkingBlocks` to `CodingKeys`, decode legacy config with the DP-001 default, and keep encode behavior automatic through `Codable`.

4. Add `supportsThinkingBlocks` to `RoutingSnapshot.RouteTarget` with a custom initializer that preserves current call sites:

   ```swift
   init(
       baseURL: String,
       apiKey: String,
       vendorName: String,
       vendorID: UUID?,
       targetModel: String?,
       isPassthrough: Bool,
       connectTimeoutSeconds: Int,
       readTimeoutSeconds: Int,
       signingDomain: SigningDomain,
       replayPolicy: TranscriptReplayPolicy,
       supportsThinkingBlocks: Bool = VendorDefaults.supportsThinkingBlocks
   )
   ```

5. Wire the field from `Vendor` into primary, backup, and route-all fallback targets. Passthrough targets should use `true` because `.transparent` paths return before portable projection.

6. Add `@State private var supportsThinkingBlocks` to `VendorEditSheet`, load it on edit, save it on add/edit, and render a toggle in `Section("Vendor Details")`:

   ```swift
   Toggle("Supports Thinking Blocks", isOn: $supportsThinkingBlocks)
   ```

7. Add tests:
   - Vendor round-trip with `supportsThinkingBlocks: false`.
   - Legacy vendor JSON defaults according to DP-001.
   - RoutingSnapshot primary, backup, and fallback targets copy `vendor.supportsThinkingBlocks`.

**Verify:**
Run: `xcodebuild test -project ModelProxy.xcodeproj -scheme ModelProxy -destination platform=macOS -only-testing:ModelProxyTests/ModelProxyTests/vendorCodableRoundTripWithSupportedModels -only-testing:ModelProxyTests/ModelProxyTests/vendorDecodesLegacyJSON -only-testing:ModelProxyTests/ModelProxyTests/routingSnapshotResolvesMappedModel -only-testing:ModelProxyTests/ModelProxyTests/routingSnapshotRouteAllUnmappedModel`

Expected: selected `ModelProxyTests` pass, including the new vendor capability assertions.
<!-- /section -->

<!-- section: task-2 keywords: TranscriptProjector, thinking, vendor-capability -->
### Task 2: Gate Vendor-Ready Thinking Blocks By Target Capability

**Files:**
- Modify: `ModelProxy/Services/TranscriptProjector.swift`
- Test: `ModelProxyTests/TranscriptProjectorTests.swift`
- Test: `ModelProxyTests/ProxySessionIntegrationTests.swift`

**Steps:**
1. Change vendor-ready projection to accept the target capability:

   ```swift
   let vendorReadyMessages = Self.makeVendorReadyMessages(
       from: originalMessages,
       supportsThinkingBlocks: target.supportsThinkingBlocks
   )
   ```

2. Add capability parameters through `makeVendorReadyMessages`, `makeVendorReadyMessage`, and `makeVendorReadyBlocks`.

3. In `makeVendorReadyBlocks`, drop `thinking`, `redacted_thinking`, and reasoning-like blocks when `supportsThinkingBlocks == false`. Keep the existing non-standard block filtering.

   ```swift
   if Self.isThinkingLikeBlock(dictionary), !supportsThinkingBlocks {
       return nil
   }
   ```

4. Preserve existing behavior for `supportsThinkingBlocks == true`: current request suffix still strips `signature`, and rehydrated branch history remains unchanged so same-vendor replay does not regress.

5. When a matched branch is reused for a target with `supportsThinkingBlocks == false`, sanitize the decoded branch history before appending the current suffix:

   ```swift
   let branchMessagesForTarget = target.supportsThinkingBlocks
       ? branchFullMessages
       : Self.makeVendorReadyMessages(from: branchFullMessages, supportsThinkingBlocks: false)
   fullMessages = branchMessagesForTarget + suffix
   ```

6. Keep `PortableContentNormalizer` unchanged. Third-party response `thinking` still stays out of the client-visible response.

7. Add tests:
   - `vendorReadyRequestStripsThinkingWhenVendorDoesNotSupportThinkingBlocks`.
   - `portableRequestDoesNotRehydrateThinkingForVendorWithoutThinkingBlocks`.
   - Existing DeepSeek/Qwen-style test continues to keep thinking when the target supports it.
   - Cross-vendor safety test still shows third-party response `thinking` does not reach the client.

**Verify:**
Run: `xcodebuild test -project ModelProxy.xcodeproj -scheme ModelProxy -destination platform=macOS -only-testing:ModelProxyTests/TranscriptProjectorTests/vendorReadyRequestKeepsThinkingStripsSignatureButPortableHashesStripThinking -only-testing:ModelProxyTests/TranscriptProjectorTests/vendorReadyRequestStripsNonStandardContentTypes -only-testing:ModelProxyTests/ProxySessionIntegrationTests/claudeCommitOnPortableVendorDoesNotPoisonMainAnthropicSession`

Expected: selected existing tests plus new capability tests pass.
<!-- /section -->

<!-- section: task-3 keywords: ProxyForwarder, SessionLineageBroker, coordinationScopeKey -->
### Task 3: Split Persistent Replay Scope From In-Flight Coordination Scope

**Files:**
- Modify: `ModelProxy/Proxy/ProxyForwarder.swift`
- Modify: `ModelProxy/Services/SessionLineageBroker.swift`
- Modify: `ModelProxy/Services/TranscriptProjector.swift`
- Modify: `ModelProxy/Services/BranchRequestCoordinator.swift`
- Modify: `ModelProxy/Models/SessionLineage.swift`
- Test: `ModelProxyTests/SessionLineageBrokerTests.swift`
- Test: `ModelProxyTests/BranchRequestCoordinatorTests.swift`
- Test: `ModelProxyTests/ProxySessionIntegrationTests.swift`

**Steps:**
1. Replace `requestSessionScopeKey` with a helper returning both persistent and coordination scopes:

   ```swift
   private struct RequestScopeKeys {
       let sessionScopeKey: String?
       let coordinationScopeKey: String?
   }
   ```

2. Derive scopes as follows:
   - Explicit `session_id`, `conversation_id`, `thread_id`, `metadata.*`, or `container.id`: use `"\(clientName)|explicit|\(explicit)"` for both persistent replay and coordination.
   - No explicit session fields: use `nil` for persistent replay and `"\(clientName)|channel|\(ObjectIdentifier(channel as AnyObject))"` for coordination.

3. Add `coordinationScopeKey` to `PreparedBranchContext`. The initializer should default `coordinationScopeKey` to `sessionScopeKey` so existing direct tests and call sites keep their current behavior until they opt in.

4. Add `coordinationScopeKey` to `SessionLineageBrokering.prepareRequest` and `TranscriptProjecting.prepareRequest`. Keep extension overloads so existing tests remain readable.

5. In `TranscriptProjector.prepareRequest`, use `sessionScopeKey` only for branch matching and lineage seed. Store `coordinationScopeKey` only in `PreparedBranchContext`.

6. In `SessionLineageBroker.prepareRequest`, pass `branchCandidates(for:sessionScopeKey:)` into the projector:

   ```swift
   private func branchCandidates(for clientName: String, sessionScopeKey: String?) -> [BranchTranscript]
   ```

   For explicit sessions, return exact scope matches. For `nil`, return branches whose `sessionScopeKey` is `nil` plus legacy channel-scoped branches containing `"|channel|"`. This keeps already-active sessions usable after the fix.

7. Change public `branches(for:sessionScopeKey:)` to filter at the branch level rather than only at `ConversationLineage.sessionScopeKey`. This prevents a reused legacy lineage from hiding a newly normalized branch.

8. Add `coordinationScopeKey` to `BranchRequestLease`. In `BranchRequestCoordinator`, compare and key in-flight entries by `coordinationScopeKey`; keep `sessionScopeKey` for diagnostics and branch persistence.

9. Add tests:
   - No-explicit-session branch history reuses across two different coordination scope keys.
   - Explicit sessions remain separate even if coordination scope differs.
   - Same portable hashes with different coordination scope keys do not block each other.
   - Legacy channel-scoped branch is considered for a no-explicit-session successor.

**Verify:**
Run: `xcodebuild test -project ModelProxy.xcodeproj -scheme ModelProxy -destination platform=macOS -only-testing:ModelProxyTests/SessionLineageBrokerTests/brokerScopesBranchReuseBySessionScopeKey -only-testing:ModelProxyTests/SessionLineageBrokerTests/brokerReloadsCommittedBranchHistoryFromPersistentStore -only-testing:ModelProxyTests/BranchRequestCoordinatorTests/samePortableHashesFromDifferentSessionScopesDoNotBlockEachOther -only-testing:ModelProxyTests/ProxySessionIntegrationTests/portableBranchSuccessorReusesCommittedVendorHistoryAfterLeaderCompletes`

Expected: selected existing tests plus new scope-split tests pass. The DeepSeek-style successor request reuses stored full assistant history after a channel change.
<!-- /section -->

<!-- section: task-4 keywords: ClientsTabView, VendorModelField, supportedModels -->
### Task 4: Reuse Vendor Model Selection In Client Fallback Settings

**Files:**
- Create: `ModelProxy/Views/Components/VendorSelectionFields.swift`
- Modify: `ModelProxy/Views/RoutingTabView.swift`
- Modify: `ModelProxy/Views/ClientsTabView.swift`
- Test: `ModelProxyTests/ModelProxyTests.swift`

**Steps:**
1. Move the reusable vendor field code out of `RoutingTabView.swift` into `ModelProxy/Views/Components/VendorSelectionFields.swift`:
   - `VendorModelField`
   - `VendorMenuField`
   - `vendorPickerLabel`
   - `menuIconWidth`

2. Keep `SourceModelField` private in `RoutingTabView.swift`; it is only used by routing rules.

3. Add an optional menu item parameter to `VendorModelField` so fallback settings can explicitly clear the field without affecting routing rule behavior:

   ```swift
   let emptySelectionTitle: String?
   ```

   When set, render a menu button that sets `text = ""` and focuses the text field.

4. Replace `ClientsTabView.swift:101` plain fallback `TextField` with `VendorModelField`:

   ```swift
   VendorModelField(
       placeholder: "Fallback model (empty = keep original)",
       text: fallbackModelBinding,
       vendorSelection: fallbackVendorBinding,
       vendors: configStore.config.vendors,
       emptySelectionTitle: "Keep original model"
   )
   ```

5. Do not auto-fill `fallbackTargetModel` when fallback vendor changes. Empty currently means "keep original model"; changing that default would alter route-all behavior without a direct user action.

6. Keep manual entry support. Selecting a configured model writes `fallbackTargetModel`; choosing `Keep original model` writes `nil`.

7. Add a routing test that a `ClientConfig` with `fallbackTargetModel` routes unmapped models to the selected vendor and model.

8. UI automation note: existing `ModelProxyUITests` is only a scaffold and has no Settings navigation harness. This task uses compile coverage plus config/routing unit coverage; manual verification after execution should open Settings → Clients → Unmapped models → Route to vendor → Fallback model menu.

**Verify:**
Run: `xcodebuild test -project ModelProxy.xcodeproj -scheme ModelProxy -destination platform=macOS -only-testing:ModelProxyTests/ModelProxyTests/routingSnapshotRouteAllUnmappedModel`

Expected: selected existing test plus new fallback-target-model assertion pass, and the app target compiles with the extracted shared SwiftUI component.
<!-- /section -->

<!-- section: task-5 keywords: docs, ADR, thinking-blocks -->
### Task 5: Record The Updated Thinking-Block Decision

**Files:**
- Modify: `docs/03-decisions/2026-03-29-thinking-block-layered-handling.md`

**Steps:**
1. Add a 2026-05-03 addendum to the ADR describing:
   - DeepSeek Anthropic-compatible API supports top-level and content-block `thinking`.
   - Some third-party vendors reject `thinking`, so vendor-level `supportsThinkingBlocks` now controls request projection.
   - The response-to-client behavior remains unchanged: third-party `thinking` stays hidden from clients.
   - Anthropic transparent paths remain byte-preserving.
   - Persistent replay scope and coordination scope are split so Claude Code connection changes do not drop stored thinking history.

2. Update the old rejected alternative "Vendor-level `preserveThinkingBlocks` flag" with a note that user-requested capability control is now accepted as an additional guard, not as the original standalone fix.

**Verify:**
Run: `rg -n "2026-05-03|supportsThinkingBlocks|coordination scope|DeepSeek" docs/03-decisions/2026-03-29-thinking-block-layered-handling.md`

Expected: all four terms appear in the ADR.
<!-- /section -->

## Decisions

### [DP-001] Default Value For `Supports Thinking Blocks` (blocking)

**Context:** The user approved adding a vendor switch, but did not choose the default for new vendors and legacy config. Current code forwards vendor-ready `thinking` to every portable third-party vendor, so the default affects both regression risk and DeepSeek success.

| Option | Architecture Fit | Implementation Amount | Risk Or Cost | Use Case |
|---|---|---|---|---|
| A: Default on | Preserves current request-side thinking behavior and lets DeepSeek work without extra setup | Small; legacy decode returns `true` | Vendors that reject `thinking` need users to turn it off | Existing ModelProxy behavior, DeepSeek/Qwen/MiniMax-style vendors |
| B: Default off | Minimizes `thinking` sent to unknown vendors | Small; legacy decode returns `false` | Existing DeepSeek/Qwen/MiniMax routes regress until users edit each vendor | Strict vendors where thinking support is rare |

**Options:**
- A: Default on; legacy config and new vendors start with `Supports Thinking Blocks` enabled.
- B: Default off; legacy config and new vendors start with `Supports Thinking Blocks` disabled.

**Chosen:** Option B

## Acceptance Criteria

- DeepSeek route with `supportsThinkingBlocks == true` receives restored assistant `thinking` on tool-result continuation after Claude Code changes TCP channel.
- Vendor with `supportsThinkingBlocks == false` receives no `thinking`, `redacted_thinking`, or reasoning-like blocks from current request suffix or restored branch history.
- Third-party response `thinking` remains absent from client-visible normalized responses.
- Anthropic official transparent replay continues to return request body unchanged in projector tests.
- Add/Edit Vendor UI can save the new thinking capability.
- Settings → Clients fallback model field can select from the selected fallback vendor's configured `supportedModels`, while retaining manual input and empty = keep original.
- Targeted tests listed in tasks pass before handoff to `dev-workflow:test-changes`.

---

## Verification
- **Verdict:** Approved after DP-001 resolved
- **Date:** 2026-05-03

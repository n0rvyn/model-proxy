---
type: plan
status: active
tags: [routing, settings, swiftui, model-mapping]
refs:
  - docs/11-crystals/2026-03-06-proxy-routing-crystal.md
  - docs/11-crystals/2026-03-06-phase-consolidation-crystal.md
---

# Routing Rule Controls And Model Presets Implementation Plan

**Goal:** Add per-route enable switches, make same-source routing deterministic, reorder Routing form fields, and refresh Claude source model suggestions without changing unrelated Settings behavior.

**Architecture:** Keep routing rules as global `ModelMapping` entries, adding a persisted `isEnabled` field that defaults to true for legacy config. The Routing UI enforces the user-chosen single-enabled-row-per-source rule: enabling, adding, or saving an enabled row disables sibling rows with the same source model. `RoutingSnapshot` builds the runtime table from enabled rows only and keeps a deterministic first-enabled fallback for malformed/hand-edited config that still contains duplicate enabled rows. The Routing UI remains a SwiftUI `Form`; row controls and source model menus consume existing `ConfigStore`, `ProxyServer`, and `TrafficLog` state.

**Tech Stack:** Swift 6, SwiftUI for macOS Settings, Swift Testing for model/routing tests.

**Design doc:** none

**Design analysis:** none

**Crystal file:** docs/11-crystals/2026-03-06-proxy-routing-crystal.md; docs/11-crystals/2026-03-06-phase-consolidation-crystal.md

**Threat model:** included

**Pre-flight risks:**
- `ModelMapping` is consumed by config persistence, `RoutingSnapshot`, Routing UI, and Statistics; all consumers must understand disabled rows.
- `AppConfig` currently decodes `modelMappings` with `try? ... ?? []`; malformed mapping arrays are silently dropped instead of being treated as corrupt config.
- `RoutingSnapshot` currently overwrites duplicate `sourceModel` rows at `ModelProxy/Proxy/RoutingSnapshot.swift:145`; runtime must ignore disabled rows and remain deterministic if hand-edited config violates the UI's single-enabled-row-per-source rule.
- `StatisticsTabView` currently uses `first(where:)` over all mappings at `ModelProxy/Views/StatisticsTabView.swift:91` and `:176`; disabled rows and duplicate source rows can produce wrong display/savings if not updated.
- `KnownAnthropicModels` is static at `ModelProxy/Models/KnownAnthropicModels.swift:6`; source suggestions need both verified current IDs and observed runtime IDs.

---

## Threat Model

### Attack Surface

- Request body `model` field: externally supplied by Claude Code, Codex, or any client using a configured proxy port. Attack class: malformed JSON or unexpected model string. Existing parsing already rejects missing/empty model strings in `RequestRouter`; this plan does not add shell, SQL, regex, or URL interpolation from model strings.
- Config file `modelMappings`: user-controlled local JSON. Attack class: stale/missing `isEnabled`. New decoders must fail closed for corrupt JSON through existing `ConfigStore` behavior, and default only missing `isEnabled` to true for valid legacy rows.

### Failure Modes

- Disabled routing ignored: if `RoutingSnapshot` forgets to filter disabled rows, user-visible switch lies. Tests must cover disabled rows resolving to passthrough or fallback policy.
- Duplicate enabled source drift: if hand-edited config has more than one enabled row for the same source, runtime still needs deterministic behavior. Tests must cover first-enabled fallback, while UI tests/checks cover automatic sibling disablement.
- Source model suggestions: observed IDs only affect menus. If observation fails, custom entry remains available; routing behavior is unchanged.

### Resource Lifecycle

- No temp files, child processes, sockets, or file handles are introduced by implementation tasks. Config persistence continues through existing `ConfigStore.saveAndReload`.

### Input Validation Requirements

- Trim source/target model fields before saving, matching current Routing form behavior.
- `isEnabled` decoding defaults only when the key is absent. Malformed `isEnabled` values must throw.
- `AppConfig.modelMappings` decoding defaults only when the key is absent. Malformed mapping arrays must throw so `ConfigStore` can treat the config as corrupt.

<!-- section: task-1 keywords: ModelMapping, Codable, isEnabled -->
### Task 1: Add persisted `isEnabled` and activation helper to `ModelMapping`

**Files:**
- Modify: `ModelProxy/Models/ModelMapping.swift`
- Modify: `ModelProxy/Models/AppConfig.swift`
- Modify: `ModelProxyTests/ModelProxyTests.swift`

**Crystal ref:** Routing [D-003]; phase consolidation [D-001]

**Steps:**
1. Add `var isEnabled: Bool` to `ModelMapping`.
2. Add `isEnabled: Bool = true` to the initializer and assign it.
3. Add `isEnabled` to `CodingKeys`.
4. In `ModelMapping.init(from:)`, decode `isEnabled` with missing-key-only defaulting:
   ```swift
   if c.contains(.isEnabled) {
       isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
   } else {
       isEnabled = true
   }
   ```
5. In `AppConfig.init(from:)`, replace the lossy model mapping decode:
   ```swift
   if container.contains(.modelMappings) {
       modelMappings = try container.decode([ModelMapping].self, forKey: .modelMappings)
   } else {
       modelMappings = []
   }
   ```
   Keep optional/default behavior for non-critical additive config like `debug`, `modelPricingOverrides`, and `webSearch`.
6. Add a pure activation helper in `ModelMapping.swift` for the user-chosen single-enabled-row-per-source behavior:
   ```swift
   enum ModelMappingActivation {
       static func setEnabled(_ isEnabled: Bool, for id: UUID, in mappings: inout [ModelMapping])
       static func enforceSingleEnabledSource(for id: UUID, in mappings: inout [ModelMapping])
   }
   ```
   Behavior:
   - `setEnabled(false, ...)` disables only the target row.
   - `setEnabled(true, ...)` enables the target row and disables every other row whose trimmed `sourceModel` equals the enabled row's trimmed source model.
   - `enforceSingleEnabledSource(for:...)` applies the sibling-disable rule when a row is already enabled after Add/Edit save.
   - If `id` is not found, leave the array unchanged.
7. Add/adjust tests in `ModelProxyTests.swift`:
   - New mapping initializer defaults to enabled.
   - Codable round trip preserves `isEnabled == false`.
   - Legacy JSON without `isEnabled` decodes as enabled.
   - Malformed `isEnabled` type fails `ModelMapping` decode.
   - Explicit JSON `null` for `isEnabled` fails `ModelMapping` decode.
   - Malformed `isEnabled` inside `AppConfig.modelMappings` fails `AppConfig` decode instead of dropping the array.
   - Explicit JSON `null` for `modelMappings` fails `AppConfig` decode.
   - Activation helper disables same-source siblings when enabling a row.
   - Activation helper leaves other source models unchanged.

**Verify:**
Run: `rg -n "isEnabled|ModelMappingActivation|contains\\(\\.isEnabled\\)|contains\\(\\.modelMappings\\)|modelMappingDecodesLegacyJSON|malformed|null" ModelProxy/Models/ModelMapping.swift ModelProxy/Models/AppConfig.swift ModelProxyTests/ModelProxyTests.swift`
Expected: output shows strict missing-key-only decoding, activation helper, and malformed/activation tests.
<!-- /section -->

<!-- section: task-2 keywords: RoutingSnapshot, duplicate source, disabled mappings -->
### Task 2: Make runtime routing ignore disabled rows with deterministic duplicate fallback

**Files:**
- Modify: `ModelProxy/Proxy/RoutingSnapshot.swift`
- Modify: `ModelProxyTests/ModelProxyTests.swift`

**Crystal ref:** Routing [D-004], [D-005]; phase consolidation [D-003]

**Data flow:** `AppConfig.modelMappings` -> enabled mapping filter -> one active runtime row per `sourceModel` -> `RoutingSnapshot.resolve`.

**Steps:**
1. In `RoutingSnapshot.init(from:for:)`, skip mappings where `mapping.isEnabled == false`.
2. Preserve the first enabled row for each `sourceModel` as a defensive fallback for hand-edited config that violates the UI's single-enabled-row-per-source rule:
   ```swift
   if mappings[mapping.sourceModel] == nil {
       mappings[mapping.sourceModel] = targets
   }
   ```
3. Keep the existing exact-match then longest-prefix behavior unchanged after the active table is built.
4. Add tests in `ModelProxyTests.swift`:
   - Disabled exact mapping is ignored and the request follows the client's unmapped policy.
   - If config contains two enabled rows with the same source, runtime routes to the first row as deterministic fallback.
   - First row disabled and second row enabled routes to the second row.

**Verify:**
Run: `rg -n "isEnabled|mappings\\[mapping\\.sourceModel\\]|first enabled|disabled" ModelProxy/Proxy/RoutingSnapshot.swift ModelProxyTests/ModelProxyTests.swift`
Expected: output shows disabled filtering, first-enabled defensive table insertion, and the new test names.
<!-- /section -->

<!-- section: task-3 keywords: RoutingTabView, Toggle, form order -->
### Task 3: Add Routing row switches and reorder Vendor before Model

**Files:**
- Modify: `ModelProxy/Views/RoutingTabView.swift`

**User interaction:** In Settings > Routing, each row has a switch. Turning it off keeps the row visible and editable, but runtime routing ignores it. Turning a row on automatically turns off other rows with the same source model. Adding or saving an enabled row also turns off other rows with that source. In Add/Edit, users pick Vendor before choosing or typing the vendor model.

**Steps:**
1. Add a `Toggle` to the non-editing `MappingRow` HStack. Use a binding that calls `ModelMappingActivation.setEnabled(_:for:in:)`, then calls `configStore.saveAndReload(proxyServer:)`.
2. When adding a new mapping, append it enabled by default and call `ModelMappingActivation.enforceSingleEnabledSource(for:in:)` for the new row.
3. When saving an edit for an enabled mapping, update the row and call `ModelMappingActivation.enforceSingleEnabledSource(for:in:)` for the saved row. When saving a disabled mapping, keep siblings unchanged.
4. Keep Edit and Delete active even when the row is disabled.
5. Apply secondary opacity or foreground style to disabled route text only; do not disable the whole row.
6. In `MappingRow` edit form, order fields as:
   - Source model
   - Target vendor
   - Target model
7. In `AddMappingRow`, order fields as:
   - Source model
   - Target vendor
   - Target model
8. In backup fields, order as:
   - Backup vendor
   - Backup model
9. Keep existing validation, auto-fill-on-empty behavior, Add Backup Target, Remove Backup, Cancel, Save/Add actions unchanged.
10. New mappings use the model initializer default `isEnabled == true`; no new control is needed inside the Add form.

**Verify:**
Run: `rg -n "Toggle|isEnabled|ModelMappingActivation|Target vendor|Target model|Backup vendor|Backup model|saveAndReload" ModelProxy/Views/RoutingTabView.swift`
Expected: output shows the row toggle, activation helper calls, enabled-state save/reload, and Vendor fields appearing before Model fields in Add/Edit code order.
<!-- /section -->

<!-- section: task-4 keywords: KnownAnthropicModels, source model presets, observed models -->
### Task 4: Refresh source model presets and add observed runtime suggestions

**Files:**
- Modify: `ModelProxy/Models/KnownAnthropicModels.swift`
- Modify: `ModelProxy/Views/RoutingTabView.swift`
- Modify: `ModelProxyTests/ModelProxyTests.swift`

**External source refs:**
- Claude API Models overview: current comparison lists `claude-opus-4-7`, `claude-sonnet-4-6`, `claude-haiku-4-5-20251001`, and alias `claude-haiku-4-5`.
- Claude Code model configuration: `opus` resolves to Opus 4.7 and `sonnet` resolves to Sonnet 4.6 on Anthropic API; aliases can vary by provider.

**User interaction:** The source model menu shows current Claude IDs first, legacy IDs after, and observed IDs from local traffic if ModelProxy has seen them. The user can still type any custom ID.

**Steps:**
1. Replace `KnownAnthropicModels.all` with grouped lists:
   ```swift
   static let current: [String] = [
       "claude-opus-4-7",
       "claude-sonnet-4-6",
       "claude-haiku-4-5",
       "claude-haiku-4-5-20251001",
   ]
   static let legacy: [String] = [
       "claude-opus-4-6",
       "claude-sonnet-4-5",
       "claude-opus-4-1-20250805",
       "claude-opus-4-20250514",
       "claude-sonnet-4-20250514",
       "claude-3-7-sonnet-20250219",
       "claude-3-5-haiku-20241022",
       "claude-3-5-sonnet-20241022",
       "claude-3-opus-20240229",
   ]
   static var all: [String] { current + legacy }
   ```
2. Add a helper on `KnownAnthropicModels` for observed runtime suggestions:
   ```swift
   static func observedSuggestions(from observedModelsOldestToNewest: [String]) -> [String]
   ```
   Behavior: trim whitespace, drop empty strings, drop models already in `all`, dedupe by model string, and return newest-first based on the traffic log order.
3. Update `SourceModelField` to accept `observedModels: [String]`.
4. Build observed models in `RoutingTabView` from `proxyServer.trafficLog.entries.map(\.model)` using the helper.
5. In the menu, show sections in this order: Current, Observed if non-empty, Legacy, Custom.
6. Update the placeholder example to a current ID, such as `claude-sonnet-4-6`.
7. Add a focused test for observed suggestion ordering and dedupe:
   - input oldest-to-newest: `["claude-custom-a", "claude-sonnet-4-6", "claude-custom-b", "claude-custom-a"]`
   - expected: `["claude-custom-a", "claude-custom-b"]` because the second `claude-custom-a` is the newest occurrence and static current IDs are excluded.

**Verify:**
Run: `rg -n "claude-opus-4-7|claude-sonnet-4-6|claude-haiku-4-5|observedSuggestions|observedModels|Current|Observed|Legacy" ModelProxy/Models/KnownAnthropicModels.swift ModelProxy/Views/RoutingTabView.swift ModelProxyTests/ModelProxyTests.swift`
Expected: output shows current IDs, grouped menu labels, observed model plumbing, and the ordering/dedupe test.
<!-- /section -->

<!-- section: task-5 keywords: StatisticsTabView, active mappings, savings -->
### Task 5: Update Statistics to honor active mappings

**Files:**
- Modify: `ModelProxy/Views/StatisticsTabView.swift`

**Data flow:** `configStore.config.modelMappings` -> enabled active mapping view with defensive first-row-per-source fallback -> model display and savings calculation.

**Steps:**
1. Add a small helper in `StatisticsTabView` that returns active mappings using the same defensive fallback as `RoutingSnapshot`: enabled rows only, first row per source if hand-edited config violates the UI invariant.
2. In `statsTable`, match candidate active mappings by both `targetVendorID == row.vendorID` and `targetModel == row.model`.
3. Display rule:
   - If exactly one candidate mapping matches the `(vendorID, targetModel)` row, show `source -> target`.
   - If zero or more than one candidate mappings match, show target model only. Do not invent a source label for ambiguous aggregate rows.
4. In `computeSavings`, use `tokenStatsStore.stats.sourceModelRecords` keyed by source model and active mappings keyed by source model. This keeps savings source-based and avoids target-row ambiguity.
5. Do not change `TokenStatsStore` persistence or table row storage in this task.

**Verify:**
Run: `rg -n "activeMapping|isEnabled|computeSavings|sourceModelRecords|targetVendorID|row.vendorID" ModelProxy/Views/StatisticsTabView.swift`
Expected: output shows active mapping filtering, unambiguous display matching by vendor+target, and source-based savings.
<!-- /section -->

<!-- section: task-6 keywords: ModelProxyTests, Swift Testing, routing controls -->
### Task 6: Add focused regression tests for routing controls

**Files:**
- Modify: `ModelProxyTests/ModelProxyTests.swift`

**Steps:**
1. Add tests near the existing `ModelMapping` and `RoutingSnapshot` tests.
2. Cover:
   - `ModelMapping` defaults `isEnabled` to true.
   - `ModelMapping` preserves false through Codable round trip.
   - Missing JSON field defaults `isEnabled` to true.
   - Malformed JSON type for `isEnabled` fails decode.
   - Explicit JSON `null` for `isEnabled` fails decode.
   - Malformed `isEnabled` inside `AppConfig.modelMappings` fails decode.
   - Explicit JSON `null` for `modelMappings` fails decode.
   - Disabled mapping is ignored by `RoutingSnapshot`.
   - Duplicate enabled source rows use first enabled mapping as runtime fallback.
   - Duplicate source rows use second mapping when first is disabled.
   - `ModelMappingActivation` disables sibling rows when one row is enabled.
   - Observed source model suggestions are newest-first, deduped, and exclude static presets.
3. Use Swift Testing (`@Test`, `#expect`, `Issue.record`) consistent with the existing test file.

**Verify:**
Run: `rg -n "isEnabled|disabledMapping|firstEnabled|duplicateSource|legacy|malformed|null|observedSuggestions" ModelProxyTests/ModelProxyTests.swift`
Expected: output shows the focused regression cases for config decoding, routing precedence, and observed suggestions.
<!-- /section -->

<!-- section: task-7 keywords: README, config schema, isEnabled -->
### Task 7: Document routing rule enablement in README config shape

**Files:**
- Modify: `README.md`

**Steps:**
1. In the feature list, mention that routing rules can be enabled or disabled without deletion.
2. In the config JSON example under `modelMappings`, add:
   ```json
   "isEnabled": true
   ```
3. Keep API key plaintext warning unchanged.

**Verify:**
Run: `rg -n "enabled|isEnabled|modelMappings" README.md`
Expected: output shows the routing rule enablement description and `isEnabled` in the JSON example.
<!-- /section -->

## Decisions

### [DP-001] Same-source routing precedence (recommended)

**Context:** The UI will allow several rows with the same source model. Runtime needs one deterministic active target for each request while keeping the existing per-row backup target behavior.

**Options:**
- A: First enabled row wins — the first enabled row in the visible list handles the request; disabled rows are ignored; backup target inside that row works as before.
- B: Merge all enabled rows into one failover list — every enabled row for the same source becomes a failover candidate; this changes the meaning of the existing Backup Target fields.
- C: Only allow one enabled row per source — turning one row on automatically turns sibling rows off; this adds hidden side effects to the switch.

**Chosen:** Option C — user chose single-enabled-row-per-source behavior. Turning one row on, adding an enabled row, or saving an enabled row disables sibling rows with the same source model.

## Test Assessment

- Business logic changes in `ModelMapping` and `RoutingSnapshot`: covered by unit tests in `ModelProxyTests/ModelProxyTests.swift`.
- User journey changes in Routing UI: covered by user-path validation after execution because no UI test harness currently targets Settings > Routing.
- Source model suggestion ordering: covered by a unit test for the `KnownAnthropicModels.observedSuggestions` helper.
- Statistics display logic: covered by explicit deterministic display rules and source-based savings logic; no new persistence or data mutation path is introduced.

## Verification Notes

- Full build/test execution is intentionally not a plan task. After execution, run the project test suite through the normal test-changes/build verification flow.

---
## Verification
- **Verdict:** Approved
- **Date:** 2026-05-06

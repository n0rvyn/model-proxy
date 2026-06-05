# Vendor Quota / Usage Query API Research

> Date: 2026-06-05
> Status: Research complete, implementation deferred
> Goal: Determine whether MiniMax / Volcengine (火山) Agent Plan / Volcengine Coding Plan / Alibaba Bailian (阿里百炼) Token Plan expose an API to query remaining subscription quota using API + KEY, then evaluate showing it in the ModelProxy menu bar.

## TL;DR

- **Only MiniMax** can query subscription quota with the **same KEY used for model inference**. One `GET`, Bearer auth, no extra credential.
- **Volcengine** and **Alibaba Bailian** put quota/billing behind their cloud OpenAPI, which requires **AK/SK signature** (a credential entirely separate from the inference `sk-` key).
- **Alibaba Bailian Token Plan keys are explicitly banned from automation scripts** — polling them risks an API key ban.
- Recommendation: implement **MiniMax first** (zero new credentials, zero ban risk), defer Volcengine/Bailian to a second phase that requires the user to supply AK/SK.

## 1. Comparison Table

| Vendor / Plan | Official API+KEY quota query? | Endpoint | Auth | Reuses model KEY? | Quota fields returned |
|---|---|---|---|---|---|
| **MiniMax Token/Coding Plan** | ✅ Supported | `GET /v1/token_plan/remains` (official doc)<br>or `GET /v1/api/openplatform/coding_plan/remains` (used by real tool)<br>host: `www.minimaxi.com` (CN) / `www.minimax.io` (intl) | `Authorization: Bearer <key>` | ✅ Yes — same subscription KEY (note: subscription KEY and pay-as-you-go KEY are mutually independent, cannot be mixed) | `model_remains[].current_interval_remaining_percent` (5h window remaining %), `current_interval_total_count`, `remains_time` (reset countdown ms), `current_weekly_*` (weekly window) |
| **火山 Agent Plan** | ⚠️ Half-supported (needs separate credential) | Ark control-plane `GetAFPUsage` (套餐 AFP 额度) + `GetUsageDetails` (用量详情), host `open.volcengineapi.com` | **AK/SK V4 signature** (service=`ark`, version=`2024-01-01`) | ❌ No — not the inference `sk-` key; Volcengine AccessKey/SecretKey | AFP (Agent Fuel Points) quota. [Action names verified from doc sidebar; request body behind login wall, confirm host/fields via API Explorer] |
| **火山 Coding Plan** | ❌ Basically unsupported | No confirmed dedicated remaining-quota endpoint. Whether `GetUsageDetails` covers Coding Plan is unconfirmed | Console view; or probe with `sk-` key and read `x-ratelimit-remaining-requests` response header | Inference key only exposes rate-limit headers, not plan balance | Rate-limit window headroom only, not subscription balance |
| **阿里百炼 Token Plan (团队版)** | ❌ Not supported (with sk- key) | `QueryResourcePackageInstances` (BSS OpenAPI, service `BssOpenApi` 2017-12-14) | **AccessKeyId/AccessKeySecret RPC signature**, needs RAM permission `bss:DescribeInstances` | ❌ No — sk- inference key cannot query balance; must use Aliyun AK/SK | `RemainingAmount` (剩余量), `TotalAmount` (总量), `Status` (Available/Expired), `ExpiryTime` |

**Key takeaway**: Only **MiniMax** lets you query quota with "the same KEY as the model". Volcengine and Bailian both gate billing/quota behind cloud OpenAPI requiring **AK/SK signing** (a credential set completely different from the inference KEY).

## 2. MiniMax — Verified Detail

Both the official doc and a working open-source tool confirm the endpoint exists (verified 2026-06-05).

- **Official doc** (`https://platform.minimaxi.com/docs/token-plan/faq`): `GET https://www.minimaxi.com/v1/token_plan/remains`, headers `Authorization: Bearer <API Key>` + `Content-Type: application/json`. No GroupId.
- **Real tool** (`JochenYang/minimax-status`, MIT, used as a Claude Code statusline): uses `GET https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains` with `Authorization: Bearer <token>` + `referer: https://platform.minimaxi.com/`. GroupId deprecated since v1.2.6 (group parsed from JWT in the token). Confirmed in `cli/api.js:84-88`.
- These are two naming generations of the same feature ("Token Plan" → "Coding Plan"). **Try `token_plan/remains` first; fall back to `coding_plan/remains` on 404.**

**Response shape** (from the tool's parser + mock):
```json
{
  "model_remains": [
    {
      "model_name": "MiniMax-M2",
      "start_time": 1763863200000,
      "end_time": 1763881200000,
      "remains_time": 5160754,
      "current_interval_total_count": 4500,
      "current_interval_remaining_percent": 73.5,
      "current_interval_usage_count": 3307,
      "current_weekly_total_count": 0,
      "current_weekly_remaining_percent": null,
      "weekly_remains_time": 0
    }
  ],
  "base_resp": { "status_code": 0, "status_msg": "success" }
}
```

Field semantics (verified from tool source, with a noted version gotcha):
- `current_interval_remaining_percent` is **remaining %** (NOT consumed %). The tool explicitly stopped inverting it as of v1.2.5.
- `remains_time` = ms until the 5h rolling window resets. Quota does NOT roll over.
- Weekly window mirrors via `current_weekly_*` / `weekly_remains_time`.
- Supplementary endpoints the tool also calls (same Bearer key): `.../charge/combo/cycle_audio_resource_package` (plan expiry) and `/account/amount` (historical billing records).

**NOT queryable via API key**: raw cash/credit balance (`/backend/account/token_plan_credit` is Cookie-auth only, returns 401 with a Bearer key). For cash balance the user must log into the console.

## 3. Third-Party Solutions (when official API+KEY is unavailable)

| Vendor | Third-party solution |
|---|---|
| MiniMax | `JochenYang/minimax-status` (MIT, source verified) — CLI + VSCode extension; endpoints and field parsing directly reusable |
| 火山 | `steipete/CodexBar` (`docs/doubao.md`) — `sk-` key probe reading rate-limit headers; self-reports "no dedicated balance API" for Volcengine |
| 火山 Agent Plan | Volcengine **API Explorer** (serviceCode=`ark`, version=`2024-01-01`) auto-signs; confirm `GetAFPUsage` request body, then call with AK/SK SDK |
| 百炼 | No Bailian-specific community script found. Standard path: Aliyun `alibabacloud_bssopenapi20171214` SDK + AK/SK → `QueryResourcePackageInstances` |

## 4. Hard Constraints (affect feasibility)

1. **Bailian Token Plan KEY cannot be used for automation scripts.** Official doc: Token Plan 团队版 key 「仅限在兼容的 AI 编程和智能体工具中交互式使用，不可用于自动化脚本或应用后端」, violation → `API Key 封禁`. Even if Bailian supported sk- key quota query, menu-bar polling would cross this line. [Verified from doc; re-confirm before relying on it.]
2. **Volcengine Coding Plan quota is consumable only inside whitelisted tools** (Claude Code, Cursor, OpenCode, Cline, TRAE). Using it for raw API calls is flagged as abuse. But *querying* quota (AK/SK control-plane call) is separate from *consuming* it — the query itself is not abuse.

## 5. Menu Bar Feature Evaluation

### Current code (verified)
- **First row renderer**: `StatusPopover.swift:138-197` `tokenSummaryCard` — three columns Input/Output/Total, data from `TokenStatsStore` (global aggregate, NOT per-vendor).
- **What "enabled" means**: `Vendor` has NO `enabled` field. `RoutingSnapshot.swift:103` filters on `ModelMapping.isEnabled == true`. "Enabled vendors" = set of `targetVendorID` across enabled mappings. Note `enforceSingleEnabledSource` means only one mapping per source model can be enabled.
- **No vendor type field**: `Vendor` (`Vendor.swift:25-53`) only has `baseURL + apiKey + SigningDomain`. `SigningDomain` (`TranscriptDomain.swift`) distinguishes auth flavor (anthropic/bedrock/vertex/compatibleThirdParty), NOT provider brand. To know "this is MiniMax / Volcengine / Bailian" we must infer from baseURL host or add a provider enum.
- **Zero account-query code**: `Services/` has no balance/quota logic; everything is proxy forwarding.

### Critique of the "enabled = subscribed" assumption
Enabling a mapping only means "route to this vendor" — it does NOT mean the vendor uses a subscription plan. The same MiniMax vendor could hold a pay-as-you-go KEY (no plan to query), and `/remains` only works for subscription KEYs. So the feature must gracefully handle "this vendor has no queryable plan" (endpoint 401/empty → hide quota, not error out).

### Feasibility by vendor
| Vendor | Menu-bar quota display feasibility |
|---|---|
| MiniMax | ✅ Directly doable — reuse the vendor's stored KEY, one GET, 5h/weekly remaining %. **First priority.** |
| 火山 Agent Plan | ⚠️ Requires user to supply AK/SK — current Vendor model lacks these fields, schema must expand |
| 火山 Coding Plan | ❌ No stable API; only rate-limit headroom (limited value) or unsupported |
| 百炼 Token Plan | ❌ Needs AK/SK + crosses the automation-ban line; **do NOT auto-poll** |

### Architecture impact (if implemented)
1. **Provider identification**: add `Vendor.quotaProvider` enum (`.miniMax / .volcengine / .bailian / .none`) — cleaner than host-sniffing (host-sniff is what `SigningDomain` does today, but quota endpoints don't map 1:1 to host).
2. **Quota query service**: new `Services/QuotaService`, dispatch by provider; MiniMax uses vendor KEY, Volcengine/Bailian need new AK/SK fields.
3. **Polling cadence**: fetch on menu open + timed refresh (MiniMax 5h window → 30-60s refresh is plenty), cache to avoid hitting on every open.
4. **Multi enabled-vendor UX**: first row is currently a single global aggregate. If multiple enabled vendors support quota query, whether to show one / multiple rows is a UX decision for the user.

### Recommendation
**Two phases. Phase 1 = MiniMax only** (the only vendor that reuses the model KEY, zero new credentials, zero ban risk). Build the skeleton (provider identification + QuotaService + menu-bar quota row), validate UX. **Phase 2** = evaluate whether Volcengine/Bailian justify making the user enter a second AK/SK credential set, given Bailian's automation-ban line.

### Open decisions for the user (must confirm before implementation — new user-visible View layout/interaction)
1. **Quota row form**: new row below Input/Output/Total, or a 4th column beside them? When multiple enabled vendors support quota, show all (multiple rows) or just one?
2. **Scope**: MiniMax-only first, or add Volcengine/Bailian AK/SK credential fields in the same pass?
3. **Bailian**: given the automation-ban line, skip auto-query entirely (user checks console), or accept the risk with a manual "click to refresh"?

## Sources

- MiniMax official FAQ (CN): https://platform.minimaxi.com/docs/token-plan/faq
- MiniMax official FAQ (intl): https://platform.minimax.io/docs/token-plan/faq
- MiniMax tool source: https://github.com/JochenYang/minimax-status
- Volcengine Coding Plan overview: https://www.volcengine.com/docs/82379/1925114
- Volcengine Agent Plan overview: https://www.volcengine.com/docs/82379/2366394
- Volcengine GetInferenceUsage (control-plane): https://www.volcengine.com/docs/82379/2116766
- Volcengine Ark auth (AK/SK): https://www.volcengine.com/docs/82379/1465834
- Volcengine billing OpenAPI list: https://www.volcengine.com/docs/6269/130259
- CodexBar (rate-limit-header approach): https://github.com/steipete/CodexBar/blob/main/docs/doubao.md
- Bailian Token Plan overview: https://help.aliyun.com/zh/model-studio/token-plan-overview
- Bailian QueryResourcePackageInstances (BSS): https://help.aliyun.com/zh/user-center/developer-reference/api-bssopenapi-2017-12-14-queryresourcepackageinstances
- Bailian QueryDPUtilizationDetail (usage detail): https://help.aliyun.com/zh/user-center/developer-reference/api-bssopenapi-2017-12-14-querydputilizationdetail

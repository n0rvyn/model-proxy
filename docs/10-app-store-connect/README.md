# App Store Connect — published pages

Source of truth for the three pages Apple links to from the store listing. These files are the
copy; the live pages are Notion documents. **Editing a file here does not update Notion** —
re-publish the Notion page after any change, then verify the URL in ASC still resolves.

| File | ASC field | Canonical URL (norvyn.com) | Legacy (Notion, being retired) |
|---|---|---|---|
| `Privacy-Policy.md` | Privacy Policy URL (App Info) | https://norvyn.com/modelproxy-privacy | `sepia-crafter-ff6.notion.site/Privacy-Policy-31c66a2f…` |
| `Support-Page.md` | Support URL (Version) | https://norvyn.com/modelproxy-support | `sepia-crafter-ff6.notion.site/Support-Page-31c66a2f…` |
| `Terms-of-Use.md` | linked from the support page | https://norvyn.com/modelproxy-terms | `sepia-crafter-ff6.notion.site/…` |

**norvyn.com is now the canonical home** (self-hosted; the site is the `wordbase` project,
which serves the apex). The three pages went live 2026-08-28 as wordbase companion pages
`modelproxy-privacy` / `-terms` / `-support`, matching the existing `<app>-<type>` convention
used by five other apps.

⚠️ **ASC still points at the Notion URLs.** Version 2.5 is in review and its metadata is
locked, so the switch happens on the next submission: change Privacy Policy URL (App Info) and
Support URL (Version) to the norvyn.com links above, then retire the Notion pages.

**The Notion pages were cleaned in place on 2026-08-28**, so the URLs currently under review no
longer name OpenAI. Seven blocks were patched across three pages, verified by read-back
(block counts unchanged, zero occurrences of `openai` / `ChatGPT` / `DashScope` remaining):

| Notion page | What was fixed |
|---|---|
| Privacy Policy | EN + CN "Data Sharing" paragraph — dropped the `(e.g., Anthropic, OpenAI, Alibaba Cloud)` list |
| Support Page | EN + CN "Which AI providers are supported" — the false DashScope/OpenAI preset claim |
| **Market** (this is the ASC **Marketing URL**) | EN + CN "Multi-Vendor Routing" bullet, **and** a stale 2.3-era keyword line that literally contained `openai` |

⚠️ The Market page is easy to forget: `marketingUrl` is an ASC metadata field too, and that page
carried two OpenAI mentions plus a verbatim keyword list. Any future metadata sweep must cover
**all three** URLs (privacyPolicyUrl, supportUrl, marketingUrl), not just the first two.

To republish after editing a file here:

```bash
# WORDBASE_API_KEY is already exported; see the wordbase repo's CLAUDE.md
curl -X PUT https://norvyn.com/api/pages/<pageId> \
  -H "Authorization: Bearer $WORDBASE_API_KEY" -H 'Content-Type: application/json' \
  -d '{"content": "..."}'
curl -X POST https://norvyn.com/api/pages/<pageId>/publish -H "Authorization: Bearer $WORDBASE_API_KEY"
```

Page ids: privacy `UcsZjthdGesVulqhrqU4m` · terms `tFiaSvs8h0_zzdvEM1N5m` ·
support `AqFbI-kVlRaJV1oyxRwV0`. Publishing triggers a static rebuild; the public URL 404s for
a short window before it lands, so verify by fetching the URL, not by trusting the 200.

Store metadata itself (app name, subtitle, keywords, description, promotional text, What's New,
screenshots) is not in this folder. It lives in `private/asc/`, which is gitignored because this
repo is public.

## Standing compliance constraint

⛔ While the **China mainland** storefront is selected in ASC Availability, the token `openai`
must not appear in **any** localization of any App Store metadata field — app name, subtitle,
keywords, description, promotional text, What's New, or screenshot artwork — nor on the pages in
this folder. Same for `ChatGPT`.

Reason: Guideline 5 (Legal). Mainland China requires an MIIT deep-synthesis permit for services
associated with ChatGPT/OpenAI. Version 2.5 was rejected on 2026-08-27 for the literal token
`openai` in the keyword fields.

Scope note: App Store Connect metadata is **per-locale, not per-territory**. There is no
China-only copy of a keyword field, so "remove it for China" necessarily means removing it
everywhere. The only alternative is deselecting the China mainland storefront.

**The constraint is `openai`/`ChatGPT` and nothing more — do not over-scrub.** The 2.5 rejection
came from a full human re-review (triggered by the app-name change). That reviewer saw a CN
subtitle reading `为 Claude Code 路由大模型 API`, a description naming Codex, keyword fields
containing `claude`, `codex` and `anthropic`, and screenshots captioned with "Codex" — and cited
one token: `openai`. Those brands survived this review, not just older ones. Providers that hold
mainland permits (DeepSeek, 智谱/GLM, Kimi, MiniMax) are likewise unaffected.

Dropping brand keywords defensively has a measured price: `claude code` ranks the app 38th in CN
and 110th in US; `模型代理` and `api 代理` are both #1. Remove what Apple names, nothing else.

Detail, evidence, and the resubmit checklist: `private/asc/2026-08-27-guideline-5-china-rejection.md`.

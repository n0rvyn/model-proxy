# ModelProxy E2E harness

End-to-end checks that drive a real ModelProxy build with a real Claude Code and a real third-party
vendor (DeepSeek's Anthropic endpoint), the same path a user takes. Unit tests do not cover this path:
the concurrent-response mixup fixed on 2026-09-26 passed every unit test and failed here on the first run.

## What you need

| Item | Why | Where it comes from |
|---|---|---|
| macOS with Xcode | builds the app | — |
| Claude Code (`claude` on `PATH` or in `~/.local/bin`) | the client under test | your install; the harness never touches its settings |
| `DEEPSEEK_API_KEY` | vendor for every mapped model | environment, or a `DEEPSEEK_API_KEY=…` line in the repo's `.env` |
| `GOOGLE_SEARCH_API_KEY`, `GOOGLE_SEARCH_ENGINE_ID` (optional) | the `websearch` scenario | environment or `.env` (`NAME=value`, or the older `KEY：…` / `Engine ID：…` lines) |
| Accessibility permission for your terminal | `up.sh` clicks the app's menu bar item to start the proxy | System Settings → Privacy & Security → Accessibility |

`.env` is gitignored. This repo is public: keys go in `.env` or the environment, never in a tracked file.

## Use

```bash
scripts/e2e/build.sh              # build the working tree as an isolated E2E app
scripts/e2e/up.sh                 # write the isolated config, launch, start listeners
scripts/e2e/scenarios.sh          # run all scenarios; exit code 1 if any fails
scripts/e2e/down.sh               # stop the app, delete the config (keys) and captures
```

- One scenario or a few: `scenarios.sh --only cc_tools,cc_continue` (`--list` prints the names).
- Include the web search scenario: `scenarios.sh --websearch` (uses search quota, see the rules).
- Compare with another version: `build.sh origin/dev`, then `up.sh <printed app path>`. It builds that ref in a temporary worktree, and `down.sh --all` removes it.
- Run Claude Code yourself against the proxy: `scripts/e2e/cc.sh -p "…" --model claude-sonnet-5`.
- See what Claude Code actually sent (ModelProxy never logs bodies):

  ```bash
  python3 scripts/e2e/capture_proxy.py "${TMPDIR%/}/modelproxy-e2e/capture" 19091 19090 &
  MP_E2E_BASE_URL=http://127.0.0.1:19091 scripts/e2e/cc.sh -p "…"
  ```

Work files go to `${TMPDIR%/}/modelproxy-e2e` (override with `MP_E2E_ROOT`). A full run takes about a minute and a few dozen DeepSeek `deepseek-flash` calls.

## Scenarios

| Name | What it proves |
|---|---|
| `head_probe` | `HEAD /api/hello` is answered locally with 200 |
| `count_tokens_forwarded` | count_tokens goes to the vendor when Supports Count Tokens is on (decoded default) |
| `count_tokens_local_404` | with it off, a local Anthropic-shaped 404 (never 501) |
| `malformed_body_fast` | proxy error responses return immediately (App Store 2.5 hung here for 15 s+) |
| `concurrent_same_session_isolated` | same session, same messages, different system prompt → two upstream calls, no shared response |
| `identical_retry_joined` | an identical concurrent retry still joins the in-flight call |
| `passthrough_relays_anthropic` | an unmapped model on the passthrough client reaches Anthropic and its error comes back unmodified |
| `cc_text` | plain Claude Code turn through a mapped vendor |
| `cc_tools` | multi-turn Read / Edit / Bash with branch reuse |
| `cc_strip_vendor` | Strip Claude-Only Request Fields removes fields and the vendor still answers |
| `cc_no_thinking_vendor` | Supports Thinking Blocks off still works for DeepSeek's own tool calls |
| `cc_subagents` | two parallel subagents get their own coordination scopes |
| `cc_continue` | `--continue` works. Prints restored thinking and per-request branch reuse; the 2nd-request miss is issue #9 |
| `websearch` (opt-in) | the search bridge ends in 200 even when the provider fails. Watchdog kills the run at the 2nd bridge failure |

The isolated config maps the Claude 5 models to DeepSeek on vendor "DeepSeek" (defaults),
`claude-sonnet-4-6` to "DeepSeek Strip" (strip on, count tokens off) and `claude-opus-4-7` to "DeepSeek
NoThinking". See `gen_config.py`.

## Rules

1. **Never test against the installed app.** The E2E build uses bundle ID `com.90percent.ModelProxy.e2e`, runs without the App Sandbox and listens on 19090 / 19092. The installed copy keeps its own container and port 9090. Without the sandbox, config and logs live in `~/Library/Application Support/ModelProxy`. `up.sh` creates that folder with a marker file and refuses to touch one it did not create.
2. **Never mix with your own Claude Code.** `cc.sh` starts from an empty environment (`env -i`) with its own `CLAUDE_CONFIG_DIR`, workspace and dummy API key. Do not run Claude Code against the E2E ports with your normal settings.
3. **Run `down.sh` when finished.** `config.json` holds the keys in plaintext, and `capture/` holds full prompts.
4. **Web search spends real quota.** Google Custom Search's free tier is 100 queries a day. Before the bridge fix, one failing run retried 12+ times and used it all up. Keep `--websearch` opt-in, run it once, and trust the watchdog.
5. **Read the proxy log, not os_log.** Debug logging is on in the E2E config. The log is `logs/modelproxy-YYYY-MM-DD.log` under the folder in rule 1. It has no bodies by policy; use `capture_proxy.py` when you need them.
6. **Take unit-test counts from the xcresult bundle** (`xcrun xcresulttool get test-results summary --path …`). Parallel test output interleaves lines, so `grep -c passed` on the xcodebuild log is off by one or two.
7. **Prove a new scenario can fail.** Before trusting a new check, run it against a build that has the bug (`build.sh <old ref>`) and see it go red.

## Driving the UI

The E2E app's menu bar icon looks exactly like the installed copy's, so address it by pid:

- Start or open the popover: `osascript -e 'tell application "System Events" to tell (first process whose unix id is <pid>) to click menu bar item 1 of menu bar 2'` (the pid is in `${TMPDIR%/}/modelproxy-e2e/app.pid`).
- Find its windows: `swift scripts/e2e/ui/winpid.swift <pid>`, then `screencapture -x -o -l <window id> out.png`.
- Scroll a sheet's form: `swift scripts/e2e/ui/scroll.swift <x> <y> -10`.
- Buttons in a sheet: when a synthetic click only activates the window, use `perform action "AXPress" of button N of group 1 of sheet 1 of window 1` through System Events. A grey switch in a screenshot can just mean the window is inactive; read the checkbox `value` instead of trusting its color.

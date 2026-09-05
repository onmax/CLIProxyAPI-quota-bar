# Quota Bar

A native macOS menu bar companion for a CLIProxyAPI account pool, forked from
[LoveEatCandy/CLIProxyAPI-quota-bar](https://github.com/LoveEatCandy/CLIProxyAPI-quota-bar).
The original SwiftBar plugin and proxy client remain in `quota.5m.py`. This fork adds
an AppKit/SwiftUI popover with a CodexBar-inspired layout and a compact quota indicator.

## Install the native app

Requires macOS 14+, Apple's command line tools, Python 3, and an existing CLIProxyAPI
management connection. No package dependencies or local HTTP server are needed.

```sh
./build.sh
cp -R '.build/Quota Bar.app' /Applications/
open '/Applications/Quota Bar.app'
```

Before opening, create `~/.config/cliproxy-quota-bar/config.json` with permissions `600`:

```json
{
  "base_url": "http://127.0.0.1:8317",
  "credentials_file": "~/.config/cliproxy-quota-bar/.env",
  "dashboard_url": "http://127.0.0.1:8317/management.html#/quota",
  "accounts": [
    { "name": "main", "email": "first-account@example.com" },
    { "name": "second", "email": "second-account@example.com" }
  ]
}
```

The private credentials file contains `CPA_MANAGEMENT_KEY=...`. It may point to an
existing SwiftBar plugin `.env`; credentials are not bundled or committed. Use HTTPS
or a loopback SSH tunnel for the management connection. Accounts are an explicit
allowlist; disabled, missing, or ambiguous accounts are never used to reset.

The title shows the sum of weekly remaining percentages. Four accounts have a
maximum of 400%. This is a summary of independent quotas, not a guarantee that
any individual request can use all remaining capacity. A trailing dot means the
last read failed or the data is older than ten minutes. Unknown data is not zero.

## Summary and resets

The overview shows total quota, each account's weekly renewal, available resets,
and credit expiry. Expand an account's reset count to see all grant and expiry dates.
Data refreshes every five minutes. Refresh and opening the reset preview only read
quota metadata through the management API; they never redeem credits.

Reset recommendations require:

- At most 10% weekly quota remaining.
- A supported, unexpired reset and a positive upstream `applicable_available_count`.
- A successful quota and reset read. Unknown state cannot authorize a reset.
- More than one hour until the regular weekly renewal.

Among eligible accounts, the earliest-expiring credit wins, then the least remaining
quota. The preview permits selecting a different account, explains why an account
is ineligible, and shows the expected gain, grant dates, expiry dates, and countdowns.
Newer credits are preserved when an older eligible account has an earlier expiry.

**OpenAI chooses which credit within the selected account is consumed.** The deployed
API accepts a redemption request UUID, not a specific credit ID. The preview lists
credits by expiry without promising which one OpenAI will use.

Only **Use 1 reset · account** invokes consumption. It re-reads the account and verifies
that the reviewed quota and reset revision is unchanged. The request is sent once with
a UUID, under a process lock, and recorded before sending. There is no automatic reset,
no purchase, and no automatic retry of consumption. The proxy's local cooldown is
cleared only after the upstream has confirmed a successful redemption.

If a reset result is uncertain, subsequent resets are blocked. Check the provider's
quota and credit list in the dashboard. After manually resolving the outcome, archive
`~/Library/Application Support/Quota Bar/pending-reset.json` to enable a fresh preview.
Do not remove the receipt before checking whether the credit was consumed.

## Development

`./build.sh` compiles and signs the local app ad hoc. It does not launch it or make
network requests. The installation task did not run tests, UI interaction checks,
or any reset operation, at the user's request. `check_policy.py` is an optional,
network-free policy check left for later; it does not import credentials or consume
anything. Live reset behavior remains untested.

## Original SwiftBar plugin

Copy `quota.5m.py` to a SwiftBar plugin directory, make it executable, and set
`CPA_BASE_URL` and `CPA_MANAGEMENT_KEY` in a sibling `.env`. The upstream script
continues to support Codex and Antigravity. The native app uses an explicit Codex
account allowlist from the private configuration instead.

Apache-2.0; original work copyright LoveEatCandy. Native companion and pool/reset
logic added by onmax. CodexBar is a visual reference; this app is not CodexBar.

#!/usr/bin/env python3
"""Modified by onmax: optional external credentials file for the native companion.

SwiftBar plugin to display CLIProxyAPI quota for Codex and Antigravity.

This plugin queries the CLIProxyAPI Management API to:
1. List auth files and filter for codex/antigravity providers
2. Query quota usage via the api-call proxy endpoint
3. Display results in the macOS status bar via SwiftBar

Configuration (environment variables):
    CPA_BASE_URL: API base URL (required)
    CPA_MANAGEMENT_KEY: Management API key (required)

SwiftBar metadata:
    <xbar.title>CLIProxyAPI Quota</xbar.title>
    <xbar.version>v1.0</xbar.version>
    <xbar.author>LoveEatCandy</xbar.author>
    <xbar.author.github>LoveEatCandy</xbar.author.github>
    <xbar.desc>Display Codex and Antigravity quota usage</xbar.desc>
    <xbar.dependencies>python3</xbar.dependencies>
    <swiftbar.runInBash>false</swiftbar.runInBash>
    <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
    <swiftbar.hideLastUpdated>false</swiftbar.hideLastUpdated>
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any

# ── Load .env file ───────────────────────────────────────────────────────────

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_ENV_FILE = os.environ.get("CPA_ENV_FILE", os.path.join(_SCRIPT_DIR, ".env"))

if os.path.isfile(_ENV_FILE):
    with open(_ENV_FILE) as _f:
        for _line in _f:
            _line = _line.strip()
            if not _line or _line.startswith("#") or "=" not in _line:
                continue
            _key, _, _val = _line.partition("=")
            _key = _key.strip()
            _val = _val.strip().strip("\"'")
            if _key and _key not in os.environ:
                os.environ[_key] = _val

# ── Configuration ────────────────────────────────────────────────────────────

BASE_URL = os.environ["CPA_BASE_URL"].rstrip("/")
MANAGEMENT_KEY = os.environ["CPA_MANAGEMENT_KEY"]
MANAGEMENT_API = f"{BASE_URL}/v0/management"
REQUEST_TIMEOUT = 15  # seconds

# Providers we care about
TARGET_PROVIDERS = {"codex", "antigravity"}

# ── Upstream API Constants (from Management Center source) ───────────────────

# Codex
CODEX_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
CODEX_REQUEST_HEADERS = {
    "Authorization": "Bearer $TOKEN$",
    "Content-Type": "application/json",
    "User-Agent": "codex_cli_rs/0.76.0 (Debian 13.0.0; x86_64) WindowsTerminal",
}

# Antigravity (try URLs in order until one succeeds)
ANTIGRAVITY_QUOTA_URLS = [
    "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
    "https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:fetchAvailableModels",
    "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
]
ANTIGRAVITY_REQUEST_HEADERS = {
    "Authorization": "Bearer $TOKEN$",
    "Content-Type": "application/json",
    "User-Agent": "antigravity/1.11.5 windows/amd64",
}
DEFAULT_ANTIGRAVITY_PROJECT_ID = "bamboo-precept-lgxtn"

# Antigravity model groups for display
ANTIGRAVITY_GROUPS: list[dict[str, Any]] = [
    {
        "id": "claude-gpt",
        "label": "Claude/GPT",
        "ids": [
            "claude-sonnet-4-5-thinking",
            "claude-opus-4-5-thinking",
            "claude-opus-4-6-thinking",
            "claude-sonnet-4-5",
            "claude-sonnet-4-6",
            "gpt-oss-120b-medium",
        ],
    },
    {
        "id": "gemini-3-pro",
        "label": "Gemini 3 Pro",
        "ids": [
            "gemini-3-pro-high",
            "gemini-3-pro-low",
            "gemini-3.1-pro-high",
            "gemini-3.1-pro-low",
        ],
    },
    {
        "id": "gemini-3-flash",
        "label": "Gemini 3 Flash",
        "ids": [
            "gemini-3-flash",
            "gemini-3.1-flash-image",
        ],
    },
    {
        "id": "gemini-2.5-pro",
        "label": "Gemini 2.5 Pro",
        "ids": [
            "gemini-2.5-pro",
        ],
    },
    {
        "id": "gemini-2-5-flash",
        "label": "Gemini 2.5 Flash",
        "ids": [
            "gemini-2.5-flash",
            "gemini-2.5-flash-thinking",
        ],
    },
    {
        "id": "gemini-2-5-flash-lite",
        "label": "Gemini 2.5 Flash Lite",
        "ids": [
            "gemini-2.5-flash-lite",
        ],
    },
]

# Provider display config
PROVIDER_ICONS: dict[str, str] = {
    "codex": "🤖",
    "antigravity": "🌀",
}
PROVIDER_LABELS: dict[str, str] = {
    "codex": "Codex",
    "antigravity": "Antigravity",
}


# ── Data Models ──────────────────────────────────────────────────────────────


@dataclass
class AuthFile:
    """Represents a single auth credential file."""

    name: str
    provider: str
    auth_index: str = ""
    email: str = ""
    status: str = "unknown"
    status_message: str = ""
    disabled: bool = False
    unavailable: bool = False
    label: str = ""
    account_type: str = ""
    # Codex-specific
    chatgpt_account_id: str = ""
    plan_type: str = ""
    # Antigravity-specific
    project_id: str = ""


@dataclass
class CodexQuota:
    """Codex quota information."""

    email: str = ""
    plan_type: str = ""
    primary_used_pct: int | None = None
    primary_reset_seconds: int | None = None
    secondary_used_pct: int | None = None
    secondary_reset_seconds: int | None = None
    limit_reached: bool = False
    error: str = ""


@dataclass
class AntigravityModelQuota:
    """Quota for a group of Antigravity models."""

    group_label: str = ""
    remaining_fraction: float | None = None
    reset_time: str = ""
    models: list[str] = field(default_factory=list)


@dataclass
class AntigravityQuota:
    """Antigravity quota information."""

    email: str = ""
    groups: list[AntigravityModelQuota] = field(default_factory=list)
    error: str = ""


# ── API Client ───────────────────────────────────────────────────────────────

HTTP_HEADERS = {
    "Authorization": f"Bearer {MANAGEMENT_KEY}",
    "Content-Type": "application/json",
    "User-Agent": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/131.0.0.0 Safari/537.36"
    ),
}


def _make_request(
    url: str,
    method: str = "GET",
    data: dict[str, Any] | None = None,
    max_retries: int = 3,
) -> dict[str, Any]:
    """Make an HTTP request to the Management API.

    :param url: Full URL to request.
    :param method: HTTP method (GET, POST, etc.).
    :param data: JSON body for POST/PUT requests.
    :param max_retries: Maximum number of attempts (default 3).
    :returns: Parsed JSON response.
    :raises RuntimeError: On HTTP or network errors after all retries.
    """
    body = json.dumps(data).encode("utf-8") if data else None
    last_exc: Exception | None = None

    for attempt in range(max_retries):
        req = urllib.request.Request(url, data=body, headers=HTTP_HEADERS, method=method)
        try:
            with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            code = exc.code
            error_body = exc.read().decode("utf-8", errors="replace")
            # Don't retry client errors (4xx) except 429
            if 400 <= code < 500 and code != 429:
                msg = f"HTTP {code}: {error_body}"
                raise RuntimeError(msg) from exc
            last_exc = RuntimeError(f"HTTP {code}: {error_body}")
        except urllib.error.URLError as exc:
            last_exc = RuntimeError(f"Connection error: {exc.reason}")

        if attempt < max_retries - 1:
            time.sleep(1 * (attempt + 1))

    raise last_exc  # type: ignore[misc]


def api_call(payload: dict[str, Any]) -> dict[str, Any]:
    """Make a proxied API call via /v0/management/api-call.

    :param payload: Request payload with authIndex, method, url, header, etc.
    :returns: Parsed JSON response containing status_code, header, body.
    :raises RuntimeError: On HTTP errors.
    """
    return _make_request(f"{MANAGEMENT_API}/api-call", method="POST", data=payload)


# ── Auth Files ───────────────────────────────────────────────────────────────


def get_auth_files() -> list[AuthFile]:
    """Fetch and parse the auth files list from the Management API.

    :returns: List of :class:`AuthFile` objects filtered for target providers.
    """
    url = f"{MANAGEMENT_API}/auth-files"
    resp = _make_request(url)

    auth_files: list[AuthFile] = []
    for item in resp.get("files", []):
        provider = item.get("provider", "")
        if provider not in TARGET_PROVIDERS:
            continue

        af = AuthFile(
            name=item.get("name", ""),
            provider=provider,
            auth_index=item.get("auth_index", "") or item.get("authIndex", ""),
            email=item.get("email", ""),
            status=item.get("status", "unknown"),
            status_message=item.get("status_message", ""),
            disabled=item.get("disabled", False),
            unavailable=item.get("unavailable", False),
            label=item.get("label", ""),
            account_type=item.get("account_type", ""),
        )

        # Extract Codex-specific fields from id_token
        id_token = item.get("id_token", {})
        if id_token and provider == "codex":
            af.chatgpt_account_id = id_token.get("chatgpt_account_id", "")
            af.plan_type = id_token.get("plan_type", "")

        auth_files.append(af)
    return auth_files


# ── Codex Quota ──────────────────────────────────────────────────────────────


def fetch_codex_quota(af: AuthFile) -> CodexQuota:
    """Fetch Codex quota via the api-call proxy.

    :param af: Auth file for the Codex account.
    :returns: :class:`CodexQuota` with usage data.
    """
    quota = CodexQuota(email=af.email, plan_type=af.plan_type)

    if not af.auth_index:
        quota.error = "missing auth_index"
        return quota
    if not af.chatgpt_account_id:
        quota.error = "missing chatgpt_account_id"
        return quota

    try:
        headers = dict(CODEX_REQUEST_HEADERS)
        headers["Chatgpt-Account-Id"] = af.chatgpt_account_id

        result = api_call(
            {
                "authIndex": af.auth_index,
                "method": "GET",
                "url": CODEX_USAGE_URL,
                "header": headers,
            }
        )

        status_code = result.get("status_code", 0)
        if status_code < 200 or status_code >= 300:
            quota.error = f"HTTP {status_code}"
            return quota

        body_str = result.get("body", "")
        if not body_str:
            quota.error = "empty response"
            return quota

        body = json.loads(body_str) if isinstance(body_str, str) else body_str
        quota.plan_type = body.get("plan_type", af.plan_type)

        rate_limit = body.get("rate_limit", {})
        quota.limit_reached = rate_limit.get("limit_reached", False)

        primary = rate_limit.get("primary_window", {})
        if primary:
            quota.primary_used_pct = primary.get("used_percent")
            quota.primary_reset_seconds = primary.get("reset_after_seconds")

        secondary = rate_limit.get("secondary_window", {})
        if secondary:
            quota.secondary_used_pct = secondary.get("used_percent")
            quota.secondary_reset_seconds = secondary.get("reset_after_seconds")

    except (RuntimeError, json.JSONDecodeError, KeyError) as exc:
        quota.error = str(exc)

    return quota


# ── Antigravity Quota ────────────────────────────────────────────────────────


def fetch_antigravity_quota(af: AuthFile) -> AntigravityQuota:
    """Fetch Antigravity quota via the api-call proxy.

    Tries multiple upstream URLs in order until one succeeds.

    :param af: Auth file for the Antigravity account.
    :returns: :class:`AntigravityQuota` with model group quotas.
    """
    quota = AntigravityQuota(email=af.email)

    if not af.auth_index:
        quota.error = "missing auth_index"
        return quota

    project_id = af.project_id or DEFAULT_ANTIGRAVITY_PROJECT_ID
    request_body = json.dumps({"project": project_id})
    last_error = ""

    for url in ANTIGRAVITY_QUOTA_URLS:
        try:
            result = api_call(
                {
                    "authIndex": af.auth_index,
                    "method": "POST",
                    "url": url,
                    "header": dict(ANTIGRAVITY_REQUEST_HEADERS),
                    "data": request_body,
                }
            )

            status_code = result.get("status_code", 0)
            if status_code < 200 or status_code >= 300:
                last_error = f"HTTP {status_code}"
                continue

            body_str = result.get("body", "")
            if not body_str:
                last_error = "empty response"
                continue

            body = json.loads(body_str) if isinstance(body_str, str) else body_str
            models = body.get("models", {})
            if not models or not isinstance(models, dict):
                last_error = "no models in response"
                continue

            quota.groups = _build_antigravity_groups(models)
            return quota

        except (RuntimeError, json.JSONDecodeError) as exc:
            last_error = str(exc)
            continue

    quota.error = last_error or "all endpoints failed"
    return quota


def _build_antigravity_groups(
    models: dict[str, Any],
) -> list[AntigravityModelQuota]:
    """Build grouped quota display from raw models data.

    :param models: Dict of model_id -> model quota data.
    :returns: List of :class:`AntigravityModelQuota` groups.
    """
    # Build a lookup: model_id -> group definition
    model_to_group: dict[str, dict[str, Any]] = {}
    for group in ANTIGRAVITY_GROUPS:
        for mid in group["ids"]:
            model_to_group[mid] = group

    # Aggregate by group: use the lowest remaining fraction
    group_data: dict[str, AntigravityModelQuota] = {}

    for model_id, info in models.items():
        if not isinstance(info, dict):
            continue

        # Quota data is nested under "quotaInfo"
        quota_info = info.get("quotaInfo", {})
        remaining = (
            quota_info.get("remainingFraction", quota_info.get("remaining_fraction"))
            if quota_info
            else info.get("remainingFraction", info.get("remaining_fraction"))
        )
        reset_time = (
            quota_info.get("resetTime", quota_info.get("reset_time", ""))
            if quota_info
            else info.get("resetTime", info.get("reset_time", ""))
        )

        gdef = model_to_group.get(model_id)
        if gdef:
            gid = gdef["id"]
            if gid not in group_data:
                group_data[gid] = AntigravityModelQuota(
                    group_label=gdef["label"],
                    remaining_fraction=None,
                    reset_time="",
                    models=[],
                )
            g = group_data[gid]
            g.models.append(model_id)
            if remaining is not None:
                frac = float(remaining)
                if g.remaining_fraction is None or frac < g.remaining_fraction:
                    g.remaining_fraction = frac
                    g.reset_time = reset_time or g.reset_time
        # else:
        #     # Ungrouped model — show individually
        #     group_data[model_id] = AntigravityModelQuota(
        #         group_label=model_id,
        #         remaining_fraction=float(remaining) if remaining is not None else None,
        #         reset_time=reset_time or "",
        #         models=[model_id],
        #     )

    return sorted(list(group_data.values()), key=lambda x: x.group_label)


# ── Formatting Helpers ───────────────────────────────────────────────────────


def _fmt_reset_abs(seconds: int | None) -> str:
    """Format seconds-until-reset as an absolute datetime string.

    :param seconds: Number of seconds until reset.
    :returns: Formatted string like "2月27日 14:30" in local time, or "".
    """
    if seconds is None or seconds <= 0:
        return "now"
    reset_dt = datetime.now() + timedelta(seconds=seconds)
    return (
        f"{reset_dt.month}月{reset_dt.day}日 {reset_dt.hour:02d}:{reset_dt.minute:02d}"
    )


def _fmt_reset_time(reset_time: str) -> str:
    """Format ISO 8601 reset timestamp as absolute local datetime.

    :param reset_time: ISO 8601 timestamp or empty string.
    :returns: Formatted string like "2月27日 14:30" in local time.
    """
    if not reset_time:
        return ""
    try:
        reset_dt = datetime.fromisoformat(reset_time.replace("Z", "+00:00"))
        local_dt = reset_dt.astimezone()
        now = datetime.now(timezone.utc)
        if (reset_dt - now).total_seconds() <= 0:
            return "resetting"
        return f"{local_dt.month}月{local_dt.day}日 {local_dt.hour:02d}:{local_dt.minute:02d}"
    except (ValueError, TypeError):
        return ""


# ── SwiftBar Output ──────────────────────────────────────────────────────────


def print_codex_section(quotas: list[CodexQuota]) -> None:
    """Print the Codex section of the dropdown menu.

    :param quotas: List of Codex quota objects.
    """
    print(f"🤖 Codex ({len(quotas)} accounts) | size=14 color=#ffffff")

    for q in quotas:
        if q.error:
            print(f"--  ❌ {q.email or 'unknown'} — {q.error} | font=Menlo size=12")
            continue

        # Status
        status_icon = "🔴" if q.limit_reached else "🤖"
        plan = q.plan_type.upper() if q.plan_type else "?"

        # Primary window (5-hour)
        if q.primary_used_pct is not None:
            remaining_pct = 100 - q.primary_used_pct
            reset = _fmt_reset_abs(q.primary_reset_seconds)
            reset_str = f" 🔄{reset}" if reset else ""
            print(f"--  {status_icon} {q.email} [{plan}] | font=Menlo size=12")
            print(f"----  5h window: {remaining_pct}%{reset_str} | font=Menlo size=11")
        else:
            print(f"--  {status_icon} {q.email} [{plan}] | font=Menlo size=12")

        # Secondary window (weekly)
        if q.secondary_used_pct is not None:
            remaining_pct = 100 - q.secondary_used_pct
            reset = _fmt_reset_abs(q.secondary_reset_seconds)
            reset_str = f" 🔄{reset}" if reset else ""
            print(f"----  Weekly: {remaining_pct}%{reset_str} | font=Menlo size=11")


def print_antigravity_section(quotas: list[AntigravityQuota]) -> None:
    """Print the Antigravity section of the dropdown menu.

    :param quotas: List of Antigravity quota objects.
    """
    print(f"🌀 Antigravity ({len(quotas)} accounts) | size=14 color=#ffffff")

    for q in quotas:
        display_name = q.email or "unknown"
        if q.error:
            print(f"--  ❌ {display_name} — {q.error} | font=Menlo size=12")
            continue

        print(f"--  🟢 {display_name} | font=Menlo size=12")

        if not q.groups:
            print("----  No model data | font=Menlo size=11 color=#888888")
            continue

        for g in q.groups:
            if g.remaining_fraction is not None:
                pct = round(g.remaining_fraction * 100)
                reset = _fmt_reset_time(g.reset_time)
                reset_str = f" 🔄{reset}" if reset else ""
                # Color code based on remaining percentage
                color = "#4caf50" if pct > 50 else "#ff9800" if pct > 20 else "#f44336"
                print(
                    f"----  {g.group_label}: {pct}%"
                    f"{reset_str} | font=Menlo size=11 color={color}"
                )
            else:
                print(f"----  {g.group_label}: N/A | font=Menlo size=11 color=#888888")


def print_status_bar(
    codex_quotas: list[CodexQuota],
    ag_quotas: list[AntigravityQuota],
) -> None:
    """Print the SwiftBar status bar title line.

    :param codex_quotas: List of Codex quota data.
    :param ag_quotas: List of Antigravity quota data.
    """
    parts: list[str] = []

    if codex_quotas:
        # Show primary window remaining percentage for first account
        q = codex_quotas[0]
        if q.primary_used_pct is not None:
            remaining = 100 - q.primary_used_pct
            icon = "🔴" if q.limit_reached else "🤖"
            parts.append(f"{icon}C:{remaining}%")
        else:
            parts.append("🤖C:?")

    if ag_quotas:
        # Show lowest remaining fraction across all groups
        q = ag_quotas[0]
        if q.groups:
            fracs = [
                g.remaining_fraction
                for g in q.groups
                if g.remaining_fraction is not None
            ]
            if fracs:
                lowest = round(min(fracs) * 100)
                parts.append(f"🌀A:{lowest}%")
            else:
                parts.append("🌀A:?")
        elif q.error:
            parts.append("🌀A:⚠️")
        else:
            parts.append("🌀A:?")

    title = " ".join(parts) if parts else "📊 Quota"
    print(f"{title} | size=13")


def print_error(message: str) -> None:
    """Print an error state to SwiftBar.

    :param message: Error message to display.
    """
    print("⚠️ Quota | color=red")
    print("---")
    print(f"Error: {message} | color=red")
    print("---")
    print("🔄 Retry | refresh=true")


# ── Main ─────────────────────────────────────────────────────────────────────


def main() -> None:
    """Entry point: fetch auth files, query quotas, render SwiftBar output."""
    if not MANAGEMENT_KEY:
        print_error("CPA_MANAGEMENT_KEY not set")
        sys.exit(0)

    try:
        # Step 1: Get auth files for target providers
        auth_files = get_auth_files()

        if not auth_files:
            print("📊 No accounts | size=13")
            print("---")
            print("No Codex or Antigravity accounts found | color=#888888")
            print("---")
            print(f"⚙️ Management Center | href={BASE_URL}")
            sys.exit(0)

        # Step 2: Query quota for each provider
        codex_quotas: list[CodexQuota] = []
        ag_quotas: list[AntigravityQuota] = []

        for af in auth_files:
            if af.provider == "codex":
                codex_quotas.append(fetch_codex_quota(af))
            elif af.provider == "antigravity":
                ag_quotas.append(fetch_antigravity_quota(af))

        # Step 3: Render output
        print_status_bar(codex_quotas, ag_quotas)
        print("---")
        if codex_quotas:
            print_codex_section(codex_quotas)
        if ag_quotas:
            print_antigravity_section(ag_quotas)

        # Footer
        print("---")
        now_str = datetime.now().strftime("%H:%M:%S")
        print(f"🕐 Updated: {now_str} | size=11 color=#888888")
        print("---")
        print("🔄 Refresh | refresh=true")
        print(f"⚙️ Management Center | href={BASE_URL} size=12")

    except RuntimeError as exc:
        print_error(str(exc))
    except Exception as exc:
        print_error(f"Unexpected: {exc}")

    sys.exit(0)


if __name__ == "__main__":
    main()

#!/usr/bin/python3
"""Native quota summary for the LoveEatCandy CLIProxyAPI quota-bar fork.

Read commands never redeem credits. Consumption requires the separate reset command,
an explicit account, a preview revision, and a durable redemption request UUID.
"""
from __future__ import annotations
import concurrent.futures
import fcntl
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import sys
import time
from datetime import datetime
import uuid

CONFIG = Path(os.environ.get('QUOTA_BAR_CONFIG', Path.home() / '.config/cliproxy-quota-bar/config.json'))
STATE = Path.home() / 'Library/Application Support/Quota Bar'
LOW_QUOTA = 10


def timestamp(value):
    if isinstance(value, (int, float)) and math.isfinite(value):
        return float(value)
    if isinstance(value, str):
        try:
            return datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
        except ValueError:
            pass
    return None


def number(value):
    return value if type(value) in (int, float) and math.isfinite(value) else None


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.with_suffix('.tmp')
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        json.dump(value, f, allow_nan=False)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def client(config):
    os.environ['CPA_ENV_FILE'] = str(Path(config['credentials_file']).expanduser())
    os.environ['CPA_BASE_URL'] = config['base_url']
    spec = importlib.util.spec_from_file_location('quota_client', Path(__file__).with_name('quota.5m.py'))
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def request(api, auth, path, method='GET', data=None):
    payload = {'authIndex': auth.auth_index, 'method': method,
               'url': 'https://chatgpt.com/backend-api/wham/' + path,
               'header': {**api.CODEX_REQUEST_HEADERS, 'Chatgpt-Account-Id': auth.chatgpt_account_id,
                          'Accept': 'application/json', 'OpenAI-Beta': 'codex-1', 'Originator': 'Codex Desktop'}}
    if data is not None:
        payload['data'] = json.dumps(data)
    # A failed consume response may still have spent the credit. Never auto-retry it.
    result = api._make_request(api.MANAGEMENT_API + '/api-call', method='POST', data=payload,
                               max_retries=1 if method == 'POST' else 2)
    if not 200 <= result.get('status_code', 0) < 300:
        raise RuntimeError('Sign in again through the proxy dashboard (HTTP 401).' if result.get('status_code') == 401 else 'Provider returned HTTP ' + str(result.get('status_code', '?')))
    body = result.get('body')
    parsed = json.loads(body) if isinstance(body, str) and body else body
    if method == 'GET' and not isinstance(parsed, dict):
        raise RuntimeError('Provider returned an unreadable response')
    return parsed


def read_account(api, auth, name):
    row = {'id': name, 'name': name, 'remaining': None, 'weeklyReset': None,
           'available': None, 'applicable': None, 'credits': [], 'error': None,
           'creditsError': None, 'authIndex': auth.auth_index if auth else None}
    if auth is None:
        row['error'] = 'Account missing or disabled'
        return row
    try:
        usage = request(api, auth, 'usage')
        for window in (usage.get('rate_limit') or {}).values():
            if not isinstance(window, dict):
                continue
            duration, used = number(window.get('limit_window_seconds')), number(window.get('used_percent'))
            if duration and duration > 86400 and used is not None and 0 <= used <= 100:
                row['remaining'] = 100 - used
                row['weeklyReset'] = timestamp(window.get('reset_at'))
                if row['weeklyReset'] is None and number(window.get('reset_after_seconds')) is not None:
                    row['weeklyReset'] = time.time() + window['reset_after_seconds']
                break
        if row['remaining'] is None:
            row['error'] = 'Weekly quota unavailable'
        counts = usage.get('rate_limit_reset_credits') or {}
        row['available'] = number(counts.get('available_count'))
        row['applicable'] = number(counts.get('applicable_available_count'))
    except RuntimeError as exc:
        row['error'] = str(exc)
    except Exception:
        row['error'] = 'Could not read quota. Check the connection and refresh.'
    try:
        data = request(api, auth, 'rate-limit-reset-credits')
        row['available'] = number(data.get('available_count'))
        if not isinstance(data.get('credits'), list):
            raise ValueError('Missing credits list')
        for credit in data['credits']:
            expiry = timestamp(credit.get('expires_at'))
            if (credit.get('reset_type') != 'codex_rate_limits' or credit.get('status') != 'available'
                    or expiry is None or expiry <= time.time()):
                continue
            row['credits'].append({'id': str(credit.get('id', '')), 'expires': expiry,
                                  'granted': timestamp(credit.get('granted_at')),
                                  'supported': credit.get('is_supported_by_plan') is True})
        row['credits'].sort(key=lambda c: (c['expires'], c['granted'] or 0, c['id']))
    except Exception:
        row['creditsError'] = 'Reset details unavailable'
    return row


def read_claude(api, auth):
    row = {'id': auth.name, 'name': auth.email or auth.label or auth.name,
           'remaining': None, 'weeklyReset': None, 'sessionRemaining': None,
           'sessionReset': None, 'error': None}
    try:
        result = api._make_request(api.MANAGEMENT_API + '/api-call', method='POST', data={
            'authIndex': auth.auth_index, 'method': 'GET',
            'url': 'https://api.anthropic.com/api/oauth/usage',
            'header': {'Authorization': 'Bearer $TOKEN$', 'anthropic-beta': 'oauth-2025-04-20',
                       'Accept': 'application/json'}}, max_retries=1)
        if result.get('status_code') != 200:
            raise RuntimeError('Sign in again through the proxy dashboard (HTTP 401).' if result.get('status_code') == 401
                               else 'Claude quota unavailable (HTTP ' + str(result.get('status_code', '?')) + ').')
        body = result.get('body')
        usage = json.loads(body) if isinstance(body, str) else body
        for key, remaining, reset in [('seven_day', 'remaining', 'weeklyReset'),
                                      ('five_hour', 'sessionRemaining', 'sessionReset')]:
            window = usage.get(key) or {}
            used = number(window.get('utilization'))
            if used is not None and 0 <= used <= 100:
                row[remaining] = 100 - used
                row[reset] = timestamp(window.get('resets_at'))
        if row['remaining'] is None:
            row['error'] = 'Weekly quota unavailable'
    except RuntimeError as exc:
        row['error'] = str(exc)
    except Exception:
        row['error'] = 'Could not read Claude quota. Check the connection and refresh.'
    return row


def reason(row, now):
    if row['error'] or row['creditsError']:
        return 'Refresh to check availability'
    if row['remaining'] is None:
        return 'Weekly quota unknown'
    if row['remaining'] > LOW_QUOTA:
        return 'Keep using the remaining quota'
    if row['available'] is None or row['available'] <= 0 or not row['credits'] or not any(c['supported'] for c in row['credits']):
        return 'No usable resets available'
    if row['applicable'] is None or row['applicable'] <= 0:
        return 'OpenAI does not allow a reset yet'
    if row['weeklyReset'] is not None and row['weeklyReset'] - now <= 3600:
        return 'Weekly quota renews within an hour; wait for it'
    return None


def snapshot(api, config):
    files = api.get_auth_files()
    accounts = config['accounts']
    if not accounts or len({a['name'] for a in accounts}) != len(accounts) or len({a['email'] for a in accounts}) != len(accounts):
        raise RuntimeError('Account configuration must contain unique names and emails')
    by_email = {}
    for auth in files:
        if auth.provider == 'codex' and not auth.disabled:
            by_email.setdefault(auth.email, []).append(auth)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as workers:
        futures = [workers.submit(read_account, api, by_email[a['email']][0]
                   if len(by_email.get(a['email'], [])) == 1 else None, a['name']) for a in accounts]
        rows = [f.result() for f in futures]
    now = time.time()
    for row in rows:
        row['holdReason'] = reason(row, now)
        row['eligible'] = row['holdReason'] is None
        material = [row['authIndex'], row['remaining'], row['weeklyReset'], row['applicable'], row['available'], row['credits'], row['eligible']]
        row['revision'] = hashlib.sha256(json.dumps(material, sort_keys=True).encode()).hexdigest()
    eligible = [r for r in rows if r['eligible']]
    eligible.sort(key=lambda r: (min(c['expires'] for c in r['credits'] if c['supported']), r['remaining'], r['id']))
    known = [r['remaining'] for r in rows if r['remaining'] is not None]
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as workers:
        claude = list(workers.map(lambda auth: read_claude(api, auth),
                                 [a for a in files if a.provider == 'claude' and not a.disabled]))
    result = {'updated': now, 'accounts': rows, 'total': sum(known) if known else None,
              'knownAccounts': len(known), 'claude': claude, 'capacity': 100 * len(rows), 'recommended': eligible[0]['id'] if eligible else None,
              'dashboard': config.get('dashboard_url', config['base_url'] + '/management.html'),
              'pending': None}
    pending = STATE / 'pending-reset.json'
    if pending.exists():
        record = json.loads(pending.read_text())
        if record.get('state') == 'uncertain':
            result['pending'] = 'A previous reset has an uncertain result. Check the dashboard before another reset. See pending-reset.json.'
            result['recommended'] = None
            for row in rows:
                row['eligible'] = False
                row['holdReason'] = 'Resolve the previous reset first'
    return result


def reset(api, config, command):
    account_id = command.get('account')
    request_id = str(uuid.UUID(command['requestID']))
    pending = STATE / 'pending-reset.json'
    if pending.exists():
        previous = json.loads(pending.read_text())
        if previous.get('state') == 'uncertain' or previous.get('requestID') == request_id:
            raise RuntimeError('This reset was already submitted or its result is uncertain. Check the dashboard.')
    current = snapshot(api, config)
    row = next((r for r in current['accounts'] if r['id'] == account_id), None)
    if not row or not row['eligible'] or row['revision'] != command.get('revision'):
        raise RuntimeError('Account or reset availability changed. Review a fresh preview before confirming.')
    files = api.get_auth_files()
    expected_email = next(a['email'] for a in config['accounts'] if a['name'] == account_id)
    auth = next((a for a in files if a.auth_index == row['authIndex'] and a.email == expected_email and not a.disabled), None)
    if auth is None:
        raise RuntimeError('Account changed. Refresh first.')
    record = {'requestID': request_id, 'account': account_id, 'state': 'uncertain', 'at': time.time()}
    save(pending, record)
    request(api, auth, 'rate-limit-reset-credits/consume', method='POST', data={'redeem_request_id': request_id})
    record['state'] = 'completed'
    save(pending, record)
    # Clear only the proxy's cooldown after the upstream has confirmed redemption.
    warning = None
    try:
        api._make_request(api.MANAGEMENT_API + '/reset-quota', method='POST',
                          data={'auth_index': auth.auth_index}, max_retries=1)
    except Exception:
        warning = 'Reset succeeded. The proxy cooldown could not be cleared; check the dashboard.'
    return {'message': warning or ('One reset applied to ' + account_id + '.'), 'snapshot': snapshot(api, config)}


def main():
    config = json.loads(CONFIG.read_text())
    api = client(config)
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    with open(STATE / 'operation.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        operation = sys.argv[1] if len(sys.argv) > 1 else 'summary'
        if operation == 'summary':
            result = snapshot(api, config)
        elif operation == 'reset':
            result = reset(api, config, json.load(sys.stdin))
        else:
            raise RuntimeError('Unknown command')
        print(json.dumps(result, allow_nan=False))


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        # Do not expose HTTP bodies or credentials through the UI or logs.
        message = str(exc) if isinstance(exc, RuntimeError) else 'Could not load the proxy. Check the local connection and configuration.'
        print(json.dumps({'error': message}))
        sys.exit(1)

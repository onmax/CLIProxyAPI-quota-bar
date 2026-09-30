"""Offline policy checks. Not executed during installation at the user's request.

Run manually with /usr/bin/python3 check_policy.py. No network or reset calls.
"""
from pool import reason, timestamp
now = 1788595000
row = {'error': None, 'creditsError': None, 'remaining': 0, 'weeklyReset': now + 86400,
       'available': 1, 'applicable': 1, 'credits': [{'supported': True}]}
assert reason(row, now) is None
assert reason({**row, 'remaining': 75}, now) == 'Keep using the remaining quota'
assert reason({**row, 'remaining': 7, 'applicable': 0}, now) == 'OpenAI does not allow a reset yet'
assert reason({**row, 'weeklyReset': now + 60}, now) == 'Weekly quota renews within an hour; wait for it'
assert reason({**row, 'creditsError': 'offline'}, now) == 'Refresh to check availability'
assert timestamp('invalid') is None
print('Offline policy checks passed')

# Provider parsing preserves unknown values and never mixes Claude into reset eligibility.
import json
from types import SimpleNamespace
from pool import read_claude, read_account
class FakeAPI:
    MANAGEMENT_API = 'test'
    CODEX_REQUEST_HEADERS = {}
    def _make_request(self, *args, **kwargs):
        return self.response
api = FakeAPI()
auth = SimpleNamespace(name='claude-test', email='test', label='', auth_index='1', chatgpt_account_id='2')
api.response = {'status_code': 200, 'body': json.dumps({'seven_day': {'utilization': 51}, 'five_hour': {'utilization': 4}})}
row = read_claude(api, auth)
assert row['remaining'] == 49 and row['sessionRemaining'] == 96 and row['error'] is None
api.response = {'status_code': 401}
assert 'Sign in again' in read_claude(api, auth)['error']
row = read_account(api, auth, 'outlook')
assert row['remaining'] is None and 'Sign in again' in row['error']
assert reason(row, now) == 'Refresh to check availability'
print('Provider checks passed')

from unittest.mock import patch
from pool import snapshot
accounts = [SimpleNamespace(**{**vars(auth), 'provider': 'codex', 'disabled': False, 'email': email})
            for email in ['known', 'offline']]
rows = [{'id': email, 'name': email, 'authIndex': email, 'remaining': remaining,
         'weeklyReset': None, 'error': None if remaining is not None else 'offline',
         'creditsError': None, 'available': None, 'applicable': None, 'credits': [], 'weight': 1}
        for email, remaining in [('known', 73), ('offline', None)]]
api.get_auth_files = lambda: accounts
with patch('pool.read_account', side_effect=lambda api, auth, name: next(r.copy() for r in rows if r['name'] == name)):
    result = snapshot(api, {'accounts': [{'name': a.email, 'email': a.email} for a in accounts], 'base_url': 'test'})
assert result['total'] == 73 and result['knownAccounts'] == 1 and result['capacity'] == 200
assert result['recommended'] is None
print('Partial pool check passed')

# Four full 20x accounts plus one full 1x account have 405% capacity.
weighted_rows = [{**rows[0], 'name': str(i), 'remaining': 100, 'weight': weight}
                 for i, weight in enumerate([1, 1, 1, 1, 0.05])]
with patch('pool.read_account', side_effect=weighted_rows):
    result = snapshot(api, {'accounts': [{'name': str(i), 'email': str(i)} for i in range(5)], 'base_url': 'test'})
assert result['total'] == 405 and result['capacity'] == 405
print('Plan weighting check passed')

usage_response = {'status_code': 200, 'body': {'seven_day': {'utilization': 51}}}
for organization, weight in [({'rate_limit_tier': 'default_claude_max_20x'}, 1),
                             ({'rate_limit_tier': 'default_claude_max_5x'}, 0.25),
                             ({'seat_tier': 'team_standard'}, 0.05), ({}, None)]:
    with patch.object(api, '_make_request', side_effect=[usage_response, {'status_code': 200, 'body': {'organization': organization}}]):
        assert read_claude(api, auth)['weight'] == weight
print('Claude plan checks passed')

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

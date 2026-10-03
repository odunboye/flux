"""Run the existing wire probes as assertions against the owned runtime."""
import socket_suite as suite

suite.adversarial()
failures = [p['name'] for p in suite.RESULTS['probes'] if p['status_check'] is False]
failures.extend(p['name'] for p in suite.RESULTS['probes'] if p.get('body_present'))
shutdown = suite.RESULTS['protocol_shutdown']
if shutdown['forced'] or shutdown['exit_code'] != 0:
    failures.append('clean shutdown')
print('Results:', suite.OUT, flush=True)
assert not failures, failures
print('PASS owned-runtime HTTP protocol and shutdown checks', flush=True)

#!/usr/bin/env python3
"""GitHub Actions -tyonkulkujen rakennetarkistus (Tests/Invoke-Checks.ps1 ajaa).

YAML voi olla kelvollista mutta GitHubille rikki: esim. tapahtuma
(schedule/push) sisennetty vahingossa toisen avaimen alle. GitHub ei
silloin aja tyonkulkua lainkaan, ja virhe nakyy vasta pushin jalkeen.
"""
import glob, os, sys
try:
    import yaml
except ImportError:
    print('  VAROITUS PyYAML puuttuu, tyonkulkuja ei tarkisteta')
    sys.exit(0)

TOP = {'name', 'run-name', 'on', 'permissions', 'env', 'defaults', 'concurrency', 'jobs'}
EVENTS = {'push', 'pull_request', 'pull_request_target', 'workflow_dispatch', 'schedule',
          'workflow_call', 'workflow_run', 'release', 'repository_dispatch', 'merge_group'}
JOB = {'name', 'runs-on', 'needs', 'if', 'steps', 'env', 'timeout-minutes', 'strategy', 'permissions',
       'concurrency', 'outputs', 'defaults', 'continue-on-error', 'services', 'container', 'environment'}

def check(path):
    errs = []
    with open(path, encoding='utf-8') as f:
        wf = yaml.safe_load(f)
    if not isinstance(wf, dict):
        return ['ei ole YAML-kartta']
    # PyYAML (YAML 1.1) lukee avaimen "on" totuusarvoksi True.
    if True in wf:
        wf['on'] = wf.pop(True)
    for k in wf:
        if k not in TOP:
            errs.append('tuntematon ylatason avain: %r' % k)
    on = wf.get('on')
    if on is None:
        errs.append('on-osio puuttuu')
    elif isinstance(on, dict):
        for ev, conf in on.items():
            if ev not in EVENTS:
                errs.append('tuntematon tapahtuma: %r' % ev)
            if ev == 'schedule' and not (isinstance(conf, list) and all('cron' in c for c in conf)):
                errs.append('schedule: odotettiin lista cron-riveja')
    conc = wf.get('concurrency')
    if isinstance(conc, dict):
        for k in conc:
            if k not in ('group', 'cancel-in-progress'):
                errs.append('concurrency: tuntematon avain %r (sisennysvirhe?)' % k)
    jobs = wf.get('jobs') or {}
    if not jobs:
        errs.append('ei yhtaan tyota')
    for name, job in jobs.items():
        for k in job:
            if k not in JOB:
                errs.append('%s: tuntematon avain %r' % (name, k))
        if 'runs-on' not in job:
            errs.append('%s: runs-on puuttuu' % name)
        needs = job.get('needs')
        for n in ([needs] if isinstance(needs, str) else (needs or [])):
            if n not in jobs:
                errs.append('%s: needs viittaa puuttuvaan tyohon %r' % (name, n))
        for i, st in enumerate(job.get('steps') or []):
            if ('uses' in st) == ('run' in st):
                errs.append('%s: vaihe %d: tasan yksi uses tai run' % (name, i + 1))
    return errs

def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    files = sorted(glob.glob(os.path.join(root, '.github', 'workflows', '*.yml')))
    bad = 0
    for f in files:
        errs = check(f)
        name = os.path.basename(f)
        if errs:
            bad += 1
            for e in errs:
                print('  VIRHE %s: %s' % (name, e))
        else:
            print('  OK    %s' % name)
    sys.exit(1 if bad else 0)

if __name__ == '__main__':
    main()

#!/usr/bin/env python3
r"""Counts Porthole downloads from the log that deploy/nginx-porthole.conf writes.

On the server, once (Python 3.6 or later, nothing to install):
    sudo install -D -m 755 download-stats.py /opt/porthole/download-stats.py
    sudo mkdir -p /var/lib/porthole
    echo '5 0 * * * root python3 /opt/porthole/download-stats.py --db /var/lib/porthole/downloads.json /var/log/nginx/porthole-downloads.log* >/dev/null' \
      | sudo tee /etc/cron.d/porthole-downloads
  The nightly run folds the logs into running daily totals (no IP addresses in them), so the
  counts survive after logrotate deletes old logs.

To see the numbers:
    python3 /opt/porthole/download-stats.py --db /var/lib/porthole/downloads.json /var/log/nginx/porthole-downloads.log*
  or copy the logs to your Mac and run:  scripts/download-stats.py porthole-downloads.log*

How it counts
  - A download is one visitor (IP address + browser) getting one zip on one day. Retries,
    resumed downloads and download managers that fetch a file in pieces all count once.
  - It needs a GET answered 200, or 206 for a range that starts at byte 0. HEAD requests,
    errors, requests without a browser name and well-known crawlers are left out.
  - "completed": the server sent that visitor the whole file that day (in one go or in pieces).
    It cannot see whether the browser kept it, and a 1.3 MB file fits in network buffers, so
    a download cancelled at once may still count as completed: read it as an upper bound.
  - Days run on Beijing time (UTC+8) unless --tz says otherwise.
"""
import argparse
import gzip
import json
import os
import re
import sys
import tempfile
from collections import defaultdict
from datetime import datetime, timedelta, timezone

ZIP = re.compile(r'^/downloads/(Porthole-([^/]+)\.zip)$')
BOTS = re.compile(r'bot|crawl|spider|slurp|scan|monitor|preview|headless|lighthouse|python|go-http|'
                  r'okhttp|java/|libwww|httpclient|axios|node-fetch', re.I)
DB_FORMAT = 1


def parse_offset(text):
    """'+08:00', '-05:30' or 'Z' -> timezone"""
    if text in ('Z', '+00:00', ''):
        return timezone.utc
    m = re.fullmatch(r'([+-])(\d{2}):?(\d{2})', text)
    if not m:
        raise ValueError('not a UTC offset: %r' % text)
    minutes = int(m.group(2)) * 60 + int(m.group(3))
    return timezone(timedelta(minutes=-minutes if m.group(1) == '-' else minutes))


def day_of(stamp, tz):
    """nginx $time_iso8601 ('2026-11-27T10:15:30+08:00') -> 'YYYY-MM-DD' in tz"""
    t = datetime.strptime(stamp[:19], '%Y-%m-%dT%H:%M:%S').replace(tzinfo=parse_offset(stamp[19:]))
    return t.astimezone(tz).strftime('%Y-%m-%d')


def open_log(path):
    if path.endswith('.gz'):
        return gzip.open(path, 'rt', encoding='utf-8', errors='replace')
    return open(path, encoding='utf-8', errors='replace')


def read_logs(paths, tz, ignore_ips):
    """-> (visits, sizes, lines seen for downloads, unreadable lines)

    visits: (day, file, ip, ua) -> [started, bytes sent, got the whole file in one response]
    sizes:  file -> size, learnt from responses that sent the whole file
    """
    visits, sizes = {}, {}
    seen = bad = 0
    for path in paths:
        with open_log(path) as log:
            for line in log:
                line = line.strip()
                if not line:
                    continue
                try:
                    r = json.loads(line)
                    m = ZIP.match(r.get('uri') or '')
                    if not m:
                        continue
                    seen += 1
                    status = int(r.get('status') or 0)
                    ua = r.get('ua') or ''
                    ip = r.get('ip') or ''
                    if r.get('method') != 'GET' or status not in (200, 206):
                        continue
                    if not ua or BOTS.search(ua) or ip in ignore_ips:
                        continue
                    name = m.group(1)
                    sent = int(r.get('bytes') or 0)
                    whole = status == 200 and r.get('done') == 'OK'
                    starts = status == 200 or (r.get('range') or '').replace(' ', '').startswith('bytes=0-')
                    if whole:
                        sizes[name] = max(sizes.get(name, 0), sent)
                    v = visits.setdefault((day_of(r['time'], tz), name, ip, ua), [False, 0, False])
                    v[0] = v[0] or starts
                    v[1] += sent
                    v[2] = v[2] or whole
                except (ValueError, KeyError, TypeError):
                    bad += 1
    return visits, sizes, seen, bad


def count(visits, sizes):
    """-> {day: {file: [downloads, completed]}}"""
    days = defaultdict(dict)
    for (day, name, _ip, _ua), (started, sent, whole) in visits.items():
        if not started:
            continue
        size = sizes.get(name)
        done = whole or (size is not None and sent >= size)
        c = days[day].setdefault(name, [0, 0])
        c[0] += 1
        c[1] += 1 if done else 0
    return days


def load_db(path, tz_text):
    if not os.path.exists(path):
        return {'format': DB_FORMAT, 'tz': tz_text, 'sizes': {}, 'days': {}}
    with open(path, encoding='utf-8') as f:
        db = json.load(f)
    if db.get('tz') != tz_text:
        sys.exit('%s counts days in UTC%s; run with --tz %s (or use another --db file).'
                 % (path, db.get('tz'), db.get('tz')))
    return db


def save_db(path, db):
    folder = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(prefix='.downloads-', dir=folder)
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        json.dump(db, f, indent=1, sort_keys=True)
        f.write('\n')
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def merge(db, days):
    """A day's counts only grow as more of its log is read, so the larger number is kept. That
    makes it safe to run on overlapping logs, and on a day whose start was already rotated away."""
    for day, files in days.items():
        known = db['days'].setdefault(day, {})
        for name, (n, done) in files.items():
            old = known.get(name, [0, 0])
            known[name] = [max(old[0], n), max(old[1], done)]


def version_key(name):
    v = ZIP.match('/downloads/' + name).group(2)
    return [int(p) if p.isdigit() else -1 for p in re.split(r'[.+-]', v)]


def version_of(name):
    return ZIP.match('/downloads/' + name).group(2)


def report(days, today, tz_text, show_days):
    files = sorted({f for d in days.values() for f in d}, key=version_key, reverse=True)
    if not files:
        print('No downloads counted yet.')
        return
    first = min(days)
    print('Porthole downloads, %s to %s (days in UTC%s)\n' % (first, today, tz_text))

    def since(n):
        return (datetime.strptime(today, '%Y-%m-%d') - timedelta(days=n - 1)).strftime('%Y-%m-%d')

    w7, w30 = since(7), since(30)
    rows = []
    for name in files + [None]:
        tot = done = d7 = d30 = 0
        for day, per in days.items():
            for f, (n, c) in per.items():
                if name is not None and f != name:
                    continue
                tot += n
                done += c
                d7 += n if day >= w7 else 0
                d30 += n if day >= w30 else 0
        rows.append((version_of(name) if name else 'all', tot, done, d7, d30))
    if len(files) == 1:
        rows.pop()   # "all" would repeat the only row
    print('%-12s %10s %10s %12s %13s' % ('version', 'downloads', 'completed', 'last 7 days', 'last 30 days'))
    for r in rows:
        print('%-12s %10d %10d %12d %13d' % r)

    shown = files[:6]
    print('\n%-12s %6s' % ('day', 'all') + ''.join(' %9s' % version_of(f)[:9] for f in shown))
    for i in range(show_days):
        day = since(i + 1)
        if day < first:
            break
        per = days.get(day, {})
        print('%-12s %6d' % (day, sum(n for n, _ in per.values()))
              + ''.join(' %9d' % per.get(f, [0, 0])[0] for f in shown))


def main():
    ap = argparse.ArgumentParser(description='Count Porthole downloads from the nginx download log.',
                                 epilog='See the top of this file for how the counting works.')
    ap.add_argument('logs', nargs='*', help='porthole-downloads.log files (.gz is fine)')
    ap.add_argument('--db', help='JSON file with the running daily totals: logs are merged into it')
    ap.add_argument('--tz', default='+08:00', help='UTC offset the days are counted in (default +08:00)')
    ap.add_argument('--days', type=int, default=14, help='days in the daily table (default 14)')
    ap.add_argument('--ignore-ip', action='append', default=[], metavar='IP',
                    help='leave out requests from this address, such as your own (repeatable)')
    ap.add_argument('--json', action='store_true', help='print the daily totals as JSON instead')
    args = ap.parse_args()
    if not args.logs and not args.db:
        ap.error('give log files, --db, or both')
    tz = parse_offset(args.tz)

    db = load_db(args.db, args.tz) if args.db else {'format': DB_FORMAT, 'tz': args.tz, 'sizes': {}, 'days': {}}
    visits, sizes, seen, bad = read_logs(args.logs, tz, set(args.ignore_ip))
    for name, size in db['sizes'].items():
        sizes[name] = max(size, sizes.get(name, 0))
    merge(db, count(visits, sizes))
    db['sizes'] = sizes
    if args.db:
        save_db(args.db, db)

    if bad:
        print('(skipped %d unreadable log line%s)' % (bad, '' if bad == 1 else 's'), file=sys.stderr)
    if args.logs and not seen:
        print('(no requests for /downloads/*.zip in these logs; is this the porthole-downloads.log '
              'written by deploy/nginx-porthole.conf?)', file=sys.stderr)

    if args.json:
        json.dump(db, sys.stdout, indent=1, sort_keys=True)
        print()
    else:
        report(db['days'], datetime.now(tz).strftime('%Y-%m-%d'), args.tz, args.days)


if __name__ == '__main__':
    main()

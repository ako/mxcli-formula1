#!/usr/bin/env python3
"""
Score the shipped forecaster SQL against races whose results are known.

This drives `forecast.sql` -- the same text the model executes through the
External Database Connector, with `{param}` placeholders filled in the same
way -- rather than a copy of it. A backtest of a paraphrase measures the
paraphrase.

    python3 spikes/forecaster/backtest.py            # both archived races
    python3 spikes/forecaster/backtest.py 11342 --at 21
"""
import argparse, gzip, json, os, time
import duckdb

HERE = os.path.dirname(os.path.abspath(__file__))
SQL = os.path.join(HERE, 'forecast.sql')
ARCHIVE = 'data/openf1'


def payload(key, ep):
    with gzip.open(f'{ARCHIVE}/{key}/{ep}.json.gz') as fh:
        return fh.read().decode()


def run(con, key, cut_lap, total_laps):
    con.execute("create or replace table _p as select ? a, ? b, ? c",
                [payload(key, 'laps'), payload(key, 'stints'), payload(key, 'pit')])
    q = (open(SQL).read()
         .replace('{lapsJson}', '(select a from _p)')
         .replace('{stintsJson}', '(select b from _p)')
         .replace('{pitJson}', '(select c from _p)')
         .replace('{sessionKey}', f"'{key}'")
         .replace('{cutLap}', str(cut_lap))
         .replace('{totalLaps}', str(total_laps)))
    rows = con.execute(q).fetchall()
    cols = [d[0] for d in con.description]
    return [dict(zip(cols, r)) for r in rows]


def truth(key):
    with gzip.open(f'{ARCHIVE}/{key}/session_result.json.gz') as fh:
        res = json.load(fh)
    fin = sorted([r for r in res if r['position'] is not None],
                 key=lambda r: r['position'])
    total = max(r['number_of_laps'] for r in res if r['number_of_laps'])
    return fin, total


def _rank(vals):
    order = sorted(range(len(vals)), key=lambda i: vals[i])
    out = [0] * len(vals)
    for p, i in enumerate(order):
        out[i] = p + 1
    return out


def score(pred, act):
    apos = {a['driver_number']: a['position'] for a in act if not a['dnf']}
    m = [p for p in pred if p['driverNumber'] in apos]
    n = len(m)
    if n < 5:
        return None
    pr = _rank([p['meanPosition'] for p in m])
    ar = _rank([apos[p['driverNumber']] for p in m])
    d2 = sum((pr[i] - ar[i]) ** 2 for i in range(n))
    rho = 1 - 6 * d2 / (n * (n * n - 1))
    winner = act[0]['driver_number']
    brier = sum((p['pWin'] - (1.0 if p['driverNumber'] == winner else 0.0)) ** 2
                for p in pred) / len(pred)
    mae = sum(abs(p['meanPosition'] - apos[p['driverNumber']]) for p in m) / n
    return dict(rho=round(rho, 3), mae=round(mae, 2),
                winner=pred[0]['driverNumber'] == winner,
                podium=len({p['driverNumber'] for p in pred[:3]}
                           & {a['driver_number'] for a in act[:3]}),
                brier=round(brier, 4))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('session', nargs='?')
    ap.add_argument('--at', type=int, default=0)
    a = ap.parse_args()
    con = duckdb.connect()

    if a.session:
        act, total = truth(a.session)
        t = time.time()
        p = run(con, a.session, a.at, total)
        dt = (time.time() - t) * 1000
        print(f'{"car":>4} {"lap":>4} {"left":>5} {"mean":>6} {"med":>4} {"10-90":>7} '
              f'{"P(win)":>7} {"P(pod)":>7} {"stop":>5} {"laps":>5}')
        for r in p:
            print(f'{r["driverNumber"]:>4} {r["lapNow"]:>4} {r["lapsRemaining"]:>5} '
                  f'{r["meanPosition"]:>6} {r["medianPosition"]:>4} '
                  f'{str(r["bestCase"])+"-"+str(r["worstCase"]):>7} '
                  f'{r["pWin"]:>7} {r["pPodium"]:>7} {r["stopsLeft"]:>5} {r["lapsUsed"]:>5}')
        print(f'\n{dt:.0f} ms | deg={p[0]["degPerLap"]} pitloss={p[0]["pitLoss"]}')
        print('actual  :', ' '.join(str(x['driver_number']) for x in act[:10]))
        print('forecast:', ' '.join(str(r['driverNumber']) for r in p[:10]))
        print('score   :', score(p, act))
        return

    for key in ('11342', '11348'):
        act, total = truth(key)
        print(f'\n=== session {key} -- {total} laps ===')
        print(f'{"lap":>5} {"rho":>7} {"MAE":>5} {"win":>4} {"pod":>4} {"brier":>7}')
        for L in [2, 4, 6, 8, 10] + list(range(15, total, 5)):
            if L >= total:
                break
            s = score(run(con, key, L, total), act)
            if s:
                print(f'{L:>5} {s["rho"]:>7} {s["mae"]:>5} '
                      f'{"Y" if s["winner"] else "-":>4} {str(s["podium"])+"/3":>4} '
                      f'{s["brier"]:>7}')


if __name__ == '__main__':
    main()

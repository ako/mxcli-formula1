#!/usr/bin/env python3
"""
Turn forecast.sql into the string literal that goes in the MDL query.

The SQL is kept in one file so the backtest and the model run the same text.
This does the two mechanical things MDL needs -- strip the comments, double the
single quotes -- so the two never drift by hand.

    python3 spikes/forecaster/embed.py > /tmp/fragment.txt
"""
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sql = open(os.path.join(HERE, 'forecast.sql')).read()
sql = re.sub(r'/\*.*?\*/', '', sql, flags=re.S)          # comments
sql = re.sub(r'\n{2,}', '\n', sql)
sql = '\n'.join(l.rstrip() for l in sql.splitlines() if l.strip())
sys.stdout.write(sql.replace("'", "''"))

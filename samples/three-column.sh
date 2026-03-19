#!/usr/bin/env tpane
# ┌──────────────┬──────────────┬──────────────┐
# │     api      │   worker     │    redis     │
# ├──────────────┼──────────────┼──────────────┤
# │   frontend   │    queue     │    logs      │
# └──────────────┴──────────────┴──────────────┘

api()      { while :; do echo api; sleep 1; done; }
worker()   { while :; do echo worker; sleep 1; done; }
redis()    { while :; do echo redis; sleep 1; done; }
frontend() { while :; do echo frontend; sleep 1; done; }
queue()    { while :; do echo queue; sleep 1; done; }
logs()     { while :; do echo logs; sleep 1; done; }

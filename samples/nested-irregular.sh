#!/usr/bin/env tpane
# ┌──────────────────────┬──────────────────────┐
# │        api           │        worker        │
# │                      ├──────────────┬───────┤
# │                      │    queue     │ logs  │
# ├──────────────────────┼──────────────┴───────┤
# │       frontend       │        shell         │
# └──────────────────────┴──────────────────────┘

api()      { while :; do echo api; sleep 1; done; }
worker()   { while :; do echo worker; sleep 1; done; }
queue()    { while :; do echo queue; sleep 1; done; }
logs()     { while :; do echo logs; sleep 1; done; }
frontend() { while :; do echo frontend; sleep 1; done; }
shell()    { while :; do echo shell; sleep 1; done; }

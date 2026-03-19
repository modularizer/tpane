#!/usr/bin/env bash
# ┌──────────────┬──────────────┐
# │     api      │    worker    │
# ├──────────────┼──────────────┤
# │     logs     │    shell     │
# └──────────────┴──────────────┘

api()    { while :; do echo api; sleep 1; done; }
worker() { while :; do echo worker; sleep 1; done; }
logs()   { while :; do echo logs; sleep 1; done; }
shell()  { while :; do echo shell; sleep 1; done; }

tpane

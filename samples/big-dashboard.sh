#!/usr/bin/env bash
# ┌──────────────────────┬──────────────┬──────────────┐
# │                      │   metrics    │   alerts     │
# │       main           ├──────────────┼──────────────┤
# │                      │    logs      │   events     │
# ├──────────┬───────────┴──────────────┴──────────────┤
# │  deploy  │                shell                    │
# └──────────┴─────────────────────────────────────────┘

main()    { while :; do echo main; sleep 1; done; }
metrics() { while :; do echo metrics; sleep 1; done; }
alerts()  { while :; do echo alerts; sleep 1; done; }
logs()    { while :; do echo logs; sleep 1; done; }
events()  { while :; do echo events; sleep 1; done; }
deploy()  { while :; do echo deploy; sleep 1; done; }
shell()   { while :; do echo shell; sleep 1; done; }

tpane

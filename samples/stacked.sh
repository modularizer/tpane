#!/usr/bin/env bash
# ┌──────────────────────────────┐
# │           server             │
# ├──────────────────────────────┤
# │           logs               │
# ├──────────────────────────────┤
# │           shell              │
# └──────────────────────────────┘

server() { while :; do echo server; sleep 1; done; }
logs()   { while :; do echo logs; sleep 1; done; }
shell()  { while :; do echo shell; sleep 1; done; }

tpane

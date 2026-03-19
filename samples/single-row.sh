#!/usr/bin/env tpane
# ┌──────────┬──────────┬──────────┬──────────┐
# │   app    │  worker  │  cache   │  shell   │
# └──────────┴──────────┴──────────┴──────────┘

app()    { while :; do echo app; sleep 1; done; }
worker() { while :; do echo worker; sleep 1; done; }
cache()  { while :; do echo cache; sleep 1; done; }
shell()  { while :; do echo shell; sleep 1; done; }

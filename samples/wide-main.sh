#!/usr/bin/env bash
# ┌────────────────────────────────────┬──────────────┐
# │                                    │    tests     │
# │              editor                ├──────────────┤
# │                                    │    shell     │
# └────────────────────────────────────┴──────────────┘

editor() { while :; do echo editor; sleep 1; done; }
tests()  { while :; do echo tests; sleep 1; done; }
shell()  { while :; do echo shell; sleep 1; done; }

tpane

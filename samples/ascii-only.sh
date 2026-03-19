#!/usr/bin/env tpane
# +-------------+-------------+
# |   editor    |   server    |
# +-------------+-------------+
# |   tests     |   shell     |
# +-------------+-------------+

editor() { while :; do echo editor; sleep 1; done; }
server() { while :; do echo server; sleep 1; done; }
tests()  { while :; do echo tests; sleep 1; done; }
shell()  { while :; do echo shell; sleep 1; done; }

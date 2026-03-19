#!/usr/bin/env tpane
# layout:
# ┌──────────────────────┬──────────────────────────┐
# │ api (6w,3h)          │ worker (2w,2h)           │
# ├──────────────────────┼─────────────┬────────────┤
# │ frontend (6w,1h)     │queue(1w,1h) │logs(1w,1h) │
# └──────────────────────┴─────────────┴────────────┘

api()      { while :; do echo api; sleep 1; done; }
worker()   { while :; do echo worker; sleep 1; done; }
frontend() { while :; do echo frontend; sleep 1; done; }
queue()    { while :; do echo queue; sleep 1; done; }
logs()     { while :; do echo logs; sleep 1; done; }

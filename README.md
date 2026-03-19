# tpane

**Draw your tmux layout in comments. Run it like a script.**

```bash
#!/usr/bin/env bash
# ┌──────────────────────┬──────────────────────┐
# │        api           │        worker        │
# │                      ├──────────────┬───────┤
# │                      │    queue     │ logs  │
# ├──────────────────────┼──────────────┴───────┤
# │       frontend       │        shell         │
# └──────────────────────┴──────────────────────┘

api()      { python3 api.py; }
worker()   { python3 worker.py; }
queue()    { redis-cli monitor; }
logs()     { tail -f app.log; }
frontend() { npm run dev; }
shell()    { bash; }

tpane
```

```bash
./dev.sh
```

That's it.

---

## Install

### 1. Install tmux

```bash
# Debian / Ubuntu
sudo apt install tmux

# macOS
brew install tmux
```
### 2. (optional) Configure tmux in `~/.tmux.conf`
I recommend adding the following line to allow `Ctrl+x` to exit your session, and enable mouse controls.
```bash
bind-key -n C-x kill-session
set -g mouse on
```


### 3. Install tpane
All you need is [tpane.sh](https://raw.githubusercontent.com/modularizer/tpane/refs/heads/master/tpane.sh) on your `PATH`. Here is one way that can be done
```bash
curl -fsSL https://raw.githubusercontent.com/modularizer/tpane/refs/heads/master/tpane.sh \
  -o ~/.local/bin/tpane && chmod +x ~/.local/bin/tpane
```

---

## How It Works

1. Draw a layout in comments using ASCII or box-drawing characters
2. Define bash functions with the same names as the pane labels
3. Call `tpane` at the bottom of your script
4. Run the script -- tpane parses the diagram, builds a split tree, and launches tmux

---

## Example

```bash
#!/usr/bin/env bash
# ┌──────────────┬──────────────┐
# │     api      │    worker    │
# ├──────────────┼──────────────┤
# │     logs     │    shell     │
# └──────────────┴──────────────┘

api()    { python3 api.py; }
worker() { celery -A tasks worker; }
logs()   { tail -f app.log; }
shell()  { bash; }

tpane  # this will read the comment block from the script that called it (this one) to parse the layout, and source its caller to have access to call the functions
```

Pane sizes are proportional to the diagram geometry. Wider boxes become wider panes.

---

## Sizing

### Auto (default)

Sizes come from the diagram. Draw it wider, it gets wider.

### Explicit flex weights (optional)
To override the detected sizes, you can use this...
```bash
# ┌──────────────────────┬────────────────────────┐
# │ api (3w,2h)          │ worker (2w,2h)         │
# ├──────────────────────┼────────────┬───────────┤
# │ frontend (3w,1h)     │queue(1w,1h)│logs(1w,1h)│
# └──────────────────────┴────────────┴───────────┘
```

* `(Xw)` -- width weight
* `(Yh)` -- height weight
* `(Xw,Yh)` -- both
* If any pane uses `w`, all must. Same for `h`.

---

## Diagram Markers

The diagram can follow any of these comment headers:

```bash
# tpane:
# layout:
# Layout:
```

Or no header at all -- tpane auto-detects comment lines that start with box-drawing characters:

```bash
#!/usr/bin/env bash
# ┌──────────┬──────────┐
# │   left   │  right   │
# └──────────┴──────────┘
```

---

## Drawing Styles

ASCII, Unicode box-drawing, and double-line characters can be freely mixed.
tpane parses by **edge capability** (horizontal vs vertical), not glyph identity.

### Supported characters

| Role | Characters |
|---|---|
| Horizontal | `-` `_` `─` `━` `═` |
| Vertical | `\|` `│` `┃` `║` |
| Corner / Junction | `+` `┌` `┐` `└` `┘` `├` `┤` `┬` `┴` `┼` `╔` `╗` `╚` `╝` `╠` `╣` `╦` `╩` `╬` |

Corners and junctions count as both horizontal and vertical, so `+`, `┼`, `├`, etc. all work at intersections.

### ASCII

```
+-------------+-------------+
|     api     |   worker    |
+-------------+-------------+
|   frontend  |    logs     |
+-------------+-------------+
```

### Box-drawing

```
┌─────────────┬─────────────┐
│     api     │   worker    │
├─────────────┼─────────────┤
│   frontend  │    logs     │
└─────────────┴─────────────┘
```

### Mixed

```
+───────────┬───────────+
│    api    │  worker   |
+───────────┼───────────+
|   logs    │  shell    │
+───────────┴───────────+
```

---

## Alternate Usage

### Direct invocation

```bash
tpane ./dev.sh
```

---

## Options

```
--session <name>   tmux session name (default: tpane)
--dir <path>       directory of pane executables
--strict           fail on missing commands
--dry-run, -d      print what would happen
--preview          show parsed layout and exit
--layout-str <s>   inline layout string
alias              print shell alias for tpane
```

---

## Rules

* Pane labels: `[a-zA-Z0-9_-]+`
* One label per pane
* Empty/unlabeled panes are allowed
* Functions in the script take priority over files in `--dir`

---

## Philosophy

* The script **is the config**
* The diagram **is the layout**
* The labels **are the API**
* The geometry **is the sizing**

---

## Why

Because this:

```bash
tmux split-window -h
tmux split-window -v
tmux select-pane -t 0
tmux split-window -v
tmux send-keys ...
```

...should not be your life.

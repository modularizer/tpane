#!/usr/bin/env bash
[[ -n ${_TPANE_RUNNING:-} ]] && { return 0 2>/dev/null || exit 0; }
export _TPANE_RUNNING=1
# tpane - Draw your tmux layout in comments. Run it like a script.
# Bash 4+ required.
#
# Usage:
#   source ./tpane.sh
#   tpane_launch_tmux_from_script "$0" [session_name]
#
# Or as a standalone CLI:
#   ./tpane.sh [options] <script-or-layout> [dir]
#
# Options:
#   --session <name>   tmux session name (default: tpane)
#   --dir <path>       directory of pane scripts (fallback for missing functions)
#   --strict           fail on missing commands or invalid sizing
#   --dry-run          print actions without running tmux
#   --preview          show parsed layout and exit
#   --layout-str <s>   use inline layout string instead of file

# shellcheck disable=SC2034,SC2154

# ---------------------------------------------------------------------------
# Global state
# ---------------------------------------------------------------------------

declare -ga TPANE_GRID_ROWS=()
declare -gi TPANE_GRID_H=0
declare -gi TPANE_GRID_W=0
declare -gi TPANE_PANE_COUNT=0

declare -ga TPANE_PANE_NAME=()
declare -ga TPANE_PANE_X1=()
declare -ga TPANE_PANE_Y1=()
declare -ga TPANE_PANE_X2=()
declare -ga TPANE_PANE_Y2=()

declare -ga TPANE_PANE_NX1=()
declare -ga TPANE_PANE_NY1=()
declare -ga TPANE_PANE_NX2=()
declare -ga TPANE_PANE_NY2=()
declare -ga TPANE_PANE_NW=()
declare -ga TPANE_PANE_NH=()

declare -ga TPANE_PANE_WFLEX=()
declare -ga TPANE_PANE_HFLEX=()
declare -ga TPANE_PANE_AUTO_W=()
declare -ga TPANE_PANE_AUTO_H=()
declare -ga TPANE_PANE_CMD=()

TPANE_ROW_HEIGHT_IN_COLS=3

declare -gi TPANE_NODE_COUNT=0
declare -ga TPANE_NODE_TYPE=()
declare -ga TPANE_NODE_AXIS=()
declare -ga TPANE_NODE_A=()
declare -ga TPANE_NODE_B=()
declare -ga TPANE_NODE_PANE=()
declare -ga TPANE_NODE_X1=()
declare -ga TPANE_NODE_Y1=()
declare -ga TPANE_NODE_X2=()
declare -ga TPANE_NODE_Y2=()
declare -ga TPANE_NODE_W=()
declare -ga TPANE_NODE_H=()

declare -g TPANE_ROOT_NODE=
declare -g TPANE_BUILD_RESULT=
declare -ga TPANE_DIAGRAM_LINES=()

# CLI state
declare -g TPANE_SCRIPT_PATH=
declare -g TPANE_SESSION_NAME=
declare -g TPANE_DIR=
declare -gi TPANE_STRICT=0
declare -gi TPANE_DRY_RUN=0
declare -gi TPANE_PREVIEW=0
declare -g TPANE_LAYOUT_STR=
declare -gi TPANE_LABELS=${TPANE_LABELS:-1}
declare -gi TPANE_FORCE=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

tpane_die() {
  echo "tpane: $*" >&2
  return 1
}

tpane_require_tmux() {
  command -v tmux >/dev/null 2>&1 && return 0
  echo "tpane: tmux is not installed." >&2
  echo "" >&2
  echo "Install tmux:" >&2
  if [[ "$OSTYPE" == darwin* ]]; then
    echo "  brew install tmux" >&2
  elif command -v apt >/dev/null 2>&1; then
    echo "  sudo apt install tmux" >&2
  elif command -v dnf >/dev/null 2>&1; then
    echo "  sudo dnf install tmux" >&2
  elif command -v pacman >/dev/null 2>&1; then
    echo "  sudo pacman -S tmux" >&2
  elif command -v apk >/dev/null 2>&1; then
    echo "  sudo apk add tmux" >&2
  elif command -v pkg >/dev/null 2>&1; then
    echo "  sudo pkg install tmux" >&2
  elif command -v zypper >/dev/null 2>&1; then
    echo "  sudo zypper install tmux" >&2
  elif [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
    echo "  pacman -S tmux    # MSYS2/Git Bash" >&2
  else
    echo "  See https://github.com/tmux/tmux/wiki/Installing" >&2
  fi
  return 1
}

tpane_trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

tpane_collapse_spaces() {
  local s=$1
  s=$(printf '%s' "$s" | tr '\t' ' ')
  while [[ $s == *"  "* ]]; do
    s=${s//  / }
  done
  printf '%s' "$(tpane_trim "$s")"
}

tpane_repeat_char() {
  local ch=$1 n=$2 out= i
  for ((i=0; i<n; i++)); do
    out+=$ch
  done
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Pass 1-2: Input loading & tpane block extraction
# ---------------------------------------------------------------------------

tpane_line_is_diagram_marker() {
  # Matches: # tpane:  # layout:  # Layout:  or just bare #
  [[ $1 =~ ^[[:space:]]*#[[:space:]]*(tpane|[Ll]ayout):[[:space:]]*$ ]] ||
  [[ $1 =~ ^[[:space:]]*#[[:space:]]*$ ]]
}

tpane_line_is_diagram_content() {
  # A comment line whose content starts with a box-drawing or ASCII border char
  local content=$1
  [[ $content =~ ^[[:space:]]*#[[:space:]]*(.*) ]] || return 1
  local inner=${BASH_REMATCH[1]}
  # Starts with a border char: + ┌ ╔ | │ ║
  [[ $inner =~ ^[+┌╔|│║┃└╚├╠] ]]
}

tpane_extract_diagram_from_script() {
  local script_path=$1
  local line collecting=0 found_marker=0

  [[ -f $script_path ]] || tpane_die "file not found: $script_path" || return 1

  TPANE_DIAGRAM_LINES=()

  while IFS= read -r line; do
    if (( !collecting )); then
      # Check for explicit marker line
      if tpane_line_is_diagram_marker "$line"; then
        found_marker=1
        collecting=1
        continue
      fi
      # Or a comment line that looks like the start of a diagram (no marker needed)
      if tpane_line_is_diagram_content "$line"; then
        collecting=1
        # Fall through to collect this line
      else
        continue
      fi
    fi

    if (( collecting )); then
      if [[ $line =~ ^[[:space:]]*#( ?)(.*)$ ]]; then
        local content=${BASH_REMATCH[2]}
        # If we hit an empty comment after collecting lines, stop
        if [[ -z $content ]] && (( ${#TPANE_DIAGRAM_LINES[@]} > 0 )); then
          break
        fi
        [[ -n $content ]] && TPANE_DIAGRAM_LINES+=("$content")
      else
        break
      fi
    fi
  done < "$script_path"

  (( ${#TPANE_DIAGRAM_LINES[@]} > 0 )) || tpane_die "no diagram found in $script_path" || return 1
}

tpane_extract_diagram_from_layout_file() {
  local layout_path=$1
  [[ -f $layout_path ]] || tpane_die "file not found: $layout_path" || return 1

  TPANE_DIAGRAM_LINES=()
  while IFS= read -r line; do
    TPANE_DIAGRAM_LINES+=("$line")
  done < "$layout_path"

  (( ${#TPANE_DIAGRAM_LINES[@]} > 0 )) || tpane_die "empty layout file: $layout_path" || return 1
}

tpane_extract_diagram_from_string() {
  local str=$1
  TPANE_DIAGRAM_LINES=()
  while IFS= read -r line; do
    [[ -n $line ]] && TPANE_DIAGRAM_LINES+=("$line")
  done <<< "$str"

  (( ${#TPANE_DIAGRAM_LINES[@]} > 0 )) || tpane_die "empty layout string" || return 1
}

# ---------------------------------------------------------------------------
# Pass 3: Normalize diagram to rectangular grid
# ---------------------------------------------------------------------------

tpane_char_at() {
  local y=$1 x=$2
  if (( y < 0 || y >= TPANE_GRID_H || x < 0 || x >= TPANE_GRID_W )); then
    printf ' '
    return 0
  fi
  printf '%s' "${TPANE_GRID_ROWS[y]:x:1}"
}

tpane_supports_h() {
  case "$1" in
    "-"|"_"|"+"|"─"|"━"|"═"|"┌"|"┐"|"└"|"┘"|"├"|"┤"|"┬"|"┴"|"┼"|"╔"|"╗"|"╚"|"╝"|"╠"|"╣"|"╦"|"╩"|"╬") return 0 ;;
    *) return 1 ;;
  esac
}

tpane_supports_v() {
  case "$1" in
    "|"|"+"|"│"|"┃"|"║"|"┌"|"┐"|"└"|"┘"|"├"|"┤"|"┬"|"┴"|"┼"|"╔"|"╗"|"╚"|"╝"|"╠"|"╣"|"╦"|"╩"|"╬") return 0 ;;
    *) return 1 ;;
  esac
}

tpane_is_border_char() {
  local ch=$1
  tpane_supports_h "$ch" && return 0
  tpane_supports_v "$ch" && return 0
  return 1
}

tpane_is_text_char() {
  local ch=$1
  [[ $ch != ' ' ]] || return 1
  tpane_is_border_char "$ch" && return 1
  return 0
}

tpane_normalize_grid() {
  local -n _src_lines=$1
  local maxw=0 line pad

  TPANE_GRID_ROWS=()
  TPANE_GRID_H=${#_src_lines[@]}
  TPANE_GRID_W=0

  (( TPANE_GRID_H > 0 )) || tpane_die "empty diagram" || return 1

  for line in "${_src_lines[@]}"; do
    ((${#line} > maxw)) && maxw=${#line}
  done
  TPANE_GRID_W=$maxw

  for line in "${_src_lines[@]}"; do
    pad=$((maxw - ${#line}))
    TPANE_GRID_ROWS+=("$line$(tpane_repeat_char ' ' "$pad")")
  done
}

# ---------------------------------------------------------------------------
# Pass 5: Find pane rectangles
# ---------------------------------------------------------------------------

tpane_rect_has_valid_border() {
  local x1=$1 y1=$2 x2=$3 y2=$4
  local x y ch

  (( x2 > x1 + 1 )) || return 1
  (( y2 > y1 + 1 )) || return 1

  local top_row=${TPANE_GRID_ROWS[y1]}
  local bot_row=${TPANE_GRID_ROWS[y2]}
  for ((x=x1; x<=x2; x++)); do
    ch=${top_row:x:1}
    tpane_supports_h "$ch" || return 1
    ch=${bot_row:x:1}
    tpane_supports_h "$ch" || return 1
  done

  for ((y=y1; y<=y2; y++)); do
    ch=${TPANE_GRID_ROWS[y]:x1:1}
    tpane_supports_v "$ch" || return 1
    ch=${TPANE_GRID_ROWS[y]:x2:1}
    tpane_supports_v "$ch" || return 1
  done

  return 0
}

tpane_rect_has_internal_full_vertical_divider() {
  local x1=$1 y1=$2 x2=$3 y2=$4
  local x y ch ok

  for ((x=x1+1; x<=x2-1; x++)); do
    ok=1
    for ((y=y1; y<=y2; y++)); do
      ch=${TPANE_GRID_ROWS[y]:x:1}
      case "$ch" in "|"|"+"|"│"|"┃"|"║"|"┌"|"┐"|"└"|"┘"|"├"|"┤"|"┬"|"┴"|"┼"|"╔"|"╗"|"╚"|"╝"|"╠"|"╣"|"╦"|"╩"|"╬") ;; *) ok=0; break ;; esac
    done
    (( ok )) && return 0
  done

  return 1
}

tpane_rect_has_internal_full_horizontal_divider() {
  local x1=$1 y1=$2 x2=$3 y2=$4
  local y x ch ok

  for ((y=y1+1; y<=y2-1; y++)); do
    ok=1
    local _row=${TPANE_GRID_ROWS[y]}
    for ((x=x1; x<=x2; x++)); do
      ch=${_row:x:1}
      case "$ch" in "-"|"_"|"+"|"─"|"━"|"═"|"┌"|"┐"|"└"|"┘"|"├"|"┤"|"┬"|"┴"|"┼"|"╔"|"╗"|"╚"|"╝"|"╠"|"╣"|"╦"|"╩"|"╬") ;; *) ok=0; break ;; esac
    done
    (( ok )) && return 0
  done

  return 1
}

tpane_find_left_boundary() {
  local y=$1 x=$2 ch
  local row=${TPANE_GRID_ROWS[y]}
  while (( x >= 0 )); do
    ch=${row:x:1}
    case "$ch" in "|"|"+"|"│"|"┃"|"║"|"┌"|"┐"|"└"|"┘"|"├"|"┤"|"┬"|"┴"|"┼"|"╔"|"╗"|"╚"|"╝"|"╠"|"╣"|"╦"|"╩"|"╬") REPLY=$x; return 0 ;; esac
    ((x--))
  done
  REPLY=-1
}

tpane_find_right_boundary() {
  local y=$1 x=$2 ch
  local row=${TPANE_GRID_ROWS[y]}
  while (( x < TPANE_GRID_W )); do
    ch=${row:x:1}
    case "$ch" in "|"|"+"|"│"|"┃"|"║"|"┌"|"┐"|"└"|"┘"|"├"|"┤"|"┬"|"┴"|"┼"|"╔"|"╗"|"╚"|"╝"|"╠"|"╣"|"╦"|"╩"|"╬") REPLY=$x; return 0 ;; esac
    ((x++)) || true
  done
  REPLY=-1
}

tpane_find_top_boundary() {
  local y=$1 x=$2 ch
  while (( y >= 0 )); do
    ch=${TPANE_GRID_ROWS[y]:x:1}
    case "$ch" in "-"|"_"|"+"|"─"|"━"|"═"|"┌"|"┐"|"└"|"┘"|"├"|"┤"|"┬"|"┴"|"┼"|"╔"|"╗"|"╚"|"╝"|"╠"|"╣"|"╦"|"╩"|"╬") REPLY=$y; return 0 ;; esac
    ((y--))
  done
  REPLY=-1
}

tpane_find_bottom_boundary() {
  local y=$1 x=$2 ch
  while (( y < TPANE_GRID_H )); do
    ch=${TPANE_GRID_ROWS[y]:x:1}
    case "$ch" in "-"|"_"|"+"|"─"|"━"|"═"|"┌"|"┐"|"└"|"┘"|"├"|"┤"|"┬"|"┴"|"┼"|"╔"|"╗"|"╚"|"╝"|"╠"|"╣"|"╦"|"╩"|"╬") REPLY=$y; return 0 ;; esac
    ((y++)) || true
  done
  REPLY=-1
}

# ---------------------------------------------------------------------------
# Pass 7: Extract label text and annotations
# ---------------------------------------------------------------------------

tpane_extract_rect_text() {
  local x1=$1 y1=$2 x2=$3 y2=$4
  local y line out=
  for ((y=y1+1; y<=y2-1; y++)); do
    line=${TPANE_GRID_ROWS[y]:x1+1:x2-x1-1}
    line=${line%"${line##*[![:space:]]}"} # rtrim
    out+="$line"$'\n'
  done
  printf '%s' "$out"
}

tpane_parse_label_and_flex() {
  local raw=$1
  local joined annotation label w= h=

  joined=$(printf '%s' "$raw" | tr '\n' ' ')
  joined=$(tpane_collapse_spaces "$joined")

  if [[ $joined =~ \(([[:space:]]*[0-9]+[[:space:]]*[whWH]([[:space:]]*,[[:space:]]*[0-9]+[[:space:]]*[whWH])?[[:space:]]*)\) ]]; then
    annotation=${BASH_REMATCH[0]}
    local inner=${annotation:1:${#annotation}-2}
    inner=$(printf '%s' "$inner" | tr -d '[:space:]')
    IFS=',' read -r -a _parts <<< "$inner"

    local part num kind
    for part in "${_parts[@]}"; do
      [[ $part =~ ^([0-9]+)([wWhH])$ ]] || return 1
      num=${BASH_REMATCH[1]}
      kind=${BASH_REMATCH[2]}
      case "$kind" in
        w|W)
          [[ -z $w ]] || return 1
          w=$num
          ;;
        h|H)
          [[ -z $h ]] || return 1
          h=$num
          ;;
        *)
          return 1
          ;;
      esac
    done

    joined=${joined/"$annotation"/}
    joined=$(tpane_collapse_spaces "$joined")
  fi

  label=$joined
  if [[ -n $label && ! $label =~ ^[A-Za-z0-9_-]+$ ]]; then
    return 1
  fi

  TPANE_PARSE_LABEL=$label
  TPANE_PARSE_W=$w
  TPANE_PARSE_H=$h
  return 0
}

tpane_scale_to_100() {
  local pos=$1 total=$2
  if (( total <= 0 )); then
    printf '%d' 0
    return 0
  fi
  printf '%d' $(((pos * 100 + total / 2) / total))
}

tpane_add_pane() {
  local name=$1 x1=$2 y1=$3 x2=$4 y2=$5 wf=$6 hf=$7
  local id=$TPANE_PANE_COUNT
  local raw_w raw_h auto_w auto_h
  local total_w total_h
  local nx1 ny1 nx2 ny2 nw nh

  raw_w=$((x2 - x1))
  raw_h=$((y2 - y1))

  auto_w=$raw_w
  auto_h=$((raw_h * TPANE_ROW_HEIGHT_IN_COLS))

  total_w=$((TPANE_GRID_W - 1))
  total_h=$((TPANE_GRID_H - 1))

  nx1=$(tpane_scale_to_100 "$x1" "$total_w")
  ny1=$(tpane_scale_to_100 "$y1" "$total_h")
  nx2=$(tpane_scale_to_100 "$x2" "$total_w")
  ny2=$(tpane_scale_to_100 "$y2" "$total_h")
  nw=$((nx2 - nx1))
  nh=$((ny2 - ny1))

  TPANE_PANE_NAME[id]=$name
  TPANE_PANE_X1[id]=$x1
  TPANE_PANE_Y1[id]=$y1
  TPANE_PANE_X2[id]=$x2
  TPANE_PANE_Y2[id]=$y2

  TPANE_PANE_NX1[id]=$nx1
  TPANE_PANE_NY1[id]=$ny1
  TPANE_PANE_NX2[id]=$nx2
  TPANE_PANE_NY2[id]=$ny2
  TPANE_PANE_NW[id]=$nw
  TPANE_PANE_NH[id]=$nh

  TPANE_PANE_WFLEX[id]=$wf
  TPANE_PANE_HFLEX[id]=$hf
  TPANE_PANE_AUTO_W[id]=$auto_w
  TPANE_PANE_AUTO_H[id]=$auto_h
  TPANE_PANE_CMD[id]=

  ((TPANE_PANE_COUNT++)) || true
}

tpane_find_leaf_panes() {
  local y x ch
  local left right top bottom
  local key text
  local label wf hf

  TPANE_PANE_COUNT=0
  TPANE_PANE_NAME=()
  TPANE_PANE_X1=()
  TPANE_PANE_Y1=()
  TPANE_PANE_X2=()
  TPANE_PANE_Y2=()

  TPANE_PANE_NX1=()
  TPANE_PANE_NY1=()
  TPANE_PANE_NX2=()
  TPANE_PANE_NY2=()
  TPANE_PANE_NW=()
  TPANE_PANE_NH=()

  TPANE_PANE_WFLEX=()
  TPANE_PANE_HFLEX=()
  TPANE_PANE_AUTO_W=()
  TPANE_PANE_AUTO_H=()
  TPANE_PANE_CMD=()

  declare -A seen_rect=()

  for ((y=0; y<TPANE_GRID_H; y++)); do
    local _row=${TPANE_GRID_ROWS[y]}
    for ((x=0; x<TPANE_GRID_W; x++)); do
      ch=${_row:x:1}

      # Skip border chars — we only seed from interior (text/space) cells
      case "$ch" in
        "-"|"_"|"+"|"─"|"━"|"═"|"|"|"│"|"┃"|"║"|"┌"|"┐"|"└"|"┘"|"├"|"┤"|"┬"|"┴"|"┼"|"╔"|"╗"|"╚"|"╝"|"╠"|"╣"|"╦"|"╩"|"╬") continue ;;
      esac

      tpane_find_left_boundary "$y" "$x"; left=$REPLY
      tpane_find_right_boundary "$y" "$x"; right=$REPLY
      tpane_find_top_boundary "$y" "$x"; top=$REPLY
      tpane_find_bottom_boundary "$y" "$x"; bottom=$REPLY

      (( left >= 0 && right >= 0 && top >= 0 && bottom >= 0 )) || continue

      key="$left,$top,$right,$bottom"
      [[ -n ${seen_rect[$key]:-} ]] && continue
      seen_rect[$key]=1

      tpane_rect_has_valid_border "$left" "$top" "$right" "$bottom" || continue

      if tpane_rect_has_internal_full_vertical_divider "$left" "$top" "$right" "$bottom"; then
        continue
      fi
      if tpane_rect_has_internal_full_horizontal_divider "$left" "$top" "$right" "$bottom"; then
        continue
      fi

      text=$(tpane_extract_rect_text "$left" "$top" "$right" "$bottom")
      if ! tpane_parse_label_and_flex "$text"; then
        tpane_die "invalid label/flex syntax in pane rect $key"
        return 1
      fi

      label=$TPANE_PARSE_LABEL
      wf=$TPANE_PARSE_W
      hf=$TPANE_PARSE_H

      tpane_add_pane "$label" "$left" "$top" "$right" "$bottom" "$wf" "$hf"
    done
  done

  (( TPANE_PANE_COUNT > 0 )) || tpane_die "no panes found" || return 1
}

# ---------------------------------------------------------------------------
# Pass 8: Validate flex consistency
# ---------------------------------------------------------------------------

tpane_validate_flex_consistency() {
  local i any_w=0 any_h=0

  for ((i=0; i<TPANE_PANE_COUNT; i++)); do
    [[ -n ${TPANE_PANE_WFLEX[i]:-} ]] && any_w=1
    [[ -n ${TPANE_PANE_HFLEX[i]:-} ]] && any_h=1
  done

  if (( any_w )); then
    for ((i=0; i<TPANE_PANE_COUNT; i++)); do
      [[ -n ${TPANE_PANE_WFLEX[i]:-} ]] || {
        tpane_die "pane '${TPANE_PANE_NAME[i]:-(unlabeled)}' missing width flex; if one pane specifies w, all panes must"
        return 1
      }
    done
  fi

  if (( any_h )); then
    for ((i=0; i<TPANE_PANE_COUNT; i++)); do
      [[ -n ${TPANE_PANE_HFLEX[i]:-} ]] || {
        tpane_die "pane '${TPANE_PANE_NAME[i]:-(unlabeled)}' missing height flex; if one pane specifies h, all panes must"
        return 1
      }
    done
  fi
}

tpane_parse_diagram() {
  local src_array_name=$1
  tpane_normalize_grid "$src_array_name" || return 1
  tpane_find_leaf_panes || return 1
  tpane_validate_flex_consistency || return 1
}

tpane_print_parse_result() {
  local i
  printf 'grid: %dx%d\n' "$TPANE_GRID_W" "$TPANE_GRID_H"
  printf 'panes: %d\n' "$TPANE_PANE_COUNT"
  for ((i=0; i<TPANE_PANE_COUNT; i++)); do
    printf 'pane[%d]: name=%q rect=(%d,%d)-(%d,%d) norm=(%d,%d)-(%d,%d) size=(%d,%d) w=%q h=%q auto=(%d,%d)\n' \
      "$i" \
      "${TPANE_PANE_NAME[i]}" \
      "${TPANE_PANE_X1[i]}" \
      "${TPANE_PANE_Y1[i]}" \
      "${TPANE_PANE_X2[i]}" \
      "${TPANE_PANE_Y2[i]}" \
      "${TPANE_PANE_NX1[i]}" \
      "${TPANE_PANE_NY1[i]}" \
      "${TPANE_PANE_NX2[i]}" \
      "${TPANE_PANE_NY2[i]}" \
      "${TPANE_PANE_NW[i]}" \
      "${TPANE_PANE_NH[i]}" \
      "${TPANE_PANE_WFLEX[i]}" \
      "${TPANE_PANE_HFLEX[i]}" \
      "${TPANE_PANE_AUTO_W[i]}" \
      "${TPANE_PANE_AUTO_H[i]}"
  done
}

# ---------------------------------------------------------------------------
# Pass 10: Build layout tree from rectangles
# ---------------------------------------------------------------------------

tpane_reset_tree() {
  TPANE_NODE_COUNT=0
  TPANE_NODE_TYPE=()
  TPANE_NODE_AXIS=()
  TPANE_NODE_A=()
  TPANE_NODE_B=()
  TPANE_NODE_PANE=()
  TPANE_NODE_X1=()
  TPANE_NODE_Y1=()
  TPANE_NODE_X2=()
  TPANE_NODE_Y2=()
  TPANE_NODE_W=()
  TPANE_NODE_H=()
  TPANE_ROOT_NODE=
  TPANE_BUILD_RESULT=
}

tpane_join_ids() {
  local out= sep= x
  for x in "$@"; do
    out+="${sep}${x}"
    sep=' '
  done
  printf '%s' "$out"
}

tpane_node_new_leaf() {
  local pane_id=$1
  local id=$TPANE_NODE_COUNT

  TPANE_NODE_TYPE[id]=leaf
  TPANE_NODE_AXIS[id]=''
  TPANE_NODE_A[id]=''
  TPANE_NODE_B[id]=''
  TPANE_NODE_PANE[id]=$pane_id
  TPANE_NODE_X1[id]=${TPANE_PANE_X1[pane_id]}
  TPANE_NODE_Y1[id]=${TPANE_PANE_Y1[pane_id]}
  TPANE_NODE_X2[id]=${TPANE_PANE_X2[pane_id]}
  TPANE_NODE_Y2[id]=${TPANE_PANE_Y2[pane_id]}
  TPANE_NODE_W[id]=''
  TPANE_NODE_H[id]=''

  ((TPANE_NODE_COUNT++)) || true
  TPANE_BUILD_RESULT=$id
}

tpane_node_new_split() {
  local axis=$1 a=$2 b=$3 x1=$4 y1=$5 x2=$6 y2=$7
  local id=$TPANE_NODE_COUNT

  TPANE_NODE_TYPE[id]=split
  TPANE_NODE_AXIS[id]=$axis
  TPANE_NODE_A[id]=$a
  TPANE_NODE_B[id]=$b
  TPANE_NODE_PANE[id]=''
  TPANE_NODE_X1[id]=$x1
  TPANE_NODE_Y1[id]=$y1
  TPANE_NODE_X2[id]=$x2
  TPANE_NODE_Y2[id]=$y2
  TPANE_NODE_W[id]=''
  TPANE_NODE_H[id]=''

  ((TPANE_NODE_COUNT++)) || true
  TPANE_BUILD_RESULT=$id
}

tpane_region_bounds_from_panes() {
  local pane_ids=($1)
  local first=1 pid
  local x1= y1= x2= y2=

  for pid in "${pane_ids[@]}"; do
    if (( first )); then
      x1=${TPANE_PANE_X1[pid]}
      y1=${TPANE_PANE_Y1[pid]}
      x2=${TPANE_PANE_X2[pid]}
      y2=${TPANE_PANE_Y2[pid]}
      first=0
    else
      (( ${TPANE_PANE_X1[pid]} < x1 )) && x1=${TPANE_PANE_X1[pid]}
      (( ${TPANE_PANE_Y1[pid]} < y1 )) && y1=${TPANE_PANE_Y1[pid]}
      (( ${TPANE_PANE_X2[pid]} > x2 )) && x2=${TPANE_PANE_X2[pid]}
      (( ${TPANE_PANE_Y2[pid]} > y2 )) && y2=${TPANE_PANE_Y2[pid]}
    fi
  done

  TPANE_REGION_X1=$x1
  TPANE_REGION_Y1=$y1
  TPANE_REGION_X2=$x2
  TPANE_REGION_Y2=$y2
}

tpane_build_tree_for_panes() {
  local pane_ids=($1)
  local pid x y x1 y1 x2 y2
  local left_ids=() right_ids=() top_ids=() bottom_ids=()

  ((${#pane_ids[@]} > 0)) || tpane_die "internal error: empty pane list" || return 1

  if ((${#pane_ids[@]} == 1)); then
    tpane_node_new_leaf "${pane_ids[0]}"
    return 0
  fi

  tpane_region_bounds_from_panes "$1"
  x1=$TPANE_REGION_X1
  y1=$TPANE_REGION_Y1
  x2=$TPANE_REGION_X2
  y2=$TPANE_REGION_Y2

  for ((x=x1+1; x<=x2-1; x++)); do
    local full=1 ch
    for ((y=y1; y<=y2; y++)); do
      ch=${TPANE_GRID_ROWS[y]:x:1}
      case "$ch" in "|"|"+"|"│"|"┃"|"║"|"┌"|"┐"|"└"|"┘"|"├"|"┤"|"┬"|"┴"|"┼"|"╔"|"╗"|"╚"|"╝"|"╠"|"╣"|"╦"|"╩"|"╬") ;; *) full=0; break ;; esac
    done
    (( full )) || continue

    left_ids=()
    right_ids=()

    for pid in "${pane_ids[@]}"; do
      if (( ${TPANE_PANE_X2[pid]} <= x )); then
        left_ids+=("$pid")
      elif (( ${TPANE_PANE_X1[pid]} >= x )); then
        right_ids+=("$pid")
      else
        full=0
        break
      fi
    done

    (( full )) || continue
    ((${#left_ids[@]} > 0 && ${#right_ids[@]} > 0)) || continue

    tpane_build_tree_for_panes "$(tpane_join_ids "${left_ids[@]}")" || return 1
    local a=$TPANE_BUILD_RESULT
    tpane_build_tree_for_panes "$(tpane_join_ids "${right_ids[@]}")" || return 1
    local b=$TPANE_BUILD_RESULT
    tpane_node_new_split "v" "$a" "$b" "$x1" "$y1" "$x2" "$y2"
    return 0
  done

  for ((y=y1+1; y<=y2-1; y++)); do
    local full=1 ch
    local _row=${TPANE_GRID_ROWS[y]}
    for ((x=x1; x<=x2; x++)); do
      ch=${_row:x:1}
      case "$ch" in "-"|"_"|"+"|"─"|"━"|"═"|"┌"|"┐"|"└"|"┘"|"├"|"┤"|"┬"|"┴"|"┼"|"╔"|"╗"|"╚"|"╝"|"╠"|"╣"|"╦"|"╩"|"╬") ;; *) full=0; break ;; esac
    done
    (( full )) || continue

    top_ids=()
    bottom_ids=()

    for pid in "${pane_ids[@]}"; do
      if (( ${TPANE_PANE_Y2[pid]} <= y )); then
        top_ids+=("$pid")
      elif (( ${TPANE_PANE_Y1[pid]} >= y )); then
        bottom_ids+=("$pid")
      else
        full=0
        break
      fi
    done

    (( full )) || continue
    ((${#top_ids[@]} > 0 && ${#bottom_ids[@]} > 0)) || continue

    tpane_build_tree_for_panes "$(tpane_join_ids "${top_ids[@]}")" || return 1
    local a=$TPANE_BUILD_RESULT
    tpane_build_tree_for_panes "$(tpane_join_ids "${bottom_ids[@]}")" || return 1
    local b=$TPANE_BUILD_RESULT
    tpane_node_new_split "h" "$a" "$b" "$x1" "$y1" "$x2" "$y2"
    return 0
  done

  tpane_die "could not reconstruct split tree for region ($x1,$y1)-($x2,$y2)"
  return 1
}

tpane_build_tree() {
  local pane_ids=() i
  tpane_reset_tree
  for ((i=0; i<TPANE_PANE_COUNT; i++)); do
    pane_ids+=("$i")
  done
  tpane_build_tree_for_panes "$(tpane_join_ids "${pane_ids[@]}")" || return 1
  TPANE_ROOT_NODE=$TPANE_BUILD_RESULT
}

# ---------------------------------------------------------------------------
# Pass 11: Compute tmux split percentages
# ---------------------------------------------------------------------------

tpane_compute_node_sizes() {
  local node=$1
  local type=${TPANE_NODE_TYPE[node]}

  if [[ $type == leaf ]]; then
    local pid=${TPANE_NODE_PANE[node]}
    local w h

    if [[ -n ${TPANE_PANE_WFLEX[pid]:-} ]]; then
      w=${TPANE_PANE_WFLEX[pid]}
    else
      w=${TPANE_PANE_AUTO_W[pid]}
    fi

    if [[ -n ${TPANE_PANE_HFLEX[pid]:-} ]]; then
      h=${TPANE_PANE_HFLEX[pid]}
    else
      h=${TPANE_PANE_AUTO_H[pid]}
    fi

    (( w > 0 )) || w=1
    (( h > 0 )) || h=1

    TPANE_NODE_W[node]=$w
    TPANE_NODE_H[node]=$h
    return 0
  fi

  local a=${TPANE_NODE_A[node]}
  local b=${TPANE_NODE_B[node]}
  local axis=${TPANE_NODE_AXIS[node]}

  tpane_compute_node_sizes "$a" || return 1
  tpane_compute_node_sizes "$b" || return 1

  local wa=${TPANE_NODE_W[a]}
  local ha=${TPANE_NODE_H[a]}
  local wb=${TPANE_NODE_W[b]}
  local hb=${TPANE_NODE_H[b]}

  if [[ $axis == v ]]; then
    TPANE_NODE_W[node]=$((wa + wb))
    TPANE_NODE_H[node]=$ha
  else
    TPANE_NODE_W[node]=$wa
    TPANE_NODE_H[node]=$((ha + hb))
  fi
}

tpane_pct_of_second() {
  local first=$1 second=$2 total pct
  total=$((first + second))
  (( total > 0 )) || { printf '50'; return 0; }

  pct=$(((second * 100 + total / 2) / total))
  (( pct < 1 )) && pct=1
  (( pct > 99 )) && pct=99
  printf '%d' "$pct"
}

# ---------------------------------------------------------------------------
# Pass 9: Resolve commands
# ---------------------------------------------------------------------------

tpane_resolve_commands() {
  local script_path=${1:-}
  local dir=${2:-}
  local strict=${3:-0}
  local i name abs_script abs_dir

  if [[ -n $script_path ]]; then
    abs_script=$(cd "$(dirname "$script_path")" && printf '%s/%s' "$(pwd)" "$(basename "$script_path")")
  fi

  if [[ -n $dir ]]; then
    abs_dir=$(cd "$dir" && pwd) || {
      tpane_die "dir not found: $dir"
      return 1
    }
  fi

  for ((i=0; i<TPANE_PANE_COUNT; i++)); do
    name=${TPANE_PANE_NAME[i]}
    if [[ -z $name ]]; then
      TPANE_PANE_CMD[i]=
      continue
    fi

    # If we have a script, generate: source script && func
    # (the script defines the functions; tmux panes source it at runtime)
    if [[ -n ${abs_script:-} ]]; then
      TPANE_PANE_CMD[i]="source $(printf '%q' "$abs_script") && $(printf '%q' "$name")"
      continue
    fi

    # Function in current shell (library/source mode)
    if declare -F "$name" >/dev/null 2>&1; then
      local fndef
      fndef=$(declare -f "$name")
      TPANE_PANE_CMD[i]="$fndef"$'\n'"$name"
      continue
    fi

    # Dir fallback: look for executable in dir
    if [[ -n ${abs_dir:-} && -x "$abs_dir/$name" ]]; then
      TPANE_PANE_CMD[i]=$(printf '%q' "$abs_dir/$name")
      continue
    fi

    # PATH fallback: command exists on PATH
    if command -v "$name" >/dev/null 2>&1; then
      TPANE_PANE_CMD[i]=$(printf '%q' "$name")
      continue
    fi

    if (( strict )); then
      tpane_die "no function or executable found for pane '$name'"
      return 1
    fi

    TPANE_PANE_CMD[i]=
  done
}

# ---------------------------------------------------------------------------
# Pass 12: tmux execution
# ---------------------------------------------------------------------------

tpane_apply_node_to_tmux_pane() {
  local node=$1
  local pane_id=$2
  local type=${TPANE_NODE_TYPE[node]}

  if [[ $type == leaf ]]; then
    local pid=${TPANE_NODE_PANE[node]}
    local name=${TPANE_PANE_NAME[pid]}
    local cmd=${TPANE_PANE_CMD[pid]:-}

    tmux select-pane -t "$pane_id" -T "${name:-tpane}" >/dev/null 2>&1 || true

    if [[ -n $cmd ]]; then
      tmux send-keys -t "$pane_id" "$cmd" C-m
    fi
    return 0
  fi

  local a=${TPANE_NODE_A[node]}
  local b=${TPANE_NODE_B[node]}
  local axis=${TPANE_NODE_AXIS[node]}
  local new_pane pct

  if [[ $axis == v ]]; then
    pct=$(tpane_pct_of_second "${TPANE_NODE_W[a]}" "${TPANE_NODE_W[b]}")
    new_pane=$(tmux split-window -h -d -t "$pane_id" -l "${pct}%" -P -F '#{pane_id}') || return 1
    tpane_apply_node_to_tmux_pane "$a" "$pane_id" || return 1
    tpane_apply_node_to_tmux_pane "$b" "$new_pane" || return 1
  else
    pct=$(tpane_pct_of_second "${TPANE_NODE_H[a]}" "${TPANE_NODE_H[b]}")
    new_pane=$(tmux split-window -v -d -t "$pane_id" -l "${pct}%" -P -F '#{pane_id}') || return 1
    tpane_apply_node_to_tmux_pane "$a" "$pane_id" || return 1
    tpane_apply_node_to_tmux_pane "$b" "$new_pane" || return 1
  fi
}

tpane_print_tree() {
  local node=$1 indent=${2:-}
  local type=${TPANE_NODE_TYPE[node]}

  if [[ $type == leaf ]]; then
    local pid=${TPANE_NODE_PANE[node]}
    printf '%sleaf %s [w=%s h=%s]\n' \
      "$indent" \
      "${TPANE_PANE_NAME[pid]:-(unlabeled)}" \
      "${TPANE_NODE_W[node]}" \
      "${TPANE_NODE_H[node]}"
    return 0
  fi

  printf '%ssplit %s [w=%s h=%s]\n' \
    "$indent" \
    "${TPANE_NODE_AXIS[node]}" \
    "${TPANE_NODE_W[node]}" \
    "${TPANE_NODE_H[node]}"

  tpane_print_tree "${TPANE_NODE_A[node]}" "$indent  "
  tpane_print_tree "${TPANE_NODE_B[node]}" "$indent  "
}

# ---------------------------------------------------------------------------
# Pass 13: Preview mode
# ---------------------------------------------------------------------------

tpane_print_preview() {
  local i
  echo "--- diagram ---"
  for ((i=0; i<TPANE_GRID_H; i++)); do
    printf '%s\n' "${TPANE_GRID_ROWS[i]}"
  done
  echo ""
  echo "--- panes ($TPANE_PANE_COUNT) ---"
  for ((i=0; i<TPANE_PANE_COUNT; i++)); do
    printf 'pane %d: %s\n' "$i" "${TPANE_PANE_NAME[i]:-(unlabeled)}"
    printf '  rect: (%d,%d) -> (%d,%d)\n' \
      "${TPANE_PANE_X1[i]}" "${TPANE_PANE_Y1[i]}" \
      "${TPANE_PANE_X2[i]}" "${TPANE_PANE_Y2[i]}"
    printf '  flex: w=%s h=%s\n' \
      "${TPANE_PANE_WFLEX[i]:-(auto)}" \
      "${TPANE_PANE_HFLEX[i]:-(auto)}"
    printf '  cmd : %s\n' "${TPANE_PANE_CMD[i]:-(none)}"
  done
  echo ""
  echo "--- split tree ---"
  tpane_print_tree "$TPANE_ROOT_NODE"
}

# ---------------------------------------------------------------------------
# High-level API: launch from script (used by test.sh pattern)
# ---------------------------------------------------------------------------

tpane_launch_tmux_from_script() {
  local script_path=$1
  local session_name=${2:-$(tpane_session_name_from_path "$script_path")}
  local attach=${3:-1}
  local first_pane

  tpane_require_tmux || return 1

  tpane_extract_diagram_from_script "$script_path" || return 1
  tpane_parse_diagram TPANE_DIAGRAM_LINES || return 1
  tpane_build_tree || return 1
  tpane_compute_node_sizes "$TPANE_ROOT_NODE" || return 1
  tpane_resolve_commands "$script_path" "" 0 || return 1

  tmux kill-session -t "$session_name" 2>/dev/null || true
  tmux new-session -d -s "$session_name" -n "$session_name" -x "$(tput cols)" -y "$(tput lines)" || return 1
  if (( TPANE_LABELS )); then
    tmux set-option -t "$session_name" pane-border-status top 2>/dev/null || true
    tmux set-option -t "$session_name" pane-border-format ' #{pane_title} ' 2>/dev/null || true
  fi
  tmux set-window-option -t "$session_name" automatic-rename off 2>/dev/null || true
  first_pane=$(tmux display-message -p -t "$session_name:0.0" '#{pane_id}') || return 1

  tpane_apply_node_to_tmux_pane "$TPANE_ROOT_NODE" "$first_pane" || return 1

  # Call tpane_conf hook if defined
  if declare -F tpane_conf >/dev/null 2>&1; then
    tpane_conf "$session_name"
  fi

  if (( attach )); then
    if [[ -n ${TMUX:-} ]]; then
      tmux switch-client -t "$session_name"
    else
      tmux attach-session -t "$session_name"
    fi
  fi
}

# ---------------------------------------------------------------------------
# CLI: subcommands
# ---------------------------------------------------------------------------

tpane_print_box() {
  cat <<'BOX'
┌──────────────┬──────────────┐
│              │              │
├──────────────┼──────────────┤
│              │              │
└──────────────┴──────────────┘
BOX
}

tpane_init() {
  local path=${1:-}
  shift || true
  local -a names=("$@")

  [[ -n $path ]] || { tpane_die "usage: tpane init <path> [name1 name2 ...]" || exit 1; }

  if [[ -e $path ]] && (( !TPANE_FORCE )); then
    tpane_die "$path already exists (use -f to overwrite)" || exit 1
  fi

  # Default pane names
  if (( ${#names[@]} == 0 )); then
    names=(api worker logs shell)
  fi

  # Generate the layout diagram
  tpane_generate_auto_layout "${names[@]}"

  # Build the script
  {
    echo '#!/usr/bin/env tpane'
    for line in "${TPANE_DIAGRAM_LINES[@]}"; do
      echo "# $line"
    done
    echo ''
    for name in "${names[@]}"; do
      printf '%s() { while :; do echo %s; sleep 1; done; }\n' "$name" "$name"
    done
  } > "$path"

  chmod +x "$path"
  echo "created $path"
}

# ---------------------------------------------------------------------------
# CLI: argument parsing and main
# ---------------------------------------------------------------------------

tpane_parse_args() {
  TPANE_SCRIPT_PATH=
  TPANE_SESSION_NAME=
  TPANE_DIR=
  TPANE_STRICT=0
  TPANE_DRY_RUN=0
  TPANE_PREVIEW=0
  TPANE_LAYOUT_STR=

  local positionals=()

  while (( $# > 0 )); do
    case "$1" in
      --session)
        shift
        TPANE_SESSION_NAME=${1:?--session requires a value}
        ;;
      --dir)
        shift
        TPANE_DIR=${1:?--dir requires a value}
        ;;
      --strict)
        TPANE_STRICT=1
        ;;
      -d|--dry-run)
        TPANE_DRY_RUN=1
        ;;
      --preview)
        TPANE_PREVIEW=1
        ;;
      --labels)
        TPANE_LABELS=1
        ;;
      --no-labels)
        TPANE_LABELS=0
        ;;
      --layout-str)
        shift
        TPANE_LAYOUT_STR=${1:?--layout-str requires a value}
        ;;
      -h|--help)
        tpane_usage
        exit 0
        ;;
      alias)
        local self
        self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && printf '%s/%s' "$(pwd)" "$(basename "${BASH_SOURCE[0]}")")
        printf 'alias tpane="bash %q"\n' "$self"
        exit 0
        ;;
      box)
        tpane_print_box
        exit 0
        ;;
      init)
        shift
        tpane_init "$@"
        exit 0
        ;;
      -f|--force)
        TPANE_FORCE=1
        ;;
      -*)
        tpane_die "unknown option: $1" || exit 1
        ;;
      *)
        positionals+=("$1")
        ;;
    esac
    shift
  done

  if [[ -n $TPANE_LAYOUT_STR ]]; then
    # --layout-str mode; dir is optional positional
    if (( ${#positionals[@]} > 0 )); then
      TPANE_DIR=${positionals[0]}
    fi
  elif (( ${#positionals[@]} == 0 )); then
    # No args: detect the calling script via /proc/$PPID/cmdline
    local caller_script=
    if [[ -r /proc/$PPID/cmdline ]]; then
      local -a _cmdparts=()
      while IFS= read -r -d '' part; do
        _cmdparts+=("$part")
      done < "/proc/$PPID/cmdline"
      # Second element is typically the script path
      if (( ${#_cmdparts[@]} >= 2 )) && [[ -f ${_cmdparts[1]} ]]; then
        caller_script=${_cmdparts[1]}
      fi
    fi
    if [[ -n $caller_script ]]; then
      TPANE_SCRIPT_PATH=$caller_script
    else
      tpane_die "usage: tpane [options] <script-or-layout> [dir]" || exit 1
    fi
  elif (( ${#positionals[@]} == 1 )); then
    TPANE_SCRIPT_PATH=${positionals[0]}
  elif (( ${#positionals[@]} == 2 )); then
    TPANE_SCRIPT_PATH=${positionals[0]}
    TPANE_DIR=${positionals[1]}
  else
    tpane_die "too many arguments" || exit 1
  fi
}

tpane_usage() {
  cat <<'USAGE'
tpane - Draw your tmux layout in comments. Run it like a script.

Usage:
  tpane <script-or-layout> [dir]
  tpane --layout-str '<layout>' [dir]

Options:
  --session <name>   tmux session name (default: tpane)
  --dir <path>       directory of pane scripts
  --strict           fail on missing commands
  --dry-run          print actions without running tmux
  --preview          show parsed layout and exit
  --layout-str <s>   use inline layout string
  -h, --help         show this help
USAGE
}

tpane_file_has_diagram() {
  local path=$1
  # Has an explicit marker, or a comment line starting with a border char
  grep -qP '^[[:space:]]*#[[:space:]]*(tpane|[Ll]ayout):[[:space:]]*$|^[[:space:]]*#[[:space:]]*[+┌╔│║]' "$path" 2>/dev/null
}

tpane_extract_functions_from_script() {
  # Find function names defined in a script (excludes tpane_conf)
  local path=$1
  grep -oP '^[a-zA-Z_][a-zA-Z0-9_-]*(?=\s*\(\))' "$path" 2>/dev/null | grep -v '^tpane_conf$'
}

tpane_generate_auto_layout() {
  # Given a list of function names, generate a diagram string
  local -a names=("$@")
  local n=${#names[@]}
  (( n > 0 )) || return 1

  local cols rows
  if (( n == 1 )); then
    cols=1; rows=1
  elif (( n == 2 )); then
    cols=2; rows=1
  elif (( n == 3 )); then
    cols=3; rows=1
  elif (( n == 4 )); then
    cols=2; rows=2
  elif (( n <= 6 )); then
    cols=3; rows=$(( (n + 2) / 3 ))
  elif (( n <= 8 )); then
    cols=4; rows=$(( (n + 3) / 4 ))
  else
    cols=4; rows=$(( (n + 3) / 4 ))
  fi

  # Cell width (inner, not counting borders)
  local cw=14
  local i=0 r c line

  TPANE_DIAGRAM_LINES=()

  # Top border
  line="┌"
  for ((c=0; c<cols; c++)); do
    (( c > 0 )) && line+="┬"
    line+=$(tpane_repeat_char "─" "$cw")
  done
  line+="┐"
  TPANE_DIAGRAM_LINES+=("$line")

  for ((r=0; r<rows; r++)); do
    # Content row
    line="│"
    for ((c=0; c<cols; c++)); do
      (( c > 0 )) && line+="│"
      if (( i < n )); then
        local name=${names[i]}
        local pad=$(( cw - ${#name} ))
        local lpad=$(( pad / 2 ))
        local rpad=$(( pad - lpad ))
        line+="$(tpane_repeat_char ' ' "$lpad")${name}$(tpane_repeat_char ' ' "$rpad")"
      else
        line+="$(tpane_repeat_char ' ' "$cw")"
      fi
      ((i++)) || true
    done
    line+="│"
    TPANE_DIAGRAM_LINES+=("$line")

    # Row separator or bottom border
    if (( r < rows - 1 )); then
      line="├"
      for ((c=0; c<cols; c++)); do
        (( c > 0 )) && line+="┼"
        line+=$(tpane_repeat_char "─" "$cw")
      done
      line+="┤"
    else
      line="└"
      for ((c=0; c<cols; c++)); do
        (( c > 0 )) && line+="┴"
        line+=$(tpane_repeat_char "─" "$cw")
      done
      line+="┘"
    fi
    TPANE_DIAGRAM_LINES+=("$line")
  done
}

tpane_session_name_from_path() {
  local base
  base=$(basename "$1")
  base=${base%.*}
  printf '%s' "$base"
}

tpane_main() {
  tpane_parse_args "$@"

  # Default session name: script filename without extension, or "tpane"
  if [[ -z $TPANE_SESSION_NAME ]]; then
    if [[ -n ${TPANE_SCRIPT_PATH:-} ]]; then
      TPANE_SESSION_NAME=$(tpane_session_name_from_path "$TPANE_SCRIPT_PATH")
    else
      TPANE_SESSION_NAME=tpane
    fi
  fi

  tpane_require_tmux || exit 1

  # Load diagram
  if [[ -n $TPANE_LAYOUT_STR ]]; then
    tpane_extract_diagram_from_string "$TPANE_LAYOUT_STR" || exit 1
  elif [[ -n $TPANE_SCRIPT_PATH ]]; then
    if tpane_file_has_diagram "$TPANE_SCRIPT_PATH"; then
      tpane_extract_diagram_from_script "$TPANE_SCRIPT_PATH" || exit 1
    else
      # No diagram found — try auto-layout from function names
      local -a _auto_funcs=()
      while IFS= read -r fn; do
        [[ -n $fn ]] && _auto_funcs+=("$fn")
      done < <(tpane_extract_functions_from_script "$TPANE_SCRIPT_PATH")

      if (( ${#_auto_funcs[@]} > 0 )); then
        tpane_generate_auto_layout "${_auto_funcs[@]}"
      else
        tpane_extract_diagram_from_layout_file "$TPANE_SCRIPT_PATH" || exit 1
      fi
    fi
  fi

  # Parse
  tpane_parse_diagram TPANE_DIAGRAM_LINES || exit 1
  tpane_build_tree || exit 1
  tpane_compute_node_sizes "$TPANE_ROOT_NODE" || exit 1

  # Resolve commands
  tpane_resolve_commands "${TPANE_SCRIPT_PATH:-}" "${TPANE_DIR:-}" "$TPANE_STRICT" || exit 1

  # Preview / dry-run
  if (( TPANE_PREVIEW )); then
    tpane_print_preview
    exit 0
  fi

  if (( TPANE_DRY_RUN )); then
    echo "dry-run: would create tmux session '$TPANE_SESSION_NAME'"
    tpane_print_preview
    exit 0
  fi

  # Launch tmux
  tmux kill-session -t "$TPANE_SESSION_NAME" 2>/dev/null || true
  tmux new-session -d -s "$TPANE_SESSION_NAME" -n "$TPANE_SESSION_NAME" -x "$(tput cols)" -y "$(tput lines)" || exit 1
  if (( TPANE_LABELS )); then
    tmux set-option -t "$TPANE_SESSION_NAME" pane-border-status top 2>/dev/null || true
    tmux set-option -t "$TPANE_SESSION_NAME" pane-border-format ' #{pane_title} ' 2>/dev/null || true
  fi
  tmux set-window-option -t "$TPANE_SESSION_NAME" automatic-rename off 2>/dev/null || true
  local first_pane
  first_pane=$(tmux display-message -p -t "$TPANE_SESSION_NAME:0.0" '#{pane_id}') || exit 1

  tpane_apply_node_to_tmux_pane "$TPANE_ROOT_NODE" "$first_pane" || exit 1

  # Source the script to pick up tpane_conf if defined
  if [[ -n ${TPANE_SCRIPT_PATH:-} ]]; then
    # shellcheck disable=SC1090
    source "$TPANE_SCRIPT_PATH" 2>/dev/null || true
  fi
  if declare -F tpane_conf >/dev/null 2>&1; then
    tpane_conf "$TPANE_SESSION_NAME"
  fi

  if [[ -n ${TMUX:-} ]]; then
    tmux switch-client -t "$TPANE_SESSION_NAME"
  else
    tmux attach-session -t "$TPANE_SESSION_NAME"
  fi
}

# Run as CLI only when executed directly (not when sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  tpane_main "$@"
fi

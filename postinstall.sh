#!/usr/bin/env bash
# postinstall: check for tmux and bash 4+, suggest install commands if missing

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

ok=true

# Check bash version
bash_version="${BASH_VERSINFO[0]:-0}"
if [[ $bash_version -lt 4 ]]; then
  ok=false
  printf "${YELLOW}⚠  bash 4+ is required${RESET} (found bash %s)\n" "$BASH_VERSION"
  if [[ "$OSTYPE" == darwin* ]]; then
    printf "   Install with: ${BOLD}brew install bash${RESET}\n"
  elif command -v apt-get &>/dev/null; then
    printf "   Install with: ${BOLD}sudo apt install bash${RESET}\n"
  elif command -v dnf &>/dev/null; then
    printf "   Install with: ${BOLD}sudo dnf install bash${RESET}\n"
  elif command -v pacman &>/dev/null; then
    printf "   Install with: ${BOLD}sudo pacman -S bash${RESET}\n"
  fi
fi

# Check tmux
if ! command -v tmux &>/dev/null; then
  ok=false
  printf "${YELLOW}⚠  tmux is not installed${RESET}\n"
  if [[ "$OSTYPE" == darwin* ]]; then
    printf "   Install with: ${BOLD}brew install tmux${RESET}\n"
  elif command -v apt-get &>/dev/null; then
    printf "   Install with: ${BOLD}sudo apt install tmux${RESET}\n"
  elif command -v dnf &>/dev/null; then
    printf "   Install with: ${BOLD}sudo dnf install tmux${RESET}\n"
  elif command -v pacman &>/dev/null; then
    printf "   Install with: ${BOLD}sudo pacman -S tmux${RESET}\n"
  elif command -v apk &>/dev/null; then
    printf "   Install with: ${BOLD}apk add tmux${RESET}\n"
  else
    printf "   Install tmux using your system package manager.\n"
  fi
else
  tmux_ver=$(tmux -V 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)*')
  printf "${GREEN}✓${RESET}  tmux %s found\n" "$tmux_ver"
fi

if $ok; then
  printf "${GREEN}✓${RESET}  tpane is ready to use\n"
fi
#!/usr/bin/env bash

set -m

export CONSOLE_ID="session_${RANDOM}_$(date +%s)"
CMD_FILE="/tmp/nvim_console_cmd_${CONSOLE_ID}"

nvim --clean -u init.lua "$@" &
NVIM_PID=$!

fg %1

while kill -0 $NVIM_PID 2>/dev/null; do
  FOUND=0

  for i in {1..10}; do
    if [ -f "$CMD_FILE" ]; then
      FOUND=1
      break
    fi
    sleep 0.05
  done

  if [ $FOUND -eq 1 ]; then
    CMD=$(cat "$CMD_FILE")
    rm "$CMD_FILE"
    eval "$CMD"
    fg %1
  else
    break
  fi
done

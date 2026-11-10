#!/bin/bash
# Commands keep their normal stdout/stderr; progress never includes arguments or secrets.
step() {
  local label="$1" started=$SECONDS result=0 worker ticker
  shift
  printf '▶ %s\n' "$label"
  "$@" &
  worker=$!
  (
    while kill -0 "$worker" 2>/dev/null; do
      sleep 5
      kill -0 "$worker" 2>/dev/null || break
      printf '  … %s — %s s\n' "$label" "$((SECONDS - started))"
    done
  ) &
  ticker=$!
  wait "$worker" || result=$?
  kill "$ticker" 2>/dev/null || true
  wait "$ticker" 2>/dev/null || true
  if [[ "$result" == 0 ]]; then
    printf '✓ %s — %s s\n' "$label" "$((SECONDS - started))"
  else
    printf '✗ %s — error %s, %s s\n' "$label" "$result" "$((SECONDS - started))" >&2
  fi
  return "$result"
}

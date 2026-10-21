#!/bin/sh
set -e
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$DIR"
if command -v python3 >/dev/null 2>&1; then
  PY=python3
elif [ -x /Users/jt/.workbuddy-ai/binaries/python/versions/3.13.12/bin/python3 ]; then
  PY=/Users/jt/.workbuddy-ai/binaries/python/versions/3.13.12/bin/python3
else
  echo "需要 Python 3.10 或更高版本" >&2
  exit 1
fi
exec "$PY" -m macapp "$@"

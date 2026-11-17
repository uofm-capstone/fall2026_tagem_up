#!/bin/sh
set -e

if [ -f tmp/pids/server.pid ]; then
  echo "Removing stale server PID file..."
  rm tmp/pids/server.pid
fi

exec "$@"
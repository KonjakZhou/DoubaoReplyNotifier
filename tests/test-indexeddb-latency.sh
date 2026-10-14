#!/bin/bash
set -euo pipefail
# Compatibility wrapper: interaction immediacy is proven by native Saman toolcall lifecycle,
# not by synthetic IndexedDB byte ordering. The real WAL parser has a separate fixture test.
ROOT="$(cd "$(dirname "$0")" && pwd)"
exec /bin/bash "$ROOT/test-native-toolcall.sh" "$@"

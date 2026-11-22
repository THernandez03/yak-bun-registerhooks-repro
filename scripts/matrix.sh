#!/usr/bin/env bash
# Installer x runtime comparison for the yak registerHooks crash.
#
# For each installer (bun, npm, pnpm, yarn) this copies the app into its own
# directory under $MATRIX_DIR, installs there, then runs `vite build` and a
# dev start under Bun and under Node, and prints two Markdown tables.
#
# Prerequisites: bash, mktemp, timeout, sha256sum (or shasum). The installers and
# runtimes (bun, node, npm, pnpm, yarn) are optional: a missing one is skipped.
# The script installs no package manager and sets no HOME or cache variable;
# export those yourself if you want the run isolated from your own setup.
#
# Environment:
#   MATRIX_DIR      empty or absent directory for the copies and logs
#                   (default: a fresh mktemp -d)
#   PORT_BASE       first dev-server port, incremented per run (default 5200)
#   PNPM_STORE_DIR  passed to every `pnpm install` as --store-dir when set
#
# Files written into a copy only (never into the repro):
#   yarn: .yarnrc.yml (nodeLinker: node-modules) and an empty yarn.lock
#   pnpm: pnpm-workspace.yaml (strictDepBuilds: false). Without it pnpm 12 exits 1
#         with ERR_PNPM_IGNORED_BUILDS for @swc/core's install script. The script
#         still stays ignored, as with Bun's default.
#   bun:  bun.lock is copied too, so Bun installs what the repro committed

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_FILES=(package.json vite.config.ts index.html src/main.tsx)

for c in bash mktemp timeout; do
  command -v "$c" >/dev/null 2>&1 || { echo "missing prerequisite: $c" >&2; exit 2; }
done
if command -v sha256sum >/dev/null 2>&1; then
  sha() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  echo "missing prerequisite: sha256sum (or shasum)" >&2
  exit 2
fi

MATRIX_DIR="${MATRIX_DIR:-$(mktemp -d)}"
mkdir -p "$MATRIX_DIR"
if [ -n "$(ls -A "$MATRIX_DIR")" ]; then
  echo "MATRIX_DIR must be empty: $MATRIX_DIR" >&2
  exit 2
fi
MATRIX_DIR="$(cd "$MATRIX_DIR" && pwd)"
LOGS="$MATRIX_DIR/logs"
mkdir -p "$LOGS"
PORT="${PORT_BASE:-5200}"

redact() { sed -e "s#$MATRIX_DIR#<matrix>#g" -e 's#|#\\|#g'; }

# First error line of a log: prefer "Error: ...", else any "error" line.
first_error() {
  local line
  line="$(grep -m1 -E 'Error:' "$1" || true)"
  [ -n "$line" ] || line="$(grep -m1 -i 'error' "$1" || true)"
  [ -n "$line" ] || line="(no error line)"
  printf '%s' "$line" | redact
}

# Runtime named by the config's first statement.
runtime_of() {
  local line
  line="$(grep -m1 '^runtime: ' "$1" || true)"
  [ -n "$line" ] && printf '%s' "${line#runtime: }" || printf 'n/a (config not loaded)'
}

version_of() { grep -m1 '"version"' "$1/package.json" 2>/dev/null | sed -E 's/.*"version": *"([^"]*)".*/\1/'; }

tool_version() {
  case "$1" in
    bun) bun --revision 2>/dev/null | head -1 ;;
    node) node --version 2>/dev/null ;;
    *) "$1" --version 2>/dev/null | head -1 ;;
  esac
}

declare -A INST_STATUS INST_EXIT INST_LAYOUT INST_YAK INST_VITE INST_SHA INST_VER INST_CMD
declare -A RT_VER
ROWS=""
EXTRA=""

for rt in bun node; do
  if command -v "$rt" >/dev/null 2>&1; then RT_VER[$rt]="$(tool_version "$rt")"; else RT_VER[$rt]=""; fi
done

run_build() { # dir label cmd...
  local dir="$1" label="$2"; shift 2
  local log="$LOGS/$label.log"
  (cd "$dir" && timeout -k 5 180 "$@" >"$log" 2>&1)
  BUILD_EXIT=$?
  BUILD_RT="$(runtime_of "$log")"
  if [ "$BUILD_EXIT" -eq 0 ]; then BUILD_CELL="exit 0"; else BUILD_CELL="exit $BUILD_EXIT: $(first_error "$log")"; fi
  rm -rf "$dir/dist"
}

run_dev() { # dir label cmd...
  local dir="$1" label="$2"; shift 2
  local log="$LOGS/$label.log" port="$PORT" pid i
  PORT=$((PORT + 1))
  (cd "$dir" && exec timeout -k 3 30 "$@" --host 127.0.0.1 --port "$port" --strictPort >"$log" 2>&1) &
  pid=$!
  for ((i = 0; i < 70; i++)); do
    grep -q 'ready in' "$log" 2>/dev/null && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  if grep -q 'ready in' "$log" 2>/dev/null; then DEV_CELL="ready"; else
    kill "$pid" 2>/dev/null
    DEV_CELL="no ready line: $(first_error "$log")"
  fi
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  DEV_RT="$(runtime_of "$log")"
}

for inst in bun npm pnpm yarn; do
  if ! command -v "$inst" >/dev/null 2>&1; then
    INST_STATUS[$inst]="skipped"
    echo "skipped installer (not on PATH): $inst" >&2
    continue
  fi
  INST_VER[$inst]="$(tool_version "$inst")"
  dir="$MATRIX_DIR/$inst"
  mkdir -p "$dir/src"
  for f in "${APP_FILES[@]}"; do cp "$ROOT/$f" "$dir/$f"; done
  shown=""
  case "$inst" in
    bun) cp "$ROOT/bun.lock" "$dir/bun.lock"; cmd=(bun install) ;;
    npm) cmd=(npm install) ;;
    pnpm)
      printf 'strictDepBuilds: false\n' >"$dir/pnpm-workspace.yaml"
      cmd=(pnpm install)
      shown="pnpm install"
      if [ -n "${PNPM_STORE_DIR:-}" ]; then
        cmd+=(--store-dir "$PNPM_STORE_DIR")
        shown='pnpm install --store-dir "$PNPM_STORE_DIR"'
      fi
      ;;
    yarn)
      printf 'nodeLinker: node-modules\n' >"$dir/.yarnrc.yml"
      : >"$dir/yarn.lock"
      cmd=(yarn install)
      ;;
  esac
  INST_CMD[$inst]="${shown:-${cmd[*]}}"
  echo "installing: $inst (${INST_VER[$inst]})" >&2
  (cd "$dir" && timeout -k 5 300 "${cmd[@]}" >"$LOGS/$inst-install.log" 2>&1)
  INST_EXIT[$inst]=$?
  if [ "${INST_EXIT[$inst]}" -ne 0 ] || [ ! -f "$dir/node_modules/@yak/react/package.json" ]; then
    INST_STATUS[$inst]="failed"
    INST_LAYOUT[$inst]="n/a"
    INST_YAK[$inst]="n/a"; INST_VITE[$inst]="n/a"; INST_SHA[$inst]="n/a"
  else
    INST_STATUS[$inst]="ok"
    if [ -d "$dir/node_modules/.pnpm" ]; then INST_LAYOUT[$inst]="symlinked, content-addressed store (node_modules/.pnpm)"
    elif [ -d "$dir/node_modules/.bun" ]; then INST_LAYOUT[$inst]="isolated (node_modules/.bun)"
    elif [ -f "$dir/node_modules/.yarn-state.yml" ]; then INST_LAYOUT[$inst]="flat, nodeLinker node-modules"
    else INST_LAYOUT[$inst]="flat (hoisted)"; fi
    INST_YAK[$inst]="$(version_of "$dir/node_modules/@yak/react")"
    INST_VITE[$inst]="$(version_of "$dir/node_modules/vite")"
    INST_SHA[$inst]="$(sha "$dir/node_modules/@yak/react/dist/isolated-source-eval/worker.js")"
  fi

  for rt in bun node; do
    if [ -z "${RT_VER[$rt]}" ]; then
      ROWS+="| $inst ${INST_VER[$inst]} | $rt | skipped (runtime not on PATH) | skipped (runtime not on PATH) |"$'\n'
      continue
    fi
    if [ "${INST_STATUS[$inst]}" != ok ]; then
      ROWS+="| $inst ${INST_VER[$inst]} | $rt ${RT_VER[$rt]} | not evaluable (install failed) | not evaluable (install failed) |"$'\n'
      continue
    fi
    if [ "$rt" = bun ]; then rcmd=(bun --bun node_modules/vite/bin/vite.js); else rcmd=(node node_modules/vite/bin/vite.js); fi
    echo "running: $inst / $rt" >&2
    run_build "$dir" "$inst-$rt-build" "${rcmd[@]}" build
    b="$BUILD_CELL"; brt="$BUILD_RT"
    run_dev "$dir" "$inst-$rt-dev" "${rcmd[@]}"
    ROWS+="| $inst ${INST_VER[$inst]} | $brt | $b | $DEV_CELL |"$'\n'
  done
done

# The commands a user types, in the Bun-installed tree.
if [ "${INST_STATUS[bun]:-}" = ok ] && command -v bunx >/dev/null 2>&1; then
  for variant in "bunx --bun vite build" "bunx vite build"; do
    label="bunx-$(printf '%s' "$variant" | tr -c 'a-z' '-')"
    # shellcheck disable=SC2086
    run_build "$MATRIX_DIR/bun" "$label" $variant
    EXTRA+="| bun ${INST_VER[bun]} | \`$variant\` | $BUILD_RT | $BUILD_CELL |"$'\n'
  done
else
  EXTRA+="| bun | \`bunx ...\` | n/a | not evaluable or skipped |"$'\n'
fi

echo
echo "### Table 1: installer by runtime"
echo
echo "| installer | runtime (from config log line) | build | dev start |"
echo "|---|---|---|---|"
printf '%s' "$ROWS"
echo
echo "### Table 1b: commands a user types (Bun-installed tree)"
echo
echo "| installer | command | runtime (from config log line) | result |"
echo "|---|---|---|---|"
printf '%s' "$EXTRA"
echo
echo "### Table 2: install layer"
echo
echo "| installer | install command | install exit | layout | @yak/react | vite | worker.js sha256 |"
echo "|---|---|---|---|---|---|---|"
for inst in bun npm pnpm yarn; do
  if [ "${INST_STATUS[$inst]}" = skipped ]; then
    echo "| $inst | n/a | skipped (not on PATH) | n/a | n/a | n/a | n/a |"
  else
    echo "| $inst ${INST_VER[$inst]} | \`${INST_CMD[$inst]}\` | ${INST_EXIT[$inst]} | ${INST_LAYOUT[$inst]} | ${INST_YAK[$inst]} | ${INST_VITE[$inst]} | \`${INST_SHA[$inst]}\` |"
  fi
done
echo
echo "Logs: <matrix>/logs"

#!/usr/bin/env bash
# >>> remote node: port wiring (generated) >>>
# Browser-facing backend URLs must use the port the node publishes, not the app's own.
__rn_root="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [ -n "${PUBLIC_HOST:-}" ]; then __rn_host="$PUBLIC_HOST"; else __rn_host='\2'; fi
find "$__rn_root" -maxdepth 3 -type f -name '.env*' -not -path '*/node_modules/*' 2>/dev/null |
  while IFS= read -r __rn_f; do
    sed -i -E "s#(https?://)(localhost|127\.0\.0\.1|0\.0\.0\.0):8002([^0-9]|\$)#\1${__rn_host}:${BACKEND_HOST_PORT:-8002}\3#g" "$__rn_f"
  done
# <<< remote node <<<
#
# CodeshastraXI Entropy - one-shot runner (Linux / macOS / Git Bash)
#
#   ./run.sh    Installs dependencies (only when they changed), then starts the
#               backend and frontend. Ctrl+C stops both.
#
# Required before start:
#   GOOGLE_API_KEY in backend/.env (Gemini - https://aistudio.google.com/app/apikey)
# Recommended for full chat features:
#   GOOGLE_GENERATIVE_AI_API_KEY and GROQ_API_KEY in frontend/.env.local
#
# Hosts and ports are set only in this file (see below) and passed to both services.
#

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$ROOT/backend"
FRONTEND_DIR="$ROOT/frontend"
LOG_DIR="$ROOT/logs"
VENV_DIR="$BACKEND_DIR/venv"

# ================================================================ settings ===
# The single place to change hosts and ports.

# Listen address: 127.0.0.1 on a normal machine (not "localhost", which may
# resolve to IPv6 ::1 only), 0.0.0.0 inside Docker so published ports reach it.
if [ -f /.dockerenv ]; then LISTEN_HOST=0.0.0.0; else LISTEN_HOST=127.0.0.1; fi
LISTEN_HOST="${BIND_HOST:-$LISTEN_HOST}"

# ---- Backend (FastAPI / uvicorn) ----
BACKEND_HOST="$LISTEN_HOST"      # address uvicorn listens on (0.0.0.0 = all interfaces)
BACKEND_PORT="${BACKEND_PORT:-8002}"                # port uvicorn listens on
BACKEND_URL="http://${PUBLIC_HOST:-localhost}:${BACKEND_HOST_PORT:-$BACKEND_PORT}"    # address browsers use to reach the backend

# ---- Frontend (Next.js) ----
FRONTEND_HOST="$LISTEN_HOST"     # address Next.js listens on (0.0.0.0 = all interfaces)
FRONTEND_PORT="${PORT:-3000}"               # port Next.js listens on
FRONTEND_URL="http://${PUBLIC_HOST:-localhost}:${FRONTEND_HOST_PORT:-$FRONTEND_PORT}"  # address browsers use to open the app

# Env vars each service receives at start (nothing is written to .env files).
BACKEND_ENV=(PUBLIC_API_URL="$BACKEND_URL")
FRONTEND_ENV=(NEXT_PUBLIC_API_URL="$BACKEND_URL" NEXT_PUBLIC_APP_URL="$FRONTEND_URL")
# =============================================================================

# numpy==1.26.2 and torch==2.6.0 in requirements.txt only ship wheels for 3.10-3.12.
PY_MIN_MINOR=10
PY_MAX_MINOR=12

# Python writes emoji/unicode to redirected logs; cp1252 on Windows would crash on that.
export PYTHONUTF8=1

OS_NAME="$(uname -s 2>/dev/null || echo unknown)"
case "$OS_NAME" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;;
  *) IS_WINDOWS=0 ;;
esac

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[36m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""
fi

step() { printf '%s==>%s %s%s%s\n' "$C_BLUE" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
ok()   { printf '%s  ok%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
info() { printf '     %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
warn() { printf '%s   !%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
die()  { printf '%sfail%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# ------------------------------------------------------------------ python ---
# Prints "3.x" if "$@" is a supported Python, fails otherwise.
python_version() {
  local v minor
  v="$("$@" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)" || return 1
  v="${v%$'\r'}"
  minor="${v#3.}"
  [[ "$v" == 3.* && "$minor" =~ ^[0-9]+$ ]] || return 1
  [ "$minor" -ge "$PY_MIN_MINOR" ] && [ "$minor" -le "$PY_MAX_MINOR" ] || return 1
  echo "$v"
}

# Sets PY_CMD to a supported interpreter command.
find_python() {
  PY_CMD=()
  local minor c
  # Ask the py launcher (Windows) for a specific version - its default may be too new.
  if command -v py >/dev/null 2>&1; then
    for ((minor = PY_MAX_MINOR; minor >= PY_MIN_MINOR; minor--)); do
      if python_version py "-3.$minor" >/dev/null; then PY_CMD=(py "-3.$minor"); return 0; fi
    done
  fi
  for ((minor = PY_MAX_MINOR; minor >= PY_MIN_MINOR; minor--)); do
    c="python3.$minor"
    if command -v "$c" >/dev/null 2>&1 && python_version "$c" >/dev/null; then PY_CMD=("$c"); return 0; fi
  done
  for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1 && python_version "$c" >/dev/null; then PY_CMD=("$c"); return 0; fi
  done
  return 1
}

venv_python() {
  # Windows venvs use Scripts/, POSIX ones bin/.
  if [ -x "$VENV_DIR/Scripts/python.exe" ]; then
    echo "$VENV_DIR/Scripts/python.exe"
  else
    echo "$VENV_DIR/bin/python"
  fi
}

file_sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

read_stamp() { [ -f "$1" ] && tr -d '[:space:]' <"$1" || true; }

env_value() {
  local path="$1" key="$2" line val
  [ -f "$path" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key"=*)
        val="${line#"$key="}"
        val="${val%%$'\r'}"
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"
        [ -n "$val" ] && printf '%s' "$val"
        ;;
    esac
  done <"$path"
}

# Both env files must already exist; this script only reads them.
check_env_files() {
  step "Environment files"
  local backend_env="$BACKEND_DIR/.env" frontend_env="$FRONTEND_DIR/.env.local" missing=0

  if [ -f "$backend_env" ]; then ok "backend/.env found"
  else warn "backend/.env not found - create it with GOOGLE_API_KEY (and optionally LLAMACLOUD_API_KEY, FIRECRAWL_API_KEY)"; missing=1
  fi
  if [ -f "$frontend_env" ]; then ok "frontend/.env.local found"
  else warn "frontend/.env.local not found - create it with GOOGLE_GENERATIVE_AI_API_KEY (and optionally GROQ_API_KEY)"; missing=1
  fi
  [ "$missing" -eq 0 ] || die "missing env file(s) - see above"

  [ -n "$(env_value "$backend_env" GOOGLE_API_KEY)" ]     || die "GOOGLE_API_KEY is empty in backend/.env (get one at https://aistudio.google.com/app/apikey)"
  local key
  for key in LLAMACLOUD_API_KEY FIRECRAWL_API_KEY; do
    [ -n "$(env_value "$backend_env" "$key")" ] || warn "backend/.env: $key is empty"
  done
  for key in GOOGLE_GENERATIVE_AI_API_KEY GROQ_API_KEY; do
    [ -n "$(env_value "$frontend_env" "$key")" ] || warn "frontend/.env.local: $key is empty"
  done
}

# ----------------------------------------------------------------- install ---
install_backend() {
  step "Backend (Python)"
  local vpy
  vpy="$(venv_python)"

  if [ -x "$vpy" ] && ! python_version "$vpy" >/dev/null; then
    warn "backend/venv uses an unsupported Python - recreating it"
    rm -rf "$VENV_DIR"
  fi

  vpy="$(venv_python)"
  if [ ! -x "$vpy" ]; then
    find_python || die "Python 3.$PY_MIN_MINOR-3.$PY_MAX_MINOR not found (3.13+ cannot install the torch/numpy pins). Install Python 3.11 and re-run."
    ok "using Python $(python_version "${PY_CMD[@]}") (${PY_CMD[*]})"
    info "creating virtualenv backend/venv"
    "${PY_CMD[@]}" -m venv "$VENV_DIR" || die "could not create the virtualenv"
    vpy="$(venv_python)"
    [ -x "$vpy" ] || die "the virtualenv looks broken - delete backend/venv and re-run"
  else
    ok "backend/venv present (Python $(python_version "$vpy"))"
  fi

  local stamp="$VENV_DIR/.requirements.sha" want
  want="$(file_sha "$BACKEND_DIR/requirements.txt")"
  if [ "$want" = "$(read_stamp "$stamp")" ]; then
    ok "Python dependencies already installed"
    return 0
  fi

  info "installing Python dependencies (torch, transformers, spacy ... this takes a while)"
  "$vpy" -m pip install --upgrade pip --quiet --disable-pip-version-check
  "$vpy" -m pip install -r "$BACKEND_DIR/requirements.txt" --disable-pip-version-check \
    || die "pip install failed - see the output above"

  local spacy_stamp="$VENV_DIR/.spacy.en_core_web_sm"
  if [ ! -f "$spacy_stamp" ]; then
    info "downloading spacy language model en_core_web_sm (used by llm-guard)"
    if "$vpy" -m spacy download en_core_web_sm --quiet; then
      echo 1 >"$spacy_stamp"
    else
      warn "spacy model download failed - llm-guard may download it on first use"
    fi
  fi

  echo "$want" >"$stamp"
  ok "Python dependencies installed"
}

install_frontend() {
  step "Frontend (Node)"
  command -v node >/dev/null 2>&1 || die "node not found. Install Node.js 18.18+ from https://nodejs.org and re-run."
  command -v npm >/dev/null 2>&1 || die "npm not found. Install Node.js 18.18+ from https://nodejs.org and re-run."
  local node_version node_major
  node_version="$(node --version | tr -d '\r')"
  node_major="${node_version#v}"; node_major="${node_major%%.*}"
  [ "$node_major" -ge 18 ] 2>/dev/null || die "Node $node_version is too old for Next.js 15 - install Node 18.18+ (20 LTS recommended)."
  ok "using node $node_version"

  local stamp="$FRONTEND_DIR/node_modules/.install.sha" want
  want="$(file_sha "$FRONTEND_DIR/package.json")"
  if [ "$want" = "$(read_stamp "$stamp")" ]; then
    ok "node_modules up to date"
    return 0
  fi

  info "running npm install in frontend"
  # React 19 RC builds don't satisfy most libraries' peer ranges.
  (cd "$FRONTEND_DIR" && npm install --legacy-peer-deps --no-audit --no-fund) \
    || die "npm install failed - see the output above"
  echo "$want" >"$stamp"
  ok "frontend dependencies installed"
}

# ------------------------------------------------------------------- ports ---
port_open() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1
}

pids_on_port() {
  local port="$1"
  if [ "$IS_WINDOWS" -eq 1 ]; then
    netstat -ano 2>/dev/null | tr -d '\r' \
      | grep -E "[:.]${port}[[:space:]].*LISTENING" \
      | awk '{print $NF}' | grep -E '^[1-9][0-9]*$' | sort -u
  elif command -v lsof >/dev/null 2>&1; then
    lsof -ti "tcp:$port" -sTCP:LISTEN 2>/dev/null | sort -u
  elif command -v fuser >/dev/null 2>&1; then
    fuser "$port/tcp" 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$'
  fi
}

# Kills everything listening on a port. netstat/lsof report native PIDs; on Git Bash those need taskkill.
kill_port() {
  local pid
  for pid in $(pids_on_port "$1"); do
    if [ "$IS_WINDOWS" -eq 1 ]; then taskkill //T //F //PID "$pid" >/dev/null 2>&1
    else kill -9 "$pid" >/dev/null 2>&1
    fi
  done
}

# ---------------------------------------------------------------- services ---
SERVICES=()   # one "name pid port" entry per started service

show_log_tail() {
  local log="$LOG_DIR/$1.log"
  if [ -s "$log" ]; then
    printf '%s----- last lines of logs/%s.log -----%s
' "$C_DIM" "$1" "$C_RESET"
    tail -n 25 "$log" | sed 's/^/  /'
  fi
}

# start_service NAME PORT TIMEOUT DIR CMD... - frees the port, starts CMD in the background
# and waits until the port answers (TIMEOUT in seconds, 0 = wait forever).
start_service() {
  local name="$1" port="$2" timeout="$3" dir="$4" pid waited=0
  shift 4
  if port_open "$port"; then
    warn "port $port ($name) is in use - stopping the old process"
    kill_port "$port"
    sleep 1
    ! port_open "$port" || die "port $port ($name) is still in use - free it and re-run"
  fi

  mkdir -p "$LOG_DIR"
  (cd "$dir" && exec "$@") >"$LOG_DIR/$name.log" 2>&1 &
  pid=$!
  SERVICES+=("$name $pid $port")
  info "$name starting (pid $pid) - logs/$name.log"

  until port_open "$port"; do
    if ! kill -0 "$pid" 2>/dev/null; then
      warn "$name exited before it started listening"
      show_log_tail "$name"
      exit 1
    fi
    if [ "$timeout" -gt 0 ] && [ "$waited" -ge "$timeout" ]; then
      warn "$name did not answer on 127.0.0.1:$port within ${timeout}s (it should listen on $LISTEN_HOST)"
      show_log_tail "$name"
      exit 1
    fi
    sleep 2
    waited=$((waited + 2))
  done
  ok "$name is up on port $port"
}

# Runs on exit. Children (node under npm, uvicorn workers) can outlive their parent, so free the ports too.
stop_services() {
  echo
  step "Stopping services"
  local entry name pid port
  for entry in ${SERVICES[@]+"${SERVICES[@]}"}; do
    read -r name pid port <<<"$entry"
    kill "$pid" >/dev/null 2>&1
    kill_port "$port"
  done
  ok "all services stopped"
}

start_all() {
  check_env_files
  install_backend
  install_frontend

  step "Starting services"
  trap stop_services EXIT
  trap 'exit 130' INT TERM

  info "the first start downloads embedding/guard models and ingests data - can take several minutes"
  start_service backend "$BACKEND_PORT" 0 "$BACKEND_DIR" env "${BACKEND_ENV[@]}" "$(venv_python)" -m uvicorn main:app --host "$BACKEND_HOST" --port "$BACKEND_PORT"

  start_service frontend "$FRONTEND_PORT" 0 "$FRONTEND_DIR" env "${FRONTEND_ENV[@]}" npm run dev -- --hostname "$FRONTEND_HOST" --port "$FRONTEND_PORT"

  echo
  echo "${C_BOLD}Everything is running${C_RESET}"
  printf ' %-12s %s\n' "App" "$FRONTEND_URL"
  printf ' %-12s %s/docs\n' "API docs" "$BACKEND_URL"
  printf ' %-12s %s\n' "Login" "admin / admin  (other seeded users: sujal, soham, surabhi, sagar)"
  printf ' %-12s %s\n' "Logs" "${C_DIM}$LOG_DIR${C_RESET}"
  echo
  echo "${C_BOLD}Press Ctrl+C to stop everything.${C_RESET}"

  local entry name pid port
  while sleep 2; do
    for entry in "${SERVICES[@]}"; do
      read -r name pid port <<<"$entry"
      if ! kill -0 "$pid" 2>/dev/null; then
        warn "$name stopped unexpectedly"
        show_log_tail "$name"
        exit 1
      fi
    done
  done
}

start_all

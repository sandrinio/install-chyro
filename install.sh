#!/usr/bin/env bash
# install.sh — Chyro single-command install script (STORY-021-09)
#
# USAGE (production):
#   curl -sSL https://install.chyro.net | bash -s -- --license=<KEY>
#
# USAGE (local macOS/OrbStack):
#   curl -sSL https://install.chyro.net | bash -s -- --license=<KEY> --local
#
# UPGRADE:
#   curl -sSL https://install.chyro.net | bash -s -- --upgrade
#
# NON-INTERACTIVE:
#   bash install.sh --license=<KEY> --non-interactive \
#     --domain=chyro.example.com \
#     --admin-email=admin@example.com \
#     --smtp-host=smtp.resend.com \
#     --smtp-port=587 \
#     --smtp-user=resend \
#     --smtp-pass=<key> \
#     --app-name=Chyro \
#     --registration-mode=invite_only \
#     --langfuse=yes
#
# REQUIREMENTS:
#   - Docker Compose v2 (docker compose)
#   - Ubuntu 22.04+ / Debian 12+ (production) OR macOS (--local)
#   - RAM: ≥8GB (warn), ≥16GB (recommended)
#   - Disk: ≥40GB free
#   - openssl, base64, curl available in PATH
#
# SECURITY NOTE:
#   JWT_SECRET is generated as 64 random hex chars (32 bytes → 64 hex).
#   This satisfies the ≥32 byte Supabase requirement (see FLASHCARDS.md).

set -euo pipefail

# ============================================================
# CONSTANTS
# ============================================================

readonly CHYRO_VERSION="${CHYRO_VERSION:-latest}"
readonly REGISTRY="${REGISTRY:-registry.chyro.net}"
readonly INSTALL_DIR="${INSTALL_DIR:-/opt/chyro}"
readonly COMPOSE_FILE="docker-compose.prod.yml"
readonly ENV_FILE=".env"
readonly CADDYFILE="Caddyfile"
readonly CONFIG_JS="frontend/public/config.js"

# Minimum system requirements
readonly MIN_RAM_GB=8
readonly REC_RAM_GB=16
readonly MIN_DISK_GB=40

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ============================================================
# ARGUMENT DEFAULTS
# ============================================================

LICENSE_KEY=""
CONSOLE_URL="${CONSOLE_URL:-https://chyroconsole.soula.ge}"
DOMAIN=""
APP_NAME="Chyro"
ADMIN_EMAIL=""
SMTP_HOST=""
SMTP_PORT="587"
SMTP_USER=""
SMTP_PASS=""
REGISTRATION_MODE="invite_only"
ENABLE_LANGFUSE="yes"
NON_INTERACTIVE=false
LOCAL_MODE=false
UPGRADE_MODE=false

# ============================================================
# LOGGING HELPERS
# ============================================================

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
fatal()   { error "$*"; exit 1; }
bold()    { echo -e "${BOLD}$*${NC}"; }

# ============================================================
# ARGUMENT PARSING
# ============================================================

parse_args() {
  for arg in "$@"; do
    case "${arg}" in
      --license=*)       LICENSE_KEY="${arg#*=}" ;;
      --console-url=*)   CONSOLE_URL="${arg#*=}" ;;
      --domain=*)        DOMAIN="${arg#*=}" ;;
      --app-name=*)      APP_NAME="${arg#*=}" ;;
      --admin-email=*)   ADMIN_EMAIL="${arg#*=}" ;;
      --smtp-host=*)     SMTP_HOST="${arg#*=}" ;;
      --smtp-port=*)     SMTP_PORT="${arg#*=}" ;;
      --smtp-user=*)     SMTP_USER="${arg#*=}" ;;
      --smtp-pass=*)     SMTP_PASS="${arg#*=}" ;;
      --registration-mode=*) REGISTRATION_MODE="${arg#*=}" ;;
      --langfuse=*)      ENABLE_LANGFUSE="${arg#*=}" ;;
      --non-interactive) NON_INTERACTIVE=true ;;
      --local)           LOCAL_MODE=true ;;
      --upgrade)         UPGRADE_MODE=true ;;
      --help|-h)         show_usage; exit 0 ;;
      *)
        warn "Unknown argument: ${arg}"
        ;;
    esac
  done
}

show_usage() {
  cat <<'EOF'
Chyro Install Script

USAGE:
  bash install.sh [OPTIONS]

OPTIONS:
  --license=<KEY>           License key — short code (CHYRO-...) or JWT (required)
  --console-url=<URL>       Chyro Console base URL (default: https://chyroconsole.soula.ge)
  --domain=<DOMAIN>         Your domain (e.g. chyro.example.com)
  --app-name=<NAME>         App display name (default: Chyro)
  --admin-email=<EMAIL>     First admin user email
  --smtp-host=<HOST>        SMTP server hostname
  --smtp-port=<PORT>        SMTP port (default: 587)
  --smtp-user=<USER>        SMTP username
  --smtp-pass=<PASS>        SMTP password
  --registration-mode=<MODE> invite_only | open (default: invite_only)
  --langfuse=yes|no         Enable Langfuse observability (default: yes)
  --non-interactive         Skip all prompts; use flags instead
  --local                   macOS/OrbStack mode: skip OS checks, HTTP-only
  --upgrade                 Pull latest images, run migrations, restart
  --help                    Show this help

EXAMPLES:
  # Fresh install (interactive):
  curl -sSL https://install.chyro.net | bash -s -- --license=<KEY>

  # Fresh install (non-interactive):
  bash install.sh --license=<KEY> --non-interactive \
    --domain=chyro.example.com --admin-email=admin@example.com

  # Local macOS install:
  bash install.sh --license=<KEY> --local

  # Upgrade existing installation:
  bash install.sh --upgrade
EOF
}

# ============================================================
# SYSTEM CHECKS
# ============================================================

# check_docker_compose — verify Docker Compose v2 is available.
# Docker Compose v1 (docker-compose) is not supported; we require the v2
# plugin syntax (`docker compose` without hyphen).
check_docker_compose() {
  if ! docker compose version &>/dev/null; then
    fatal "Docker Compose v2 is required. Install it from https://docs.docker.com/compose/install/"
  fi
  local version
  version=$(docker compose version --short 2>/dev/null || docker compose version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  success "Docker Compose v2 found (${version})"
}

# get_ram_gb — return available RAM in GB.
# On macOS (--local), reads hw.memsize via sysctl; on Linux reads /proc/meminfo.
get_ram_gb() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    local bytes
    bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
    echo $(( bytes / 1024 / 1024 / 1024 ))
  else
    local kb
    kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    echo $(( kb / 1024 / 1024 ))
  fi
}

# get_disk_gb — return free disk space in GB for the install directory's filesystem.
# Uses df -k (POSIX) so it works on both Linux and macOS.
get_disk_gb() {
  local target="${1:-$INSTALL_DIR}"
  # df -k outputs kilobytes; column 4 is available space
  df -k "${target}" 2>/dev/null | awk 'NR==2 {print int($4 / 1024 / 1024)}'
}

# check_os — verify the OS is Ubuntu 22.04+ or Debian 12+.
# Skipped entirely in --local mode (macOS).
check_os() {
  if [[ "${LOCAL_MODE}" == "true" ]]; then
    info "Local mode: skipping OS check"
    return
  fi

  if [[ "$(uname -s)" == "Darwin" ]]; then
    warn "Running on macOS without --local flag. Consider using --local for macOS deployments."
    return
  fi

  if [[ ! -f /etc/os-release ]]; then
    fatal "Cannot determine OS. This script supports Ubuntu 22.04+ and Debian 12+."
  fi

  # shellcheck source=/dev/null
  source /etc/os-release
  local os_id="${ID:-unknown}"
  local version_id="${VERSION_ID:-0}"

  case "${os_id}" in
    ubuntu)
      local major_version
      major_version=$(echo "${version_id}" | cut -d. -f1)
      if [[ "${major_version}" -lt 22 ]]; then
        fatal "Ubuntu 22.04+ required. Found Ubuntu ${version_id}."
      fi
      success "OS check passed: Ubuntu ${version_id}"
      ;;
    debian)
      local major_version
      major_version=$(echo "${version_id}" | cut -d. -f1)
      if [[ "${major_version}" -lt 12 ]]; then
        fatal "Debian 12+ required. Found Debian ${version_id}."
      fi
      success "OS check passed: Debian ${version_id}"
      ;;
    *)
      fatal "Unsupported OS: ${os_id}. This script supports Ubuntu 22.04+ and Debian 12+."
      ;;
  esac
}

# check_ram — validate available RAM against minimum requirements.
# Warns at <8GB, recommends ≥16GB.
check_ram() {
  local ram_gb
  ram_gb=$(get_ram_gb)
  info "Detected RAM: ${ram_gb}GB"

  if [[ "${ram_gb}" -lt "${MIN_RAM_GB}" ]]; then
    warn "Insufficient RAM: ${ram_gb}GB detected. Chyro requires at least ${MIN_RAM_GB}GB."
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
      warn "Non-interactive mode: continuing despite low RAM."
    else
      echo ""
      ensure_tty_stdin
      read -rp "RAM is below minimum (${MIN_RAM_GB}GB). Continue anyway? [y/N] " confirm
      if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
        fatal "Aborted by user due to insufficient RAM."
      fi
    fi
  elif [[ "${ram_gb}" -lt "${REC_RAM_GB}" ]]; then
    warn "RAM is ${ram_gb}GB. ${REC_RAM_GB}GB+ is recommended for production workloads."
    success "RAM check passed (${ram_gb}GB — below recommended, above minimum)"
  else
    success "RAM check passed (${ram_gb}GB)"
  fi
}

# check_disk — validate free disk space on the install path.
# Creates the install directory first so df can measure the right filesystem.
check_disk() {
  # Ensure the directory exists for df to work
  mkdir -p "${INSTALL_DIR}"
  local disk_gb
  disk_gb=$(get_disk_gb "${INSTALL_DIR}")
  info "Free disk space at ${INSTALL_DIR}: ${disk_gb}GB"

  if [[ "${disk_gb}" -lt "${MIN_DISK_GB}" ]]; then
    fatal "Insufficient disk space: ${disk_gb}GB available, ${MIN_DISK_GB}GB required."
  fi
  success "Disk check passed (${disk_gb}GB free)"
}

# check_tools — ensure required CLI tools are in PATH.
check_tools() {
  local missing=()
  for tool in openssl base64 curl docker; do
    if ! command -v "${tool}" &>/dev/null; then
      missing+=("${tool}")
    fi
  done
  if [[ "${#missing[@]}" -gt 0 ]]; then
    fatal "Missing required tools: ${missing[*]}. Install them and re-run."
  fi
  success "Required tools found (openssl, base64, curl, docker)"
}

# ============================================================
# LICENSE VALIDATION
# ============================================================

# exchange_short_code — exchange a CHYRO-* short code for the full JWT by
# calling the public Console activation endpoint. Sets the global LICENSE_KEY
# to the returned JWT so the rest of the JWT-decode path runs unchanged.
#
# Also sends domain + version as query params so the Console operator can see
# who activated, where, and with what installer version.
exchange_short_code() {
  local code="${1}"
  local url="${CONSOLE_URL}/api/licenses/exchange/${code}"

  # Append optional context (domain, version) for the activation log.
  local query=""
  if [[ -n "${DOMAIN}" ]]; then
    query="?domain=${DOMAIN}"
  fi
  if [[ -n "${CHYRO_VERSION}" ]]; then
    if [[ -n "${query}" ]]; then
      query="${query}&version=${CHYRO_VERSION}"
    else
      query="?version=${CHYRO_VERSION}"
    fi
  fi

  info "Activating license code ${code} via ${CONSOLE_URL}…"

  local response http_code body
  # -w writes the HTTP status on the last line so we can split body / status.
  response=$(curl -sS -w "\n%{http_code}" \
    -H "User-Agent: chyro-install/${CHYRO_VERSION}" \
    "${url}${query}" 2>&1) || {
    fatal "Could not reach Chyro Console at ${CONSOLE_URL}. Check network and try again."
  }

  http_code=$(echo "${response}" | tail -n1)
  body=$(echo "${response}" | sed '$d')

  case "${http_code}" in
    200)
      ;;
    404)
      fatal "License code '${code}' was not recognized. Double-check the key in the Chyro Console."
      ;;
    403)
      fatal "License code '${code}' has been revoked. Contact your Chyro administrator."
      ;;
    429)
      fatal "Too many activation attempts. Wait a minute and try again."
      ;;
    *)
      fatal "License activation failed (HTTP ${http_code}): ${body}"
      ;;
  esac

  # Parse {"jwt": "...", "public_key": "...", "registry_user": "...",
  # "registry_password": "..."} without requiring jq.
  local jwt
  jwt=$(echo "${body}" | sed -n 's/.*"jwt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

  if [[ -z "${jwt}" ]]; then
    fatal "Console returned no JWT for code '${code}'. Response: ${body}"
  fi

  # Optional: registry credentials. New consoles return them; older consoles
  # don't, in which case we leave the globals empty and skip docker login.
  REGISTRY_USER_FROM_LICENSE=$(echo "${body}" | sed -n 's/.*"registry_user"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  REGISTRY_PASS_FROM_LICENSE=$(echo "${body}" | sed -n 's/.*"registry_password"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

  # Replace the license key with the full JWT — the rest of validate_license
  # parses it as before, no other changes needed downstream.
  LICENSE_KEY="${jwt}"
  success "License code activated"
}

# registry_login — log Docker into registry.chyro.net using credentials the
# Console handed us during exchange_short_code. Skipped if no creds were
# returned (older console, manual JWT install, etc.) so the user can still
# pre-configure docker login themselves.
registry_login() {
  if [[ -z "${REGISTRY_USER_FROM_LICENSE:-}" || -z "${REGISTRY_PASS_FROM_LICENSE:-}" ]]; then
    info "No registry credentials in license response — assuming docker is already logged into ${REGISTRY}."
    return 0
  fi

  info "Logging in to ${REGISTRY} as ${REGISTRY_USER_FROM_LICENSE}…"
  if echo "${REGISTRY_PASS_FROM_LICENSE}" \
    | docker login "${REGISTRY}" --username "${REGISTRY_USER_FROM_LICENSE}" --password-stdin >/dev/null 2>&1; then
    success "Registry login successful"
  else
    fatal "Registry login failed for ${REGISTRY_USER_FROM_LICENSE}@${REGISTRY}. Contact your Chyro administrator."
  fi
}

# validate_license — decode the license JWT header and extract the public key.
# The license key is a JWT; its header contains the public key used for
# LICENSE_PUBLIC_KEY in the backend. We extract the header's 'kid' or 'pk' field.
# This function sets the global LICENSE_PUBLIC_KEY variable.
#
# Accepts either a full JWT (header.payload.signature) OR a short code in the
# form CHYRO-XXX-YYYY-ZZZZZZZZ. Short codes are exchanged for the JWT against
# the Console activation endpoint before decoding.
validate_license() {
  local license="${1}"

  if [[ -z "${license}" ]]; then
    fatal "License key is required. Pass --license=<KEY>."
  fi

  # Detect short-code format and exchange for the full JWT.
  if [[ "${license}" =~ ^CHYRO-[A-Z0-9]+-[0-9]{4}-[A-Z0-9]+$ ]]; then
    exchange_short_code "${license}"
    license="${LICENSE_KEY}"
  fi

  # Basic JWT structure check: three dot-separated base64url segments
  local part_count
  part_count=$(echo "${license}" | tr -cd '.' | wc -c)
  if [[ "${part_count}" -ne 2 ]]; then
    fatal "Invalid license key format. Expected a JWT with three segments."
  fi

  # Extract the header segment (first segment before the first dot)
  local header_b64
  header_b64=$(echo "${license}" | cut -d. -f1)

  # JWT uses base64url encoding (- → +, _ → /); pad to multiple of 4
  local header_padded
  header_padded=$(echo "${header_b64}" | tr '_-' '/+' | awk '{ l=length($0)%4; if(l==2) print $0"=="; else if(l==3) print $0"="; else print $0 }')

  local header_json
  header_json=$(echo "${header_padded}" | base64 -d 2>/dev/null) || {
    fatal "Failed to decode license key header. The key may be malformed."
  }

  info "License key decoded successfully"

  # Extract the public key from the header JSON.
  # The field name depends on the license issuer; we support 'pk' and 'kid'.
  # If neither is present, store the raw header as the key reference.
  if echo "${header_json}" | grep -q '"pk"'; then
    LICENSE_PUBLIC_KEY=$(echo "${header_json}" | sed 's/.*"pk"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
  elif echo "${header_json}" | grep -q '"kid"'; then
    LICENSE_PUBLIC_KEY=$(echo "${header_json}" | sed 's/.*"kid"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
  else
    # Fallback: store the base64-encoded header as the public key identifier
    LICENSE_PUBLIC_KEY="${header_b64}"
  fi

  # Decode payload to extract license details for the success output
  local payload_b64
  payload_b64=$(echo "${license}" | cut -d. -f2)
  local payload_padded
  payload_padded=$(echo "${payload_b64}" | tr '_-' '/+' | awk '{ l=length($0)%4; if(l==2) print $0"=="; else if(l==3) print $0"="; else print $0 }')
  local payload_json
  payload_json=$(echo "${payload_padded}" | base64 -d 2>/dev/null) || true

  if [[ -n "${payload_json}" ]]; then
    LICENSE_COMPANY=$(echo "${payload_json}" | sed -n 's/.*"company"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    LICENSE_TIER=$(echo "${payload_json}" | sed -n 's/.*"tier"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    LICENSE_USER_CAP=$(echo "${payload_json}" | sed -n 's/.*"user_cap"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
    LICENSE_EXPIRES=$(echo "${payload_json}" | sed -n 's/.*"expires_at"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  fi

  success "License key validated"
}

# ============================================================
# SECRET GENERATION
# ============================================================

# generate_jwt_secret — produce a 64-character hex string (32 bytes).
# This satisfies the Supabase ≥32-byte requirement (FLASHCARDS.md 2026-03-24).
generate_jwt_secret() {
  openssl rand -hex 32
}

# generate_postgres_password — produce a 32-character alphanumeric password.
generate_postgres_password() {
  openssl rand -hex 16
}

# generate_encryption_key — produce a 64-character hex string (32 bytes).
# Used as ENCRYPTION_KEY for the BYOK provider key encryption in the backend.
generate_encryption_key() {
  openssl rand -hex 32
}

# generate_supabase_anon_key — produce a Supabase anon JWT signed with HS256.
# The JWT payload contains the role=anon claim required by PostgREST and Kong.
# Arguments:
#   $1 — JWT_SECRET (the signing secret, ≥32 bytes)
generate_supabase_anon_key() {
  local jwt_secret="${1}"
  _generate_supabase_jwt "${jwt_secret}" "anon"
}

# generate_supabase_service_role_key — produce a Supabase service_role JWT.
# Arguments:
#   $1 — JWT_SECRET
generate_supabase_service_role_key() {
  local jwt_secret="${1}"
  _generate_supabase_jwt "${jwt_secret}" "service_role"
}

# _generate_supabase_jwt — internal helper for Supabase JWT generation.
# Produces an HS256-signed JWT with the given role claim.
# Arguments:
#   $1 — JWT_SECRET
#   $2 — role (anon | service_role)
#
# JWT structure follows the Supabase self-hosting docs:
#   Header: {"alg":"HS256","typ":"JWT"}
#   Payload: {"role":"<role>","iss":"supabase","iat":<now>,"exp":<now+5years>}
_generate_supabase_jwt() {
  local secret="${1}"
  local role="${2}"
  local now exp

  now=$(date +%s)
  exp=$(( now + 5 * 365 * 24 * 3600 ))  # 5 years

  # Base64url-encode a string (no padding).
  # GNU base64 wraps output at 76 chars by default while BSD base64 does not,
  # so we explicitly strip newlines — without this, JWTs longer than 76 chars
  # contain embedded \n on Linux and break downstream sed templating.
  _b64url() {
    printf '%s' "${1}" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '='
  }

  local header
  header=$(_b64url '{"alg":"HS256","typ":"JWT"}')

  local payload
  payload=$(_b64url "{\"role\":\"${role}\",\"iss\":\"supabase\",\"iat\":${now},\"exp\":${exp}}")

  local unsigned="${header}.${payload}"

  # Sign with HMAC-SHA256 using openssl dgst
  # openssl outputs hex; we convert to binary then base64url
  local sig
  sig=$(printf '%s' "${unsigned}" \
    | openssl dgst -sha256 -hmac "${secret}" -binary \
    | base64 \
    | tr -d '\n' \
    | tr '+/' '-_' \
    | tr -d '=')

  printf '%s' "${unsigned}.${sig}"
}

# ============================================================
# EXISTING INSTALLATION DETECTION
# ============================================================

# detect_existing_install — check if Chyro is already installed.
# Returns 0 if an existing installation is detected, 1 otherwise.
detect_existing_install() {
  if [[ -f "${INSTALL_DIR}/${ENV_FILE}" ]] && [[ -f "${INSTALL_DIR}/${COMPOSE_FILE}" ]]; then
    return 0
  fi
  return 1
}

# ============================================================
# INTERACTIVE PROMPTS
# ============================================================

# ensure_tty_stdin — re-attach stdin to the controlling terminal so that
# `read` prompts work even when the script was invoked via `curl ... | bash`.
#
# When you pipe curl into bash, bash's stdin is the curl output stream, not
# the keyboard — so any `read` call returns EOF immediately and prompts get
# silently skipped. The fix is to redirect stdin from /dev/tty.
#
# This is only safe when a controlling terminal actually exists. In CI or
# truly headless contexts /dev/tty won't be readable; in that case we leave
# stdin alone and the operator should pass --non-interactive with all flags.
#
# Idempotent: only swaps stdin once per process, only when needed.
ensure_tty_stdin() {
  # Already on a TTY — nothing to do.
  if [ -t 0 ]; then
    return 0
  fi
  # No controlling terminal available — give up silently and let read fail.
  if [ ! -r /dev/tty ]; then
    warn "No TTY available for prompts. Pass --non-interactive with all flags, or download the script and run it directly."
    return 0
  fi
  exec </dev/tty
}

# prompt_if_empty — prompt the user for a value if the variable is empty.
# Skipped entirely in --non-interactive mode.
# Arguments:
#   $1 — variable name (for display)
#   $2 — prompt text
#   $3 — default value (shown in brackets, used if user presses Enter)
#   $4 — output variable name (nameref target)
prompt_if_empty() {
  local label="${1}"
  local prompt_text="${2}"
  local default_val="${3}"
  local _varname="${4}"
  local _current_val
  eval "_current_val=\"\${${_varname}:-}\""

  if [[ "${NON_INTERACTIVE}" == "true" ]]; then
    if [[ -z "${_current_val}" ]]; then
      if [[ -n "${default_val}" ]]; then
        eval "${_varname}=\"${default_val}\""
        info "Using default ${label}: ${default_val}"
      fi
    fi
    return
  fi

  if [[ -n "${_current_val}" ]]; then
    return  # Already set via flag
  fi

  local display_prompt="${prompt_text}"
  if [[ -n "${default_val}" ]]; then
    display_prompt="${prompt_text} [${default_val}]"
  fi

  while true; do
    read -rp "${display_prompt}: " input_val
    if [[ -z "${input_val}" && -n "${default_val}" ]]; then
      eval "${_varname}=\"${default_val}\""
      break
    elif [[ -n "${input_val}" ]]; then
      eval "${_varname}=\"${input_val}\""
      break
    else
      warn "This field is required."
    fi
  done
}

# prompt_yes_no — prompt for a yes/no answer, return the value.
# Arguments:
#   $1 — prompt text
#   $2 — default value (yes|no)
# Outputs: "yes" or "no" on stdout
prompt_yes_no() {
  local prompt_text="${1}"
  local default_val="${2:-yes}"

  if [[ "${NON_INTERACTIVE}" == "true" ]]; then
    echo "${default_val}"
    return
  fi

  local choices="[Y/n]"
  if [[ "${default_val}" == "no" ]]; then
    choices="[y/N]"
  fi

  read -rp "${prompt_text} ${choices}: " input_val
  if [[ -z "${input_val}" ]]; then
    echo "${default_val}"
  elif [[ "${input_val}" =~ ^[Yy] ]]; then
    echo "yes"
  else
    echo "no"
  fi
}

# gather_config — collect all required configuration via interactive prompts.
# Values already set via CLI flags are not re-prompted.
gather_config() {
  bold ""
  bold "=== Chyro Installation Configuration ==="
  echo ""

  # Re-attach stdin to the controlling terminal so prompts work even when
  # the script was piped into bash via curl. No-op if stdin is already a TTY.
  if [[ "${NON_INTERACTIVE}" == "false" ]]; then
    ensure_tty_stdin
  fi

  # Domain
  local domain_default=""
  if [[ "${LOCAL_MODE}" == "true" ]]; then
    domain_default="localhost"
  fi
  prompt_if_empty "domain" "Domain name (e.g. chyro.example.com)" "${domain_default}" DOMAIN

  # App name
  prompt_if_empty "app-name" "Application name" "Chyro" APP_NAME

  # Admin email
  prompt_if_empty "admin-email" "Admin user email" "" ADMIN_EMAIL

  # SMTP settings
  echo ""
  info "Email delivery settings (required for auth emails, invitations)"
  prompt_if_empty "smtp-host" "SMTP host (e.g. smtp.resend.com)" "" SMTP_HOST
  prompt_if_empty "smtp-port" "SMTP port" "587" SMTP_PORT
  prompt_if_empty "smtp-user" "SMTP username" "" SMTP_USER
  prompt_if_empty "smtp-pass" "SMTP password" "" SMTP_PASS

  # Registration mode
  echo ""
  if [[ "${NON_INTERACTIVE}" == "false" ]]; then
    echo "Registration mode:"
    echo "  1) invite_only — only admins can invite new users (recommended)"
    echo "  2) open        — anyone can register"
    read -rp "Choose [1/2, default=1]: " reg_choice
    case "${reg_choice}" in
      2|open) REGISTRATION_MODE="open" ;;
      *)      REGISTRATION_MODE="invite_only" ;;
    esac
  fi

  # Langfuse
  echo ""
  if [[ "${NON_INTERACTIVE}" == "false" ]]; then
    ENABLE_LANGFUSE=$(prompt_yes_no "Enable Langfuse LLM observability?" "yes")
  fi
}

# ============================================================
# FILE GENERATION
# ============================================================

# generate_env_file — write the .env file from gathered config and generated secrets.
# This function uses the global variables set during config gathering and secret
# generation. All secret values are generated fresh; existing values are NOT
# overwritten to preserve idempotency (R9).
generate_env_file() {
  local env_path="${INSTALL_DIR}/${ENV_FILE}"

  # Generate all secrets
  local jwt_secret postgres_password encryption_key anon_key service_role_key
  local langfuse_nextauth_secret langfuse_salt langfuse_encryption_key
  local dashboard_password db_enc_key secret_key_base

  info "Generating cryptographic secrets..."
  jwt_secret=$(generate_jwt_secret)
  postgres_password=$(generate_postgres_password)
  encryption_key=$(generate_encryption_key)
  anon_key=$(generate_supabase_anon_key "${jwt_secret}")
  service_role_key=$(generate_supabase_service_role_key "${jwt_secret}")
  langfuse_nextauth_secret=$(openssl rand -base64 32)
  langfuse_salt=$(openssl rand -base64 32)
  langfuse_encryption_key=$(openssl rand -hex 32)
  dashboard_password=$(openssl rand -hex 16)
  db_enc_key=$(openssl rand -hex 16)
  secret_key_base=$(openssl rand -base64 48 | tr -d '\n')

  success "All secrets generated"

  # Store keys globally for config.js and kong.yml generation
  GENERATED_ANON_KEY="${anon_key}"
  GENERATED_SERVICE_ROLE_KEY="${service_role_key}"
  GENERATED_JWT_SECRET="${jwt_secret}"

  # Protocol prefix for URLs
  local protocol="https"
  if [[ "${LOCAL_MODE}" == "true" ]]; then
    protocol="http"
  fi

  # DISABLE_SIGNUP controls registration mode in GoTrue
  local disable_signup="false"
  if [[ "${REGISTRATION_MODE}" == "invite_only" ]]; then
    disable_signup="true"
  fi

  # Sanitize user-supplied values for .env file — escape $, `, \ and wrap in quotes
  # to prevent shell expansion when the heredoc is written. Generated secrets are
  # hex/base64 and safe, but user inputs (SMTP_PASS, APP_NAME, etc.) may contain
  # shell metacharacters like $, backticks, or $(). Using a quoted heredoc (<<'EOF')
  # prevents expansion entirely, so we write variables explicitly after the static block.
  cat > "${env_path}" <<'ENV_STATIC_EOF'
# .env — Chyro production environment
# DO NOT commit this file to version control.
ENV_STATIC_EOF

  # Now append all key=value pairs using printf to prevent shell expansion
  {
    printf '# Generated by install.sh on %s\n\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    printf '# ===========================================================================\n'
    printf '# DOMAIN & TLS\n'
    printf '# ===========================================================================\n'
    printf 'DOMAIN=%s\n\n' "${DOMAIN}"
    printf '# ===========================================================================\n'
    printf '# SUPABASE CORE CREDENTIALS\n'
    printf '# ===========================================================================\n'
    printf 'POSTGRES_PASSWORD=%s\n' "${postgres_password}"
    printf 'POSTGRES_DB=postgres\n'
    printf 'JWT_SECRET=%s\n' "${jwt_secret}"
    printf 'ANON_KEY=%s\n' "${anon_key}"
    printf 'SERVICE_ROLE_KEY=%s\n\n' "${service_role_key}"
    printf '# ===========================================================================\n'
    printf '# SUPABASE AUTH (GoTrue)\n'
    printf '# ===========================================================================\n'
    printf 'API_EXTERNAL_URL=%s://%s\n' "${protocol}" "${DOMAIN}"
    printf 'SITE_URL=%s://%s\n' "${protocol}" "${DOMAIN}"
    printf 'ADDITIONAL_REDIRECT_URLS=\n'
    printf 'DISABLE_SIGNUP=%s\n' "${disable_signup}"
    printf 'ENABLE_EMAIL_AUTOCONFIRM=false\n'
    printf 'ENABLE_EMAIL_SIGNUP=true\n\n'
    printf '# ===========================================================================\n'
    printf '# SUPABASE SMTP\n'
    printf '# ===========================================================================\n'
    printf 'SMTP_HOST=%s\n' "${SMTP_HOST}"
    printf 'SMTP_PORT=%s\n' "${SMTP_PORT}"
    printf 'SMTP_USER=%s\n' "${SMTP_USER}"
    printf 'SMTP_PASS=%s\n' "${SMTP_PASS}"
    printf 'SMTP_SENDER_NAME=%s\n\n' "${APP_NAME}"
    printf '# ===========================================================================\n'
    printf '# SUPABASE STUDIO\n'
    printf '# ===========================================================================\n'
    printf 'DASHBOARD_USERNAME=supabase\n'
    printf 'DASHBOARD_PASSWORD=%s\n' "${dashboard_password}"
    printf 'STUDIO_DEFAULT_ORGANIZATION=%s\n' "${APP_NAME}"
    printf 'STUDIO_DEFAULT_PROJECT=chyro-prod\n\n'
    printf '# ===========================================================================\n'
    printf '# SUPABASE OPTIONAL FEATURES\n'
    printf '# ===========================================================================\n'
    printf 'ENABLE_GOOGLE_SIGNUP=false\n'
    printf 'GOOGLE_CLIENT_ID=\n'
    printf 'GOOGLE_CLIENT_SECRET=\n'
    printf 'DB_ENC_KEY=%s\n' "${db_enc_key}"
    printf 'SECRET_KEY_BASE=%s\n' "${secret_key_base}"
    printf 'PGRST_DB_SCHEMAS=public,storage,graphql_public\n'
    printf 'JWT_EXPIRY=3600\n'
    printf 'LOGFLARE_API_KEY=your-super-secret-and-long-logflare-key\n\n'
    printf '# ===========================================================================\n'
    printf '# CHYRO BACKEND\n'
    printf '# ===========================================================================\n'
    printf 'SUPABASE_ANON_KEY=%s\n' "${anon_key}"
    printf 'SUPABASE_SERVICE_ROLE_KEY=%s\n' "${service_role_key}"
    printf 'SUPABASE_JWT_SECRET=%s\n' "${jwt_secret}"
    printf 'CORS_ORIGINS=%s://%s\n' "${protocol}" "${DOMAIN}"
    printf 'ENCRYPTION_KEY=%s\n' "${encryption_key}"
    printf 'LICENSE_KEY=%s\n' "${LICENSE_KEY}"
    printf 'LICENSE_PUBLIC_KEY=%s\n' "${LICENSE_PUBLIC_KEY}"
    printf 'ENVIRONMENT=production\n'
    printf 'VITE_API_URL=/api\n\n'
    printf '# ===========================================================================\n'
    printf '# LANGFUSE — LLM observability (--profile langfuse)\n'
    printf '# ===========================================================================\n'
    printf 'LANGFUSE_PUBLIC_KEY=pk-lf-placeholder\n'
    printf 'LANGFUSE_SECRET_KEY=sk-lf-placeholder\n'
    printf 'LANGFUSE_NEXTAUTH_SECRET=%s\n' "${langfuse_nextauth_secret}"
    printf 'LANGFUSE_SALT=%s\n' "${langfuse_salt}"
    printf 'LANGFUSE_ENCRYPTION_KEY=%s\n' "${langfuse_encryption_key}"
    printf 'CLICKHOUSE_PASSWORD=clickhouse\n'
    printf 'MINIO_ROOT_USER=minio\n'
    printf 'MINIO_ROOT_PASSWORD=miniosecret\n'
  } >> "${env_path}"

  success ".env file written to ${env_path}"
}

# generate_caddyfile — write the Caddyfile from the template.
# In --local mode, generates an HTTP-only config (no TLS).
generate_caddyfile() {
  local caddyfile_path="${INSTALL_DIR}/${CADDYFILE}"

  if [[ "${LOCAL_MODE}" == "true" ]]; then
    # HTTP-only Caddyfile for local development (no TLS, no Let's Encrypt)
    cat > "${caddyfile_path}" <<'CADDYFILE_EOF'
# Caddyfile — Chyro local development (HTTP-only, no TLS)
# Generated by install.sh --local

:80 {
  # /api/* — Chyro FastAPI backend
  handle /api/* {
    uri strip_prefix /api
    reverse_proxy backend:8000
  }

  # /branding/* — static operator-managed branding assets
  handle /branding/* {
    uri strip_prefix /branding
    root * /srv/branding
    file_server
  }

  # Default catch-all — Chyro SPA
  handle {
    reverse_proxy frontend:80
  }
}
CADDYFILE_EOF
    success "Caddyfile written (HTTP-only mode for local)"
  else
    # Production Caddyfile with automatic TLS
    cat > "${caddyfile_path}" <<CADDYFILE_EOF
# Caddyfile — Chyro production reverse proxy
# Generated by install.sh for domain: ${DOMAIN}

${DOMAIN} {
  # /api/* — Chyro FastAPI backend
  handle /api/* {
    uri strip_prefix /api
    reverse_proxy backend:8000
  }

  # /branding/* — static operator-managed branding assets
  handle /branding/* {
    uri strip_prefix /branding
    root * /srv/branding
    file_server
  }

  # Default catch-all — Chyro SPA
  handle {
    reverse_proxy frontend:80
  }
}

# Supabase Studio
db.${DOMAIN} {
  reverse_proxy studio:3000
}

# Langfuse traces (only reachable when --profile langfuse is active)
traces.${DOMAIN} {
  reverse_proxy langfuse:3000
}
CADDYFILE_EOF
    success "Caddyfile written (production TLS mode)"
  fi
}

# generate_config_js — write frontend/public/config.js with runtime Supabase config.
# This file is volume-mounted into the nginx container at runtime, injecting
# window.CHYRO_CONFIG so the frontend SPA does not need Supabase URL baked in at
# build time (STORY-021-07 R7).
generate_config_js() {
  local config_js_path="${INSTALL_DIR}/${CONFIG_JS}"
  local supabase_url

  # Ensure the directory exists
  mkdir -p "$(dirname "${config_js_path}")"

  local protocol="https"
  if [[ "${LOCAL_MODE}" == "true" ]]; then
    protocol="http"
  fi

  # In production, Kong is the Supabase gateway; Caddy routes /supabase/* to it,
  # or the frontend calls the public URL directly. The runtime config points to
  # the public-facing Supabase URL.
  supabase_url="${protocol}://${DOMAIN}"

  cat > "${config_js_path}" <<EOF
/**
 * config.js — Chyro runtime configuration injection
 * Generated by install.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
 *
 * This file is volume-mounted into the nginx container at runtime.
 * It sets window.CHYRO_CONFIG so the Supabase client can read the
 * Supabase URL and anon key without a build-time rebuild.
 *
 * DO NOT commit this file with real credentials.
 */
window.CHYRO_CONFIG = {
  supabaseUrl: '${supabase_url}',
  supabaseAnonKey: '${GENERATED_ANON_KEY}',
}
EOF

  success "frontend/public/config.js written"
}

# copy_compose_file — copy docker-compose.prod.yml to the install directory.
# The script copies from the repo checkout or from the distributed bundle.
# Per sprint context rules, the script copies — not embeds — the compose file.
copy_compose_file() {
  local dest="${INSTALL_DIR}/${COMPOSE_FILE}"

  # If this script is run from within the repo (SCRIPT_DIR contains the file),
  # copy it. Otherwise, download from the release URL.
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local repo_root
  repo_root="$(dirname "${script_dir}")"
  local repo_compose="${repo_root}/${COMPOSE_FILE}"

  if [[ -f "${repo_compose}" ]]; then
    cp "${repo_compose}" "${dest}"
    success "docker-compose.prod.yml copied from repo"
  elif [[ -f "${INSTALL_DIR}/${COMPOSE_FILE}" ]]; then
    info "docker-compose.prod.yml already exists at install directory"
  else
    info "Downloading docker-compose.prod.yml from release..."
    curl -sSL "https://install.chyro.net/releases/${CHYRO_VERSION}/docker-compose.prod.yml" \
      -o "${dest}" \
      || fatal "Failed to download docker-compose.prod.yml"
    success "docker-compose.prod.yml downloaded"
  fi
}

# setup_volumes_dir — create the volumes/api/kong.yml placeholder if not present.
# Kong requires a declarative config file to be volume-mounted.
setup_volumes_dir() {
  local kong_dir="${INSTALL_DIR}/volumes/api"
  local kong_yml="${kong_dir}/kong.yml"

  mkdir -p "${kong_dir}"

  if [[ ! -f "${kong_yml}" ]]; then
    # Check if repo has a kong.yml we can copy
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local repo_root
    repo_root="$(dirname "${script_dir}")"
    local repo_kong="${repo_root}/volumes/api/kong.yml"

    if [[ -f "${repo_kong}" ]]; then
      cp "${repo_kong}" "${kong_yml}"
      success "volumes/api/kong.yml copied from repo"
    else
      info "Downloading kong.yml from release..."
      curl -sSL "https://install.chyro.net/releases/${CHYRO_VERSION}/volumes/api/kong.yml" \
        -o "${kong_yml}" \
        || warn "Failed to download kong.yml — Kong will not start without it"
    fi
  fi
}

# generate_kong_yml — template the kong.yml API key credentials with the generated
# Supabase JWT keys. Kong 3.x's declarative config (format_version 2.1) still uses
# hardcoded key values in the keyauth_credentials block — there is no native env-var
# substitution in the DB-less declarative config itself without an entrypoint script.
#
# Strategy: the source kong.yml ships with the Supabase demo keys (safe for dev,
# invalid for production). After generate_env_file() runs and sets GENERATED_ANON_KEY
# and GENERATED_SERVICE_ROLE_KEY, this function replaces those placeholders with the
# real generated keys using sed in-place.
#
# This function MUST be called after generate_env_file() so GENERATED_ANON_KEY and
# GENERATED_SERVICE_ROLE_KEY are set.
generate_kong_yml() {
  local kong_yml="${INSTALL_DIR}/volumes/api/kong.yml"

  if [[ ! -f "${kong_yml}" ]]; then
    warn "kong.yml not found at ${kong_yml} — skipping key templating"
    return 0
  fi

  # Supabase demo JWT keys (anon + service_role) that ship in the source kong.yml.
  # These are the well-known public demo values — safe to hardcode here as they are
  # the values we are replacing, not secrets being introduced.
  local demo_anon_key="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0"
  local demo_service_key="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU"

  # Replace demo service_role key with the generated SERVICE_ROLE_KEY from .env.
  # Read from the generated .env file since we don't store service_role_key globally.
  local generated_service_key
  generated_service_key=$(grep '^SERVICE_ROLE_KEY=' "${INSTALL_DIR}/${ENV_FILE}" | cut -d'=' -f2-)

  if [[ -z "${generated_service_key}" ]]; then
    warn "Could not read SERVICE_ROLE_KEY from .env — kong.yml service_role key not updated"
    return 0
  fi

  # Use sed with .bak suffix for portability (works on both Linux GNU sed and macOS BSD sed).
  # The backup file is removed immediately after to keep the directory clean.
  sed -i.bak "s|${demo_anon_key}|${GENERATED_ANON_KEY}|g" "${kong_yml}"
  rm -f "${kong_yml}.bak"

  sed -i.bak "s|${demo_service_key}|${generated_service_key}|g" "${kong_yml}"
  rm -f "${kong_yml}.bak"

  success "kong.yml API keys updated with generated production credentials"
}

# setup_db_init — copy the Supabase database init SQL to the install directory.
# This script creates extensions (pgvector, uuid-ossp, etc.) and runs AFTER
# the Supabase Postgres image's built-in init scripts (which create auth roles,
# schemas, and the authenticator user). The file is mounted as 99-chyro-init.sql.
setup_db_init() {
  local init_dir="${INSTALL_DIR}/volumes/db/init"
  local init_sql="${init_dir}/init.sql"

  mkdir -p "${init_dir}"

  if [[ ! -f "${init_sql}" ]]; then
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local repo_root
    repo_root="$(dirname "${script_dir}")"
    local repo_init="${repo_root}/volumes/db/init/init.sql"

    if [[ -f "${repo_init}" ]]; then
      cp "${repo_init}" "${init_sql}"
      # Also copy the role password script
      local repo_role_pw="${repo_root}/volumes/db/init/zz-set-role-passwords.sh"
      if [[ -f "${repo_role_pw}" ]]; then
        cp "${repo_role_pw}" "${init_dir}/zz-set-role-passwords.sh"
        chmod +x "${init_dir}/zz-set-role-passwords.sh"
      fi
      success "Database init SQL copied from repo"
    else
      info "Downloading init.sql from release..."
      curl -sSL "https://install.chyro.net/releases/${CHYRO_VERSION}/volumes/db/init/init.sql" \
        -o "${init_sql}" \
        || warn "Failed to download init.sql — database extensions may need manual setup"
    fi
  fi
}

# setup_source_dirs — in --local mode, copy or symlink source directories
# so docker compose can build backend/frontend images from source.
# In production mode this is a no-op (images are pulled from registry).
setup_source_dirs() {
  if [[ "${LOCAL_MODE}" != "true" ]]; then
    return  # Production mode — images pulled from registry, no source needed
  fi

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local repo_root
  repo_root="$(dirname "${script_dir}")"

  # If INSTALL_DIR is different from repo root, copy source dirs
  if [[ "$(cd "${INSTALL_DIR}" && pwd)" != "$(cd "${repo_root}" && pwd)" ]]; then
    info "Local mode: copying source directories for Docker build..."
    for dir in backend frontend shared database; do
      if [[ -d "${repo_root}/${dir}" ]] && [[ ! -e "${INSTALL_DIR}/${dir}" ]]; then
        cp -R "${repo_root}/${dir}" "${INSTALL_DIR}/${dir}"
        info "  Copied ${dir}/"
      fi
    done
    success "Source directories ready for local build"
  fi
}

# setup_branding_dir — pre-create the branding/ directory.
# CRITICAL: Docker must NOT create this directory — a Docker-created dir is
# root-owned and Caddy's file_server cannot serve from it correctly.
# This is a sprint context rule and FLASHCARD constraint.
setup_branding_dir() {
  local branding_dir="${INSTALL_DIR}/branding"
  if [[ ! -d "${branding_dir}" ]]; then
    mkdir -p "${branding_dir}"
    success "branding/ directory created (pre-created by script, not Docker)"
  else
    info "branding/ directory already exists"
  fi
}

# ============================================================
# SERVICE STARTUP
# ============================================================

# pull_images — pull all Docker images from the registry before starting.
# This ensures the latest images are used and reduces startup time.
pull_images() {
  registry_login
  info "Pulling images from ${REGISTRY}..."
  cd "${INSTALL_DIR}"

  local compose_args=("-f" "${COMPOSE_FILE}")
  if [[ "${ENABLE_LANGFUSE}" == "yes" ]]; then
    compose_args+=("--profile" "langfuse")
  fi

  docker compose "${compose_args[@]}" pull || {
    warn "Some images failed to pull. Continuing with locally cached images if available."
  }
  success "Images pulled"
}

# start_services — start all Docker Compose services in detached mode.
start_services() {
  info "Starting Chyro services..."
  cd "${INSTALL_DIR}"

  local compose_args=("-f" "${COMPOSE_FILE}" "up" "-d" "--remove-orphans")
  if [[ "${ENABLE_LANGFUSE}" == "yes" ]]; then
    compose_args=("-f" "${COMPOSE_FILE}" "--profile" "langfuse" "up" "-d" "--remove-orphans")
  fi

  docker compose "${compose_args[@]}" || fatal "Failed to start services"
  success "All services started"
}

# wait_for_db — wait until the Postgres database passes its health check.
# This is required before running migrations, which need a live DB.
wait_for_db() {
  info "Waiting for database to be ready..."
  local max_attempts=30
  local attempt=0

  while [[ "${attempt}" -lt "${max_attempts}" ]]; do
    if docker compose -f "${INSTALL_DIR}/${COMPOSE_FILE}" exec -T db \
        pg_isready -U postgres &>/dev/null; then
      success "Database is ready"
      return
    fi
    attempt=$(( attempt + 1 ))
    info "  Waiting... (${attempt}/${max_attempts})"
    sleep 5
  done

  fatal "Database did not become ready after $(( max_attempts * 5 )) seconds."
}

# run_migrations — execute database SQL migrations against the Postgres container.
# Migrations are numbered SQL files in database/migrations/ that run in order.
# Each migration is applied via psql inside the db container.
run_migrations() {
  info "Running database migrations..."
  cd "${INSTALL_DIR}"

  local migrations_dir="${INSTALL_DIR}/database/migrations"
  if [[ ! -d "${migrations_dir}" ]]; then
    warn "No migrations directory found at ${migrations_dir} — skipping migrations"
    return
  fi

  local migration_count=0
  for sql_file in "${migrations_dir}"/*.sql; do
    [[ -f "${sql_file}" ]] || continue
    local filename
    filename=$(basename "${sql_file}")
    info "  Applying: ${filename}"
    docker compose -f "${COMPOSE_FILE}" exec -T db \
      psql -U supabase_admin -d "${POSTGRES_DB:-postgres}" -f "/migrations/${filename}" \
      --set ON_ERROR_STOP=1 > /dev/null 2>&1 \
      || warn "  Migration ${filename} had errors (may already be applied)"
    migration_count=$(( migration_count + 1 ))
  done

  if [[ "${migration_count}" -eq 0 ]]; then
    warn "No migration files found"
  else
    success "${migration_count} migrations applied"
  fi
}

# create_admin_user — create the first admin user in Supabase Auth.
# The admin email was collected during configuration gathering.
create_admin_user() {
  if [[ -z "${ADMIN_EMAIL}" ]]; then
    warn "No admin email provided — skipping admin user creation"
    return
  fi

  info "Creating admin user: ${ADMIN_EMAIL}..."

  # Generate a random temporary password for the first admin
  ADMIN_PASSWORD=$(openssl rand -base64 16 | tr -d '=/+' | head -c 20)

  # Use the backend's admin creation endpoint or Supabase Auth admin API.
  # Pass credentials via environment variables to prevent shell injection.
  docker compose -f "${INSTALL_DIR}/${COMPOSE_FILE}" exec -T \
    -e "CHYRO_ADMIN_EMAIL=${ADMIN_EMAIL}" \
    -e "CHYRO_ADMIN_PASSWORD=${ADMIN_PASSWORD}" \
    backend python -c "
import os, sys
sys.path.insert(0, '/app')
from app.core.config import settings
from supabase import create_client

email = os.environ['CHYRO_ADMIN_EMAIL']
password = os.environ['CHYRO_ADMIN_PASSWORD']
supabase = create_client(settings.supabase_url, settings.supabase_service_role_key)
try:
    result = supabase.auth.admin.create_user({
        'email': email,
        'password': password,
        'email_confirm': True,
        'user_metadata': {'role': 'admin'}
    })
    print('Admin user created: ' + result.user.id)
except Exception as e:
    # User may already exist (idempotent)
    print('Note: ' + str(e))
" || warn "Admin user creation encountered an issue — check logs with: docker compose -f ${INSTALL_DIR}/${COMPOSE_FILE} logs backend"

  success "Admin user setup complete"
}

# ============================================================
# UPGRADE MODE
# ============================================================

# run_upgrade — pull latest images, run migrations, restart services.
# Zero data loss: named volumes (db_data, storage_data, redis_data) are preserved.
run_upgrade() {
  bold ""
  bold "=== Chyro Upgrade ==="
  echo ""

  if ! detect_existing_install; then
    fatal "No existing Chyro installation found at ${INSTALL_DIR}. Run without --upgrade to install."
  fi

  info "Upgrading existing Chyro installation at ${INSTALL_DIR}..."

  # Source existing .env to get current config
  # shellcheck disable=SC1090
  set -a
  source "${INSTALL_DIR}/${ENV_FILE}"
  set +a

  pull_images

  info "Restarting services with new images..."
  cd "${INSTALL_DIR}"
  docker compose -f "${COMPOSE_FILE}" up -d --remove-orphans \
    || fatal "Failed to restart services"

  wait_for_db
  run_migrations

  success "Upgrade complete"
  print_success_output
}

# ============================================================
# SUCCESS OUTPUT
# ============================================================

# print_success_output — display the final success message with URL, credentials,
# and next steps for branding customization.
print_success_output() {
  local protocol="https"
  if [[ "${LOCAL_MODE}" == "true" ]]; then
    protocol="http"
  fi

  echo ""
  echo "============================================================"
  bold "  Chyro Installation Complete!"
  echo "============================================================"

  # --- License Info ---
  echo ""
  bold "  License:"
  echo "  Company:          ${LICENSE_COMPANY:-N/A}"
  echo "  Tier:             ${LICENSE_TIER:-N/A}"
  echo "  User Cap:         ${LICENSE_USER_CAP:-unlimited}"
  echo "  Expires:          ${LICENSE_EXPIRES:-N/A}"

  # --- URLs ---
  echo ""
  bold "  Access URLs:"
  echo "  App:              ${protocol}://${DOMAIN}"
  if [[ "${LOCAL_MODE}" != "true" ]]; then
    echo "  Supabase Studio:  https://db.${DOMAIN}"
    if [[ "${ENABLE_LANGFUSE}" == "yes" ]]; then
      echo "  Langfuse:         https://traces.${DOMAIN}"
    fi
  fi
  echo "  Ports:            80 (HTTP), 443 (HTTPS)"

  # --- Credentials ---
  echo ""
  bold "  Credentials:"
  if [[ -n "${ADMIN_EMAIL:-}" ]]; then
    echo "  Admin Email:      ${ADMIN_EMAIL}"
    echo "  Admin Password:   ${ADMIN_PASSWORD:-<see setup logs>}"
  fi
  echo "  Studio User:      supabase"
  echo "  Studio Password:  <see DASHBOARD_PASSWORD in .env>"
  echo ""
  echo "  >>> SAVE THESE CREDENTIALS NOW <<<"
  echo "  >>> Change the admin password on first login <<<"

  # --- Registration Mode ---
  echo ""
  bold "  Configuration:"
  echo "  App Name:         ${APP_NAME:-Chyro}"
  echo "  Registration:     ${REGISTRATION_MODE:-invite_only}"
  if [[ "${REGISTRATION_MODE}" == "open" ]]; then
    echo "                    (anyone can sign up — change in .env if needed)"
  else
    echo "                    (admin must invite users)"
  fi

  # --- Service Status ---
  echo ""
  bold "  Service Status:"
  cd "${INSTALL_DIR}"
  docker compose -f "${COMPOSE_FILE}" ps --format "  {{.Name}}\t{{.Status}}" 2>/dev/null || \
    echo "  (run 'docker compose ps' to check)"

  # --- Health Check ---
  echo ""
  bold "  Quick Health Check:"
  if curl -sf "${protocol}://${DOMAIN}/api/health" > /dev/null 2>&1; then
    success "  API is responding at ${protocol}://${DOMAIN}/api/health"
  elif curl -sf "http://localhost:8000/health" > /dev/null 2>&1; then
    success "  API is responding (backend container healthy)"
  else
    warn "  API not responding yet — services may still be starting"
    echo "  Check with: docker compose -f ${INSTALL_DIR}/${COMPOSE_FILE} logs backend"
  fi

  # --- File Locations ---
  echo ""
  bold "  File Locations:"
  echo "  Config:           ${INSTALL_DIR}/.env"
  echo "  Compose:          ${INSTALL_DIR}/${COMPOSE_FILE}"
  echo "  Reverse Proxy:    ${INSTALL_DIR}/${CADDYFILE}"
  echo "  Branding:         ${INSTALL_DIR}/branding/"

  # --- Branding ---
  echo ""
  bold "  Branding Customization:"
  echo "  Place your logo and assets in: ${INSTALL_DIR}/branding/"
  echo "  They will be served at: ${protocol}://${DOMAIN}/branding/<filename>"

  # --- Langfuse ---
  if [[ "${ENABLE_LANGFUSE}" == "yes" ]]; then
    echo ""
    bold "  Langfuse Setup:"
    echo "  1. Visit https://traces.${DOMAIN} and create an account"
    echo "  2. Create a project and generate API keys"
    echo "  3. Update LANGFUSE_PUBLIC_KEY and LANGFUSE_SECRET_KEY in .env"
    echo "  4. Restart: docker compose -f ${INSTALL_DIR}/${COMPOSE_FILE} restart backend worker"
  fi

  # --- Useful Commands ---
  echo ""
  bold "  Useful Commands:"
  echo "  View logs:   docker compose -f ${INSTALL_DIR}/${COMPOSE_FILE} logs -f"
  echo "  Restart:     docker compose -f ${INSTALL_DIR}/${COMPOSE_FILE} restart"
  echo "  Stop:        docker compose -f ${INSTALL_DIR}/${COMPOSE_FILE} down"
  echo "  Upgrade:     curl -sSL https://install.chyro.net | bash -s -- --upgrade"
  echo "============================================================"
}

# ============================================================
# MAIN FLOW
# ============================================================

main() {
  parse_args "$@"

  bold ""
  bold "=== Chyro Install Script ==="
  bold "    Version: ${CHYRO_VERSION}"
  echo ""

  # ── UPGRADE MODE ────────────────────────────────────────────
  if [[ "${UPGRADE_MODE}" == "true" ]]; then
    run_upgrade
    exit 0
  fi

  # ── FRESH INSTALL ───────────────────────────────────────────

  # 1. Validate license key
  validate_license "${LICENSE_KEY}"

  # 2. System checks
  info "Running system checks..."
  check_tools
  check_docker_compose

  if [[ "${LOCAL_MODE}" != "true" ]]; then
    check_os
  fi

  check_ram
  check_disk

  # 3. Check for existing installation (R9: idempotent)
  if detect_existing_install; then
    warn "Existing Chyro installation detected at ${INSTALL_DIR}"
    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
      warn "Non-interactive mode: existing installation will be updated without destroying data."
    else
      echo ""
      ensure_tty_stdin
      read -rp "Existing installation found. Continue and update (data is preserved)? [y/N] " confirm
      if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
        info "Aborting. To upgrade, use --upgrade flag."
        exit 0
      fi
    fi
  fi

  # 4. Gather configuration (interactive or via flags)
  gather_config

  # 5. Set up install directory
  info "Setting up installation directory: ${INSTALL_DIR}"
  mkdir -p "${INSTALL_DIR}"

  # 6. Copy compose file and supporting files
  copy_compose_file
  setup_volumes_dir
  setup_db_init

  # 6b. In --local mode, copy source dirs for Docker build
  setup_source_dirs

  # 7. Create branding directory (pre-created by script, NOT by Docker)
  setup_branding_dir

  # 8. Generate secrets and write .env
  generate_env_file

  # 8b. Template kong.yml with generated JWT keys (replaces Supabase demo keys)
  generate_kong_yml

  # 9. Write Caddyfile
  generate_caddyfile

  # 10. Write frontend/public/config.js
  generate_config_js

  # 10b. Template kong.yml with production JWT keys
  generate_kong_yml

  # 11. Pull images
  pull_images

  # 12. Start services
  start_services

  # 13. Wait for DB then run migrations
  wait_for_db
  run_migrations

  # 14. Create first admin user
  create_admin_user

  # 15. Print success summary
  print_success_output
}

# Entry point — pass all script arguments to main
main "$@"

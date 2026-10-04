# Shared by setup.sh and manage.sh (sourced, not run).
# shellcheck shell=bash

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
fail() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '  \033[1;32m✔\033[0m %s\n' "$*"; }
bad()  { printf '  \033[1;31m✖\033[0m %s\n' "$*"; }

# The core stack (Postgres, Redis, four services, Cube, frontend) needs about
# this much; Airbyte installed with abctl wants another 8 GB.
MIN_RAM_GB=6
MIN_DISK_GB=10

host_os() {
    case "$(uname -s)" in
        Darwin) echo macos ;;
        Linux) if grep -qi microsoft /proc/version 2>/dev/null; then echo wsl; else echo linux; fi ;;
        *) echo other ;;
    esac
}

ram_gb() {
    case "$(uname -s)" in
        Darwin) echo $(( $(sysctl -n hw.memsize) / 1073741824 )) ;;
        *) awk '/MemTotal/ {printf "%d", $2 / 1048576}' /proc/meminfo 2>/dev/null || echo 0 ;;
    esac
}

cpu_count() { getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 0; }

disk_free_gb() { df -Pk "${1:-.}" 2>/dev/null | awk 'NR==2 {printf "%d", $4 / 1048576}'; }

install_hint() {
    case "$(host_os)" in
        macos) echo "Install Docker Desktop (brew install --cask docker) or Podman Desktop (brew install --cask podman-desktop), then start it." ;;
        wsl) echo "Install Docker Desktop on Windows and turn on WSL integration for this distribution (Settings > Resources > WSL integration)." ;;
        linux) echo "Install Docker Engine with the compose plugin: curl -fsSL https://get.docker.com | sh   (then: sudo usermod -aG docker \$USER, and sign in again)" ;;
        *) echo "Install Docker or Podman with a compose provider." ;;
    esac
}

# Sets C (the compose command as an array) and E (docker or podman) for the caller.
# shellcheck disable=SC2034
find_runtime() {
    if docker compose version >/dev/null 2>&1 && docker info >/dev/null 2>&1; then C=(docker compose); E=docker
    elif podman info >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then C=(podman compose); E=podman
    else return 1; fi
}

# Prints the host checklist. Returns 1 when something blocks the install.
host_check() {
    local blocked=0 ram cpus disk
    ram="$(ram_gb)"; cpus="$(cpu_count)"; disk="$(disk_free_gb "${1:-.}")"
    say "Checking this machine"
    ok "$(host_os) · $(uname -m) · ${ram} GB RAM · ${cpus} CPU · ${disk:-?} GB free disk"
    if find_runtime; then
        ok "$E $("$E" --version 2>/dev/null | head -1 | sed 's/^[^0-9]*//') with compose"
    else
        bad "Docker or Podman with compose is not running"
        echo "    $(install_hint)"
        blocked=1
    fi
    if command -v curl >/dev/null 2>&1; then ok "curl"; else bad "curl is missing"; blocked=1; fi
    if [[ "$ram" -gt 0 && "$ram" -lt "$MIN_RAM_GB" ]]; then
        warn "${ram} GB of RAM: the portal needs about ${MIN_RAM_GB} GB (Airbyte on this host another 8 GB)."
    fi
    if [[ -n "$disk" && "$disk" -lt "$MIN_DISK_GB" ]]; then
        warn "${disk} GB of free disk: the images and databases need about ${MIN_DISK_GB} GB."
    fi
    return "$blocked"
}

# .env helpers (in the current directory).
set_env() {  # set_env KEY VALUE: replace or append, keep everything else
    local key="$1" value="$2"
    if grep -q "^$key=" .env 2>/dev/null; then
        sed -i.bak "s|^$key=.*|$key=$value|" .env && rm -f .env.bak
    else
        printf '%s=%s\n' "$key" "$value" >> .env
    fi
}
# tr: a .env written on Windows has CRLF line ends.
get_env() { grep "^$1=" .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r' || true; }

wait_healthy() {  # wait_healthy PORT
    printf 'Waiting for the portal'
    for _ in $(seq 1 60); do
        curl -fs "http://localhost:$1/api/health" >/dev/null 2>&1 && { echo; return 0; }
        printf '.'; sleep 5
    done
    echo
    return 1
}

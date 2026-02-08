#!/usr/bin/env bash
set -euo pipefail

APARECE_DIR="/opt/aparece"
ANSIBLE_DIR="${APARECE_DIR}/ansible"
METADATA_DIR="${ANSIBLE_DIR}/app_metadata"

usage() {
    cat <<EOF
Usage: aparece <command> [args]

Commands:
    activate <app>    Install and activate an application
    list              List available applications
    status  [app]     Show status of applications

Run 'aparece list' to see available apps.
EOF
    exit "${1:-0}"
}

log() { echo "[aparece] $*"; }
error() { echo "[aparece] ERROR: $*" >&2; exit 1; }

# Parse a YAML metadata file using Python's yaml module (available via Ansible dependency)
parse_meta() {
    local meta_file="$1"
    local field="$2"
    python3 -c "
import yaml, sys, json
with open('${meta_file}') as f:
    data = yaml.safe_load(f)
val = data.get('${field}')
if val is None:
    sys.exit(0)
if isinstance(val, list):
    if len(val) == 0:
        sys.exit(0)
    # For list of dicts (ufw_ports), extract 'port' values
    if isinstance(val[0], dict) and 'port' in val[0]:
        print(','.join(str(item['port']) for item in val))
    else:
        print(','.join(str(item) for item in val))
else:
    print(val)
"
}

available_apps() {
    local apps=()
    for f in "${METADATA_DIR}"/*.yml; do
        [[ -f "$f" ]] || continue
        apps+=("$(basename "$f" .yml)")
    done
    echo "${apps[@]}"
}

validate_app() {
    local app="$1"
    local meta="${METADATA_DIR}/${app}.yml"
    [[ -f "$meta" ]] || error "Unknown app: ${app}. Run 'aparece list' to see available apps."
}

cmd_list() {
    echo "Available apps:"
    for f in "${METADATA_DIR}"/*.yml; do
        [[ -f "$f" ]] || continue
        local app
        app="$(basename "$f" .yml)"
        local desc
        desc="$(parse_meta "$f" description)"
        printf "  %-14s %s\n" "$app" "$desc"
    done
}

cmd_activate() {
    local app="$1"
    validate_app "$app"

    local meta="${METADATA_DIR}/${app}.yml"
    local desc
    desc="$(parse_meta "$meta" description)"

    log "Activating ${desc}..."
    echo ""

    cd "${ANSIBLE_DIR}"
    ansible-playbook playbooks/activate.yml -e "app_name=${app}"

    echo ""

    # Print summary
    local ports binary service logs

    ports="$(parse_meta "$meta" ufw_ports)"
    binary="$(parse_meta "$meta" binary_path)"
    service="$(parse_meta "$meta" service_name)"
    logs="$(parse_meta "$meta" log_paths)"

    echo "=== ${desc} ==="
    [[ -n "$ports" ]]   && echo "  Port(s): ${ports}"
    [[ -n "$binary" ]]  && echo "  Binary:  ${binary}"
    [[ -n "$service" ]] && echo "  Service: ${service} (systemctl status ${service})"
    [[ -n "$logs" ]]    && echo "  Logs:    ${logs}"
    echo ""
}

cmd_status() {
    local filter="${1:-}"

    if [[ -n "$filter" ]]; then
        validate_app "$filter"
    fi

    for f in "${METADATA_DIR}"/*.yml; do
        [[ -f "$f" ]] || continue
        local app
        app="$(basename "$f" .yml)"

        [[ -n "$filter" && "$filter" != "$app" ]] && continue

        local service
        service="$(parse_meta "$f" service_name)"

        if [[ -n "$service" ]]; then
            if systemctl is-active --quiet "$service" 2>/dev/null; then
                printf "  %-14s ACTIVE   (service: %s)\n" "$app" "$service"
            else
                printf "  %-14s INACTIVE\n" "$app"
            fi
        else
            local binary
            binary="$(parse_meta "$f" binary_path)"
            # Expand $HOME if present
            binary="$(eval echo "$binary")"
            if [[ -n "$binary" && -x "$binary" ]]; then
                printf "  %-14s INSTALLED (binary: %s)\n" "$app" "$binary"
            else
                printf "  %-14s NOT INSTALLED\n" "$app"
            fi
        fi
    done
}

# Main dispatch
[[ $# -lt 1 ]] && usage 1

case "$1" in
    activate)
        [[ $# -lt 2 ]] && error "Usage: aparece activate <app>"
        cmd_activate "$2"
        ;;
    list)
        cmd_list
        ;;
    status)
        cmd_status "${2:-}"
        ;;
    -h|--help|help)
        usage 0
        ;;
    *)
        error "Unknown command: $1. Run 'aparece --help' for usage."
        ;;
esac

#!/usr/bin/env bash
# Scan 10.20.3.0/24 for live hosts and open ports

SUBNET="10.20.3"
TIMEOUT=1
THREADS=20

echo "Scanning ${SUBNET}.1-254 ..."
echo "-------------------------------------------"

scan_host() {
    local ip="${SUBNET}.${1}"

    # Quick ICMP ping
    if ping -c 1 -W "$TIMEOUT" "$ip" &>/dev/null; then
        # Reverse DNS lookup
        hostname=$(getent hosts "$ip" 2>/dev/null | awk '{print $2}')
        [[ -z "$hostname" ]] && hostname="(no rDNS)"

        # Common server ports: SSH, HTTP, HTTPS, RDP, SMB, Postgres, MySQL, Redis, Kafka, Elasticsearch
        ports=(22 80 443 3389 445 5432 3306 6379 9092 9200 8080 8443)
        open_ports=()
        for port in "${ports[@]}"; do
            if timeout "$TIMEOUT" bash -c "echo >/dev/tcp/${ip}/${port}" 2>/dev/null; then
                open_ports+=("$port")
            fi
        done

        echo -n "[UP] ${ip}  ${hostname}"
        if [[ ${#open_ports[@]} -gt 0 ]]; then
            echo "  |  open ports: ${open_ports[*]}"
        else
            echo "  |  no common ports open"
        fi
    fi
}

export -f scan_host
export SUBNET TIMEOUT

# Run in parallel using xargs
seq 1 254 | xargs -P "$THREADS" -I{} bash -c 'scan_host "$@"' _ {}

echo "-------------------------------------------"
echo "Done."

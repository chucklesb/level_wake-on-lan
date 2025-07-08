#!/bin/bash

### send-wol.sh - Send a WOL magic packet to a given MAC address and target subnet
# Depends: socat
# Intended for Level RMM automation.

# Globals
socat_bin=""

# Level RMM variables
level_SocatBin="{{SocatBin}}"
level_MacAddress="{{MacAddress}}"
level_TargetCidr="{{TargetCidr}}"

# Logging and error handling
log_name="send-wol-$(date +%s).log"
log_path="${TMPDIR:-/tmp}/${log_name}"

write_log_message() {
    # Parameters
    local message="$1"
    local type="${2:-Info}"
    local include_timestamp="${3:-true}"
    local include_type="${4:-true}"
    local log_to_file="${5:-true}"
    local log_to_console="${6:-true}"

    # Initialize timestamp and entry type variables
    local timestamp=""
    local type_str=""

    # Validate type
    case "$type" in
        Error|Warning|Debug|Info|Success) ;;
        *) type="Info" ;;           # Default type is Info
    esac

    # Include timestamp if requested
    if [[ $include_timestamp == true ]]; then
        timestamp="[$(date '+%Y-%m-%d %H:%M:%S')] "
    fi

    # Include type if requested
    if [[ $include_type == true ]]; then
        type_str="${type^^}: "      # Convert to uppercase
    fi

    # Build the log entry message
    local log_entry="${timestamp}${type_str}${message}"

    # Log to file if enabled
    if [[ $log_to_file == true ]]; then
        echo "$log_entry" >> "$log_path"
    fi

    # Log to console if enabled
    if [[ $log_to_console == true ]]; then
        echo "$log_entry"
    fi
}

resolve_error() {
    write_log_message "$1" Error >&2
    exit 1
}

## Main functions
check_socat() {
    local socat_path

    if [[ -n "$1" && "$1" != "{{"*"}}" ]]; then
        socat_path="$1"
    else
        socat_path=$(command -v socat)
    fi

    if [[ -f "$socat_path" ]]; then
        write_log_message "socat binary located: $socat_path"
        if [[ ! -x "$socat_path" ]]; then
            chmod +x "$socat_path" || {
                resolve_error "check_socat(): Failed to make $socat_path executable."
            }
        fi
    else
        resolve_error "check_socat(): Unable to locate socat binary."
    fi

    socat_bin="$socat_path"
}

convert_ip_int() {
    local ip="$1"

    # Split IP address into octets and validate
    IFS=. read -r -a octets <<< "$ip"
    if (( ${#octets[@]} != 4 )); then
        resolve_error "convert_ip_int(): Invalid IPv4 address format: $ip"
    fi

    for octet in "${octets[@]}"; do
        if [[ ! $octet =~ ^[0-9]+$ ]] || (( octet > 255 )); then
            resolve_error "convert_ip_int(): Invalid IP address octet '$octet' in '$ip'."
        fi
    done

    # Convert IP to integer representation
    printf '%d' "$(( (${octets[0]} << 24) + (${octets[1]} << 16) + (${octets[2]} << 8) + ${octets[3]} ))"
}

cidr_broadcast() {
    local cidr_string="$1"
    
    # Split CIDR string into ip/netmask
    IFS=/ read -r -a cidr <<< "$cidr_string"
    if (( ${#cidr[@]} != 2 )); then
        resolve_error "cidr_broadcast(): Invalid CIDR format for '$cidr_string' (valid format A.B.C.D/M)."
    fi
    local ip="${cidr[0]}"
    local mask="${cidr[1]}"

    # Convert IP to integer
    local ip_int
    ip_int=$(convert_ip_int "$ip")

    # Validate and calculate netmask
    if (( mask < 0 || mask > 32 )); then
        resolve_error "cidr_broadcast(): Invalid CIDR mask '$mask' (valid range 0..32)."
    fi
    local mask_int
    mask_int=$(( 0xFFFFFFFF << (32 - mask) ))

    # Calculate broadcast address
    local broadcast_int
    broadcast_int=$(( (ip_int & mask_int) | (~mask_int & 0xFFFFFFFF) ))

    # Convert back to dotted-decimal
    printf '%d.%d.%d.%d' \
        $(( (broadcast_int >> 24) & 0xFF )) \
        $(( (broadcast_int >> 16) & 0xFF )) \
        $(( (broadcast_int >> 8) & 0xFF )) \
        $(( broadcast_int & 0xFF ))
}

normalize_mac() {
    local input="$1"
    
    # Remove delimiters and convert to uppercase
    local clean_mac="${input//[^a-zA-Z0-9]/}"
    clean_mac="${clean_mac^^}"

    # Validate input MAC
    if [[ ! "$clean_mac" =~ ^[0-9A-F]{12}$ ]]; then
        resolve_error "normalize_mac(): Invalid MAC address: $input"
    fi

    # Construct byte string
    local byte_string=""
    for ((i=0; i<12; i+=2)); do
        byte_string+="\\x${clean_mac:$i:2}"
    done
    printf '%b' "$byte_string"
}

send_wol() {
    local target_mac="$1"
    local target_cidr="$2"

    # Convert MAC address to byte array and normalized string
    local mac_bytes
    mac_bytes=$(normalize_mac "$target_mac")
    local mac_string=""
    for ((i = 0; i < 6; i++)); do
        byte=$(printf '%d' "'${mac_bytes:i:1}")
        mac_string+=$(printf '%02x:' "$byte")
    done
    mac_string=${mac_string::-1}
    write_log_message "Target MAC: $mac_string"

    # Calculate subnet broadcast address
    local broadcast_addr
    broadcast_addr=$(cidr_broadcast "$target_cidr")
    write_log_message "Broadcast address: $broadcast_addr"

    # Construct Wake-On-LAN magic packet
    local packet
    packet=$(printf '\xff%.0s' {1..6})
    packet+=$(
        for i in {1..16}; do
            printf '%b' "$mac_bytes"
        done
    )

    # Send the Wake-On-LAN magic packet using socat
    set +e              # Catch potential socat errors
    local socat_output
    socat_output=$(printf '%b' "$packet" | "$socat_bin" -x - UDP-DATAGRAM:"${broadcast_addr}":9,broadcast 2>&1)
    local socat_exit_code=$?

    printf '%s\n' "$socat_output"

    if [[ $socat_exit_code -eq 0 ]]; then
        if [[ $socat_output =~ length=([0-9]+) ]]; then
            local bytes_sent="${BASH_REMATCH[1]}"
            if [[ $bytes_sent -eq 102 ]]; then
                write_log_message "Wake-On-LAN packet sent to $mac_string." "Success"
            else
                resolve_error "send_wol(): Failed to send Wake-On-Lan packet: Invalid packet size ($bytes_sent bytes)."
            fi
        else
            resolve_error "send_wol(): Failed to parse socat output."
        fi
    else
        resolve_error "send_wol(): Failed to send Wake-On-Lan packet: socat failed with exit code $socat_exit_code"
    fi
}

## Entry point
set -e              # Exit immediately if an error occurs
echo "Logging to file: $log_path"
check_socat "$level_SocatBin"
send_wol "$level_MacAddress" "$level_TargetCidr"
#!/usr/bin/env bash

### Helper functions ###
function ip2int() {
    local IFS='.'
    read -r octet1 octet2 octet3 octet4 <<< "$1"
    echo $(( (octet1 << 24) + (octet2 << 16) + (octet3 << 8) + octet4 ))
}

function int2str() {
    echo "$(( ($1 >> 24) & 255 )).$(( ($1 >> 16) & 255 )).$(( ($1 >> 8) & 255 )).$(( $1 & 255 ))"
}

function is_ip_in_network() {
    local mask=$(( ((1 << 32) - 1) - ((1 << (32 - $3)) - 1) ))
    [[ $(( $1 & mask )) -eq $(( $2 & mask )) ]]
}

function usage() {
    echo -e "Usage: $0 <ip-address>[,ip-address...] [-s|--sort] [-w|--wireguard]\n"
    echo "Parameters:"
    echo -e "  ip-address           Required IP address(es), comma-separated\n"
    echo "Options:"
    echo "  -s, --sort          Enable sorting by prefix length"
    echo "  -w, --wireguard     Enable wireguard formatted output"
    exit 1
}
### End of helper functions ###

# Create temporary files for set operations
temp_file=$(mktemp)
final_temp_file=$(mktemp)

# Cleanup temporary files on exit
trap 'rm -f "$temp_file" "$final_temp_file"' EXIT

# Array to store target IPs
declare -a target_ips

# Variables
sort_enabled=false
wireguard_format=false
ip_addresses=""

# Recursive function to split and exclude
function split_and_exclude() {
    local network=$1
    local prefix=$2
     
    # Check if network contains any of the target IPs
    local contains_ip=false
    local exact_match=false
    for ip in "${target_ips[@]}"; do
        if is_ip_in_network "$ip" "$network" "$prefix"; then
            contains_ip=true

            [[ $prefix -eq 32 ]] && [[ $network -eq $ip ]] && exact_match=true
        fi
    done

    # If the prefix is /32 and there is no exact match, add the network to the list
    if [[ $prefix -eq 32 ]] && ! $exact_match; then
        echo "$(int2str "$network")/$prefix" >> "$temp_file"
    elif [[ $prefix -eq 32 ]]; then
        return
    fi
    
    # If the network does not contain any of the target IPs, add it to the list
    if ! $contains_ip; then
        echo "$(int2str "$network")/$prefix" >> "$temp_file"
        return
    fi
    
    local new_prefix=$((prefix + 1))
    local subnet2=$((network + $(( 1 << (32 - new_prefix)))))
    
    split_and_exclude "$network" "$new_prefix" # Recursively split the first subnet (network)
    split_and_exclude "$subnet2" "$new_prefix" # Recursively split the second subnet
}

function exclude_cidr() {
    local IFS=','
    read -ra ip_list <<< "$1"
    
    # Convert IPs to integers
    target_ips=()
    for ip in "${ip_list[@]}"; do
        target_ips+=("$(ip2int "$ip")")
    done
    
    # Clear temporary files
    > "$temp_file"
    > "$final_temp_file"
    
    # Start with 0.0.0.0/0
    split_and_exclude 0 0
    
    # Remove duplicates and save to final temp file
    sort -u "$temp_file" > "$final_temp_file"
}

[[ $# -lt 1 ]] && echo -e "Error: Missing argument\n" && usage

# Check if the first argument is a help flag
[[ "$1" == "-h" || "$1" == "--help" ]] && usage

ip_addresses="$1"
shift

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--sort)
            sort_enabled=true
            shift
            ;;
        -w|--wireguard)
            wireguard_format=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Error: Unknown option '$1'"
            usage
            ;;
    esac
done

exclude_cidr "$ip_addresses"

[[ $sort_enabled == true ]] && sort -t'/' -k2 -n "$final_temp_file" -o "$final_temp_file"

# If wireguard format, output as a single comma-separated line with AllowedIPs prefix
if [[ "$wireguard_format" == true ]]; then
    echo -n "AllowedIPs = "
    paste -d, -s "$final_temp_file" | sed 's/^//' | sed 's/,/, /g'
    exit 0
fi

# Otherwise, print each line separately
cat "$final_temp_file"

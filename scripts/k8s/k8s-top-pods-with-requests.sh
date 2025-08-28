#!/bin/bash

# Script to show top pods with their resource requests for each namespace
# Usage: ./k8s-top-pods-with-requests.sh [namespace] [top_count]
# If no namespace specified, shows for all namespaces
# If no top_count specified, shows top 5 pods

set -e

# Default values
TOP_COUNT=${2:-5}
NAMESPACE=${1:-""}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to convert memory units to bytes for sorting
convert_memory_to_bytes() {
    local mem=$1
    if [[ $mem =~ ^([0-9.]+)([KMGT]?i?)$ ]]; then
        local value=${BASH_REMATCH[1]}
        local unit=${BASH_REMATCH[2]}
        case $unit in
            "Ki") echo "$(echo "$value * 1024" | bc)" ;;
            "Mi") echo "$(echo "$value * 1024 * 1024" | bc)" ;;
            "Gi") echo "$(echo "$value * 1024 * 1024 * 1024" | bc)" ;;
            "Ti") echo "$(echo "$value * 1024 * 1024 * 1024 * 1024" | bc)" ;;
            *) echo "$value" ;;
        esac
    else
        echo "0"
    fi
}

# Function to convert CPU units to millicores for sorting
convert_cpu_to_millicores() {
    local cpu=$1
    if [[ $cpu =~ ^([0-9.]+)m?$ ]]; then
        local value=${BASH_REMATCH[1]}
        if [[ $cpu == *"m" ]]; then
            echo "$value"
        else
            echo "$(echo "$value * 1000" | bc)"
        fi
    else
        echo "0"
    fi
}

# Function to get pod resource requests
get_pod_requests() {
    local namespace=$1
    local pod_name=$2
    
    local cpu_req=$(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.spec.containers[*].resources.requests.cpu}' 2>/dev/null | tr ' ' '\n' | head -1)
    local mem_req=$(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.spec.containers[*].resources.requests.memory}' 2>/dev/null | tr ' ' '\n' | head -1)
    
    # Default values if not set
    cpu_req=${cpu_req:-"0m"}
    mem_req=${mem_req:-"0Mi"}
    
    echo "$cpu_req,$mem_req"
}

# Function to process namespace
process_namespace() {
    local ns=$1
    
    echo -e "${BLUE}=== Namespace: $ns ===${NC}"
    
    # Check if kubectl top is available
    if ! kubectl top pods -n "$ns" --no-headers 2>/dev/null | head -1 > /dev/null; then
        echo -e "${RED}Error: kubectl top not available or no pods in namespace $ns${NC}"
        return
    fi
    
    # Get top pods data and combine with requests
    local temp_file=$(mktemp)
    
    # Header
    printf "%-30s %-15s %-15s %-15s %-15s\n" "POD NAME" "CPU USAGE" "CPU REQUEST" "MEM USAGE" "MEM REQUEST"
    printf "%-30s %-15s %-15s %-15s %-15s\n" "$(printf '%*s' 30 '' | tr ' ' '-')" "$(printf '%*s' 15 '' | tr ' ' '-')" "$(printf '%*s' 15 '' | tr ' ' '-')" "$(printf '%*s' 15 '' | tr ' ' '-')" "$(printf '%*s' 15 '' | tr ' ' '-')"
    
    # Get pods with usage and requests
    kubectl top pods -n "$ns" --no-headers 2>/dev/null | while read -r pod_name cpu_usage mem_usage; do
        if [[ -n "$pod_name" ]]; then
            local requests=$(get_pod_requests "$ns" "$pod_name")
            local cpu_req=$(echo "$requests" | cut -d',' -f1)
            local mem_req=$(echo "$requests" | cut -d',' -f2)
            
            # Convert for sorting
            local cpu_usage_mc=$(convert_cpu_to_millicores "$cpu_usage")
            
            printf "%-30s %-15s %-15s %-15s %-15s\n" "$pod_name" "$cpu_usage" "$cpu_req" "$mem_usage" "$mem_req"
            
            # Store for sorting
            echo "$cpu_usage_mc|$pod_name|$cpu_usage|$cpu_req|$mem_usage|$mem_req" >> "$temp_file"
        fi
    done | head -n $((TOP_COUNT + 2))  # +2 for header lines
    
    # Show top consumers by CPU
    if [[ -s "$temp_file" ]]; then
        echo -e "\n${YELLOW}Top $TOP_COUNT CPU consumers:${NC}"
        sort -t'|' -k1 -nr "$temp_file" | head -n "$TOP_COUNT" | while IFS='|' read -r cpu_mc pod_name cpu_usage cpu_req mem_usage mem_req; do
            echo -e "${GREEN}$pod_name${NC}: CPU ${cpu_usage} (req: ${cpu_req}), MEM ${mem_usage} (req: ${mem_req})"
        done
    fi
    
    rm -f "$temp_file"
    echo ""
}

# Main execution
echo -e "${BLUE}Kubernetes Top Pods with Resource Requests${NC}"
echo -e "${BLUE}===========================================${NC}\n"

if [[ -n "$NAMESPACE" ]]; then
    # Process specific namespace
    if kubectl get namespace "$NAMESPACE" > /dev/null 2>&1; then
        process_namespace "$NAMESPACE"
    else
        echo -e "${RED}Error: Namespace '$NAMESPACE' not found${NC}"
        exit 1
    fi
else
    # Process all namespaces with pods
    kubectl get namespaces -o name | cut -d'/' -f2 | while read -r ns; do
        # Check if namespace has pods
        if kubectl get pods -n "$ns" --no-headers 2>/dev/null | head -1 > /dev/null; then
            process_namespace "$ns"
        fi
    done
fi

echo -e "${BLUE}Usage: $0 [namespace] [top_count]${NC}"
echo -e "${BLUE}Example: $0 default 10${NC}"
echo -e "${BLUE}Example: $0 kube-system${NC}"
#!/bin/bash
#
# Interactive VM Provisioning from Templates
# Usage: ./provision-vm-1.sh
#
# Provides an interactive menu to select a template and configure a new VM.
#

set -e

# Defaults
STORAGE="ssd-pool"
DEFAULT_MEMORY_GB=2
DEFAULT_CORES=2
DEFAULT_DISK=10

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Get list of templates
get_templates() {
    # Templates have status "stopped" and typically have "template" in config
    # We look for VMs that are actually marked as templates
    local templates=()
    while IFS= read -r line; do
        vmid=$(echo "$line" | awk '{print $1}')
        if [ -n "$vmid" ] && qm config "$vmid" 2>/dev/null | grep -q "^template: 1"; then
            templates+=("$line")
        fi
    done < <(qm list 2>/dev/null | tail -n +2)
    printf '%s\n' "${templates[@]}"
}

# Auto-generate VM ID starting from 500
get_next_vm_id() {
    local count=${1:-1}
    local existing_ids
    existing_ids=$(qm list 2>/dev/null | tail -n +2 | awk '{print $1}' | sort -n)
    local vm_id=500
    while true; do
        local available=true
        for ((i=0; i<count; i++)); do
            if echo "$existing_ids" | grep -q "^$((vm_id + i))$"; then
                available=false
                break
            fi
        done
        if $available; then
            echo "$vm_id"
            return
        fi
        vm_id=$((vm_id + 1))
    done
}

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}            Interactive VM Provisioning                    ${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo ""

# Step 1: Get and display available templates
echo -e "${BLUE}Available Templates:${NC}"
echo ""

TEMPLATES=()
i=1
while IFS= read -r line; do
    if [ -n "$line" ]; then
        vmid=$(echo "$line" | awk '{print $1}')
        name=$(echo "$line" | awk '{print $2}')
        TEMPLATES+=("$vmid:$name")
        printf "  ${GREEN}%d)${NC} %-25s ${BLUE}(ID: %s)${NC}\n" "$i" "$name" "$vmid"
        i=$((i + 1))
    fi
done < <(get_templates)

if [ ${#TEMPLATES[@]} -eq 0 ]; then
    echo -e "${RED}No templates found!${NC}"
    echo ""
    echo "Create a template first with:"
    echo "  create-template.sh"
    exit 1
fi

echo ""

# Step 2: Select template
while true; do
    read -p "Select template [1]: " TEMPLATE_CHOICE
    TEMPLATE_CHOICE=${TEMPLATE_CHOICE:-1}
    
    if [[ "$TEMPLATE_CHOICE" =~ ^[0-9]+$ ]] && [ "$TEMPLATE_CHOICE" -ge 1 ] && [ "$TEMPLATE_CHOICE" -le ${#TEMPLATES[@]} ]; then
        break
    else
        echo -e "${RED}Invalid selection. Please enter 1-${#TEMPLATES[@]}${NC}"
    fi
done

SELECTED=${TEMPLATES[$((TEMPLATE_CHOICE - 1))]}
TEMPLATE_ID="${SELECTED%%:*}"
TEMPLATE_NAME="${SELECTED##*:}"
echo -e "  Selected: ${GREEN}$TEMPLATE_NAME${NC} (ID: $TEMPLATE_ID)"
echo ""

# Step 3: VM Configuration
echo -e "${BLUE}VM Configuration:${NC}"
echo ""

# VM Name (required)
while true; do
    read -p "  VM Name: " VM_NAME
    if [ -n "$VM_NAME" ]; then
        break
    else
        echo -e "  ${RED}Name is required${NC}"
    fi
done

# Cores
read -p "  CPU Cores [$DEFAULT_CORES]: " CORES
CORES=${CORES:-$DEFAULT_CORES}

# Memory (in GB, converted to MB internally)
read -p "  Memory in GB [$DEFAULT_MEMORY_GB]: " MEMORY_GB
MEMORY_GB=${MEMORY_GB:-$DEFAULT_MEMORY_GB}
MEMORY_MB=$((MEMORY_GB * 1024))

# Disk size
read -p "  Disk size in GB [$DEFAULT_DISK]: " DISK
DISK=${DISK:-$DEFAULT_DISK}

# Number of VMs to create
read -p "  Number of VMs [1]: " VM_COUNT
VM_COUNT=${VM_COUNT:-1}
if ! [[ "$VM_COUNT" =~ ^[0-9]+$ ]] || [ "$VM_COUNT" -lt 1 ]; then
    VM_COUNT=1
fi

# Auto-assign VM ID
VM_ID=$(get_next_vm_id "$VM_COUNT")

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}                    VM Summary                             ${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""
if [ "$VM_COUNT" -eq 1 ]; then
    echo -e "  Name:       ${GREEN}$VM_NAME${NC}"
    echo -e "  VM ID:      ${GREEN}$VM_ID${NC}"
else
    FIRST_NAME="${VM_NAME}-01"
    LAST_NAME="${VM_NAME}-$(printf "%02d" "$VM_COUNT")"
    LAST_ID=$((VM_ID + VM_COUNT - 1))
    echo -e "  Names:      ${GREEN}${FIRST_NAME}${NC} ... ${GREEN}${LAST_NAME}${NC}"
    echo -e "  VM IDs:     ${GREEN}${VM_ID}${NC} ... ${GREEN}${LAST_ID}${NC}"
    echo -e "  Count:      ${GREEN}$VM_COUNT${NC}"
fi
echo -e "  Template:   ${GREEN}$TEMPLATE_NAME${NC} (ID: $TEMPLATE_ID)"
echo -e "  Cores:      ${GREEN}$CORES${NC}"
echo -e "  Memory:     ${GREEN}${MEMORY_GB}GB${NC} (${MEMORY_MB}MB)"
echo -e "  Disk:       ${GREEN}${DISK}GB${NC}"
echo -e "  Storage:    ${GREEN}$STORAGE${NC}"
echo ""

# Confirm
read -p "Proceed? [Y/n]: " CONFIRM
CONFIRM=${CONFIRM:-Y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

echo ""

# Single VM path - matches original script exactly
if [ "$VM_COUNT" -eq 1 ]; then
    # Step 4: Clone template
    echo -e "${YELLOW}[1/5]${NC} Cloning template..."
    qm clone "$TEMPLATE_ID" "$VM_ID" --name "$VM_NAME" --full >/dev/null 2>&1

    # Step 5: Set memory and cores
    echo -e "${YELLOW}[2/5]${NC} Configuring resources..."
    qm set "$VM_ID" --memory "$MEMORY_MB" --cores "$CORES" >/dev/null

    # Step 6: Resize disk
    echo -e "${YELLOW}[3/5]${NC} Resizing disk to ${DISK}GB..."
    qm resize "$VM_ID" scsi0 "${DISK}G" >/dev/null

    # Step 7: Start VM
    echo -e "${YELLOW}[4/5]${NC} Starting VM..."
    qm start "$VM_ID" >/dev/null 2>&1

    # Step 8: Get IP
    echo -e "${YELLOW}[5/5]${NC} Getting VM IP address..."

    # Get the VM's MAC address from config
    VM_MAC=$(qm config "$VM_ID" | grep -oP 'virtio=\K[A-F0-9:]+' | tr '[:upper:]' '[:lower:]')
    echo -e "  MAC address: ${BLUE}$VM_MAC${NC}"

    # Give VM time to boot and get DHCP
    echo -e "  Waiting 15s for VM to boot..."
    sleep 15

    # Try to find IP using ip-scan if available
    VM_IP=""
    if [ -f ~/homelab/infra/proxmox/ip-scan.py ]; then
        echo -e "  Scanning network..."
        VM_IP=$(python3 ~/homelab/infra/proxmox/ip-scan.py 2>/dev/null | grep -i "$VM_MAC" | awk '{print $2}')
    fi

    echo ""
    echo ""

    if [ -n "$VM_IP" ]; then
        echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}              VM Created Successfully!                     ${NC}"
        echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  Name:     ${GREEN}$VM_NAME${NC}"
        echo -e "  ID:       ${GREEN}$VM_ID${NC}"
        echo -e "  IP:       ${GREEN}$VM_IP${NC}"
        echo -e "  MAC:      ${GREEN}$VM_MAC${NC}"
        echo ""
    else
        echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}              VM Created (IP pending)                      ${NC}"
        echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  Name:     ${GREEN}$VM_NAME${NC}"
        echo -e "  ID:       ${GREEN}$VM_ID${NC}"
        echo -e "  IP:       ${YELLOW}(still booting - check in a moment)${NC}"
        echo ""
        echo -e "${BLUE}Find IP with:${NC}"
        echo "  python3 ~/homelab/infra/proxmox/ip-scan.py"
        echo "  # Look for MAC: $VM_MAC"
    fi

    echo ""
    exit 0
fi

# Multi-VM path
declare -a CREATED_NAMES
declare -a CREATED_IDS
declare -a CREATED_MACS
declare -a CREATED_IPS

for ((n=1; n<=VM_COUNT; n++)); do
    CURRENT_NAME="${VM_NAME}-$(printf "%02d" "$n")"
    CURRENT_ID=$((VM_ID + n - 1))
    
    echo -e "${CYAN}--- Creating VM $n of $VM_COUNT: $CURRENT_NAME (ID: $CURRENT_ID) ---${NC}"
    echo ""
    
    echo -e "${YELLOW}[1/4]${NC} Cloning template..."
    qm clone "$TEMPLATE_ID" "$CURRENT_ID" --name "$CURRENT_NAME" --full >/dev/null 2>&1
    
    echo -e "${YELLOW}[2/4]${NC} Configuring resources..."
    qm set "$CURRENT_ID" --memory "$MEMORY_MB" --cores "$CORES" >/dev/null
    
    echo -e "${YELLOW}[3/4]${NC} Resizing disk to ${DISK}GB..."
    qm resize "$CURRENT_ID" scsi0 "${DISK}G" >/dev/null
    
    echo -e "${YELLOW}[4/4]${NC} Starting VM..."
    qm start "$CURRENT_ID" >/dev/null 2>&1
    
    CURRENT_MAC=$(qm config "$CURRENT_ID" | grep -oP 'virtio=\K[A-F0-9:]+' | tr '[:upper:]' '[:lower:]')
    
    CREATED_NAMES+=("$CURRENT_NAME")
    CREATED_IDS+=("$CURRENT_ID")
    CREATED_MACS+=("$CURRENT_MAC")
    CREATED_IPS+=("")
    
    echo ""
done

echo -e "${YELLOW}[5/5]${NC} Getting VM IP addresses..."
echo -e "  Waiting 15s for VMs to boot..."
sleep 15

if [ -f ~/homelab/infra/proxmox/ip-scan.py ]; then
    echo -e "  Scanning network..."
    SCAN_OUTPUT=$(python3 ~/homelab/infra/proxmox/ip-scan.py 2>/dev/null)
    
    for ((n=0; n<VM_COUNT; n++)); do
        IP=$(echo "$SCAN_OUTPUT" | grep -i "${CREATED_MACS[$n]}" | awk '{print $2}')
        CREATED_IPS[$n]="$IP"
    done
fi

echo ""
echo ""

ALL_IPS_FOUND=true
for ((n=0; n<VM_COUNT; n++)); do
    if [ -z "${CREATED_IPS[$n]}" ]; then
        ALL_IPS_FOUND=false
        break
    fi
done

if $ALL_IPS_FOUND; then
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}            $VM_COUNT VMs Created Successfully!                   ${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
else
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}            $VM_COUNT VMs Created (some IPs pending)             ${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
fi

echo ""

printf "  ${BOLD}%-20s  %-6s  %-15s  %-17s${NC}\n" "NAME" "ID" "IP" "MAC"
printf "  %-20s  %-6s  %-15s  %-17s\n" "--------------------" "------" "---------------" "-----------------"

for ((n=0; n<VM_COUNT; n++)); do
    NAME="${CREATED_NAMES[$n]}"
    ID="${CREATED_IDS[$n]}"
    IP="${CREATED_IPS[$n]}"
    MAC="${CREATED_MACS[$n]}"
    
    if [ -n "$IP" ]; then
        printf "  ${GREEN}%-20s${NC}  ${GREEN}%-6s${NC}  ${GREEN}%-15s${NC}  ${GREEN}%-17s${NC}\n" "$NAME" "$ID" "$IP" "$MAC"
    else
        printf "  ${GREEN}%-20s${NC}  ${GREEN}%-6s${NC}  ${YELLOW}%-15s${NC}  ${GREEN}%-17s${NC}\n" "$NAME" "$ID" "(pending)" "$MAC"
    fi
done

echo ""

if ! $ALL_IPS_FOUND; then
    echo -e "${BLUE}Find IPs with:${NC}"
    echo "  python3 ~/homelab/infra/proxmox/ip-scan.py"
    echo ""
fi

echo ""

#!/bin/bash
#
# Create a Cloud-Init Template for Proxmox
# Usage: ./create-template.sh
#
# This script lets you select a cloud image, creates a VM,
# configures cloud-init with SSH keys, and converts it to a template.
#

set -e

# Configuration
IMAGE_DIR="/var/lib/vz/template/iso"
STORAGE="ssd-pool"
SSH_KEYS_DIR="$HOME/hl-tools/ssh"

# Template defaults
DEFAULT_CORES=1
DEFAULT_MEMORY=1024  # MB
DEFAULT_DISK=10      # GB
DEFAULT_USER="ubuntu"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Parse image name to generate template name
# e.g., "ubuntu-24.04-cloudimg-amd64.img" -> "ubuntu-24.04-template"
# e.g., "noble-server-cloudimg-amd64.img" -> "noble-server-template"
generate_template_name() {
    local img_name="$1"
    local base_name
    
    # Remove .img extension
    base_name="${img_name%.img}"
    
    # Try to extract meaningful name
    if [[ "$base_name" =~ ^([a-zA-Z]+-[0-9]+\.[0-9]+) ]]; then
        # Matches patterns like "ubuntu-24.04"
        echo "${BASH_REMATCH[1]}-template"
    elif [[ "$base_name" =~ ^([a-zA-Z]+-[a-zA-Z]+) ]]; then
        # Matches patterns like "noble-server"
        echo "${BASH_REMATCH[1]}-template"
    elif [[ "$base_name" =~ ^([a-zA-Z]+) ]]; then
        # Just the first word
        echo "${BASH_REMATCH[1]}-template"
    else
        echo "cloud-template"
    fi
}

# Auto-generate VM ID in 9000+ range
get_next_template_id() {
    local existing_ids
    existing_ids=$(qm list 2>/dev/null | tail -n +2 | awk '{print $1}' | sort -n)
    local vm_id=9000
    while echo "$existing_ids" | grep -q "^${vm_id}$"; do
        vm_id=$((vm_id + 1))
    done
    echo "$vm_id"
}

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}          Cloud-Init Template Creator                      ${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo ""

# Step 1: List available images and let user select
echo -e "${BLUE}Available Cloud Images:${NC}"
echo ""

IMAGES=()
i=1
while IFS= read -r img_path; do
    if [ -n "$img_path" ]; then
        img_name=$(basename "$img_path")
        img_size=$(du -h "$img_path" | cut -f1)
        IMAGES+=("$img_path")
        printf "  ${GREEN}%d)${NC} %-45s ${BLUE}(%s)${NC}\n" "$i" "$img_name" "$img_size"
        i=$((i + 1))
    fi
done < <(find "$IMAGE_DIR" -maxdepth 1 -name "*.img" -type f 2>/dev/null | sort)

if [ ${#IMAGES[@]} -eq 0 ]; then
    echo -e "${RED}No cloud images found in $IMAGE_DIR${NC}"
    echo ""
    echo "Download a cloud image first, e.g.:"
    echo "  cd $IMAGE_DIR"
    echo "  wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
    exit 1
fi

echo ""

# Select image
while true; do
    read -p "Select image [1]: " IMAGE_CHOICE
    IMAGE_CHOICE=${IMAGE_CHOICE:-1}
    
    if [[ "$IMAGE_CHOICE" =~ ^[0-9]+$ ]] && [ "$IMAGE_CHOICE" -ge 1 ] && [ "$IMAGE_CHOICE" -le ${#IMAGES[@]} ]; then
        break
    else
        echo -e "${RED}Invalid selection. Please enter 1-${#IMAGES[@]}${NC}"
    fi
done

IMAGE_PATH="${IMAGES[$((IMAGE_CHOICE - 1))]}"
IMAGE_NAME=$(basename "$IMAGE_PATH")
echo -e "  Selected: ${GREEN}$IMAGE_NAME${NC}"
echo ""

# Generate template name from image
SUGGESTED_NAME=$(generate_template_name "$IMAGE_NAME")
read -p "Template name [$SUGGESTED_NAME]: " TEMPLATE_NAME
TEMPLATE_NAME="${TEMPLATE_NAME:-$SUGGESTED_NAME}"

# Auto-assign VM ID
VM_ID=$(get_next_template_id)

# Configuration prompts
echo ""
echo -e "${BLUE}Template Configuration:${NC}"
read -p "  CPU Cores [$DEFAULT_CORES]: " CORES
CORES="${CORES:-$DEFAULT_CORES}"

read -p "  Memory in MB [$DEFAULT_MEMORY]: " MEMORY
MEMORY="${MEMORY:-$DEFAULT_MEMORY}"

read -p "  Disk size in GB [$DEFAULT_DISK]: " DISK
DISK="${DISK:-$DEFAULT_DISK}"

read -p "  Default user [$DEFAULT_USER]: " CI_USER
CI_USER="${CI_USER:-$DEFAULT_USER}"

# Collect SSH keys from the ssh directory
echo ""
echo -e "${BLUE}SSH Keys:${NC}"
SSH_KEYS_FILE=$(mktemp)
KEY_COUNT=0

# Add keys from ~/tools/ssh/authorized_keys if exists
if [ -f "$SSH_KEYS_DIR/authorized_keys" ]; then
    cat "$SSH_KEYS_DIR/authorized_keys" >> "$SSH_KEYS_FILE"
    KEY_COUNT=$((KEY_COUNT + $(wc -l < "$SSH_KEYS_DIR/authorized_keys")))
fi

# Add all .pub files from ~/tools/ssh/
while IFS= read -r pub_file; do
    if [ -f "$pub_file" ]; then
        cat "$pub_file" >> "$SSH_KEYS_FILE"
        KEY_COUNT=$((KEY_COUNT + 1))
        echo -e "  Found: ${GREEN}$(basename "$pub_file")${NC}"
    fi
done < <(find "$SSH_KEYS_DIR" -maxdepth 1 -name "*.pub" -type f 2>/dev/null)

# Also check ~/.ssh for pve keys
if [ -f "$HOME/.ssh/pve_root.pub" ]; then
    cat "$HOME/.ssh/pve_root.pub" >> "$SSH_KEYS_FILE"
    KEY_COUNT=$((KEY_COUNT + 1))
    echo -e "  Found: ${GREEN}~/.ssh/pve_root.pub${NC}"
fi

if [ "$KEY_COUNT" -eq 0 ]; then
    echo -e "${RED}No SSH keys found!${NC}"
    echo ""
    echo "Add SSH keys to ~/hl-tools/ssh/ or generate one:"
    echo "  ssh-keygen -t ed25519 -f ~/.ssh/pve_root"
    rm -f "$SSH_KEYS_FILE"
    exit 1
fi

echo -e "  Total keys: ${GREEN}$KEY_COUNT${NC}"

# Summary
echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}                  Template Summary                         ${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Template Name:  ${GREEN}$TEMPLATE_NAME${NC}"
echo -e "  VM ID:          ${GREEN}$VM_ID${NC}"
echo -e "  Image:          ${GREEN}$IMAGE_NAME${NC}"
echo -e "  Cores:          ${GREEN}$CORES${NC}"
echo -e "  Memory:         ${GREEN}${MEMORY}MB${NC}"
echo -e "  Disk:           ${GREEN}${DISK}GB${NC}"
echo -e "  Default User:   ${GREEN}$CI_USER${NC}"
echo -e "  SSH Keys:       ${GREEN}$KEY_COUNT key(s)${NC}"
echo -e "  Storage:        ${GREEN}$STORAGE${NC}"
echo ""

# Confirm
read -p "Proceed? [Y/n]: " CONFIRM
CONFIRM=${CONFIRM:-Y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    rm -f "$SSH_KEYS_FILE"
    exit 0
fi

echo ""

# Step 2: Create VM
echo -e "${YELLOW}[1/7]${NC} Creating VM $VM_ID..."
qm create "$VM_ID" \
    --name "$TEMPLATE_NAME" \
    --memory "$MEMORY" \
    --cores "$CORES" \
    --net0 virtio,bridge=vmbr0 \
    --ostype l26 \
    --agent enabled=1 >/dev/null

# Step 3: Import disk
echo -e "${YELLOW}[2/7]${NC} Importing disk image..."
qm importdisk "$VM_ID" "$IMAGE_PATH" "$STORAGE" --format raw >/dev/null 2>&1

# Step 4: Configure VM hardware
echo -e "${YELLOW}[3/7]${NC} Configuring VM hardware..."
qm set "$VM_ID" \
    --scsihw virtio-scsi-pci \
    --scsi0 "$STORAGE:vm-$VM_ID-disk-0" \
    --boot c \
    --bootdisk scsi0 \
    --serial0 socket \
    --vga serial0 >/dev/null

# Step 5: Resize disk
echo -e "${YELLOW}[4/7]${NC} Resizing disk to ${DISK}GB..."
qm resize "$VM_ID" scsi0 "${DISK}G" >/dev/null

# Step 6: Configure cloud-init
echo -e "${YELLOW}[5/7]${NC} Configuring cloud-init..."
qm set "$VM_ID" \
    --ide2 "$STORAGE:cloudinit" \
    --ciuser "$CI_USER" \
    --sshkeys "$SSH_KEYS_FILE" \
    --ipconfig0 ip=dhcp >/dev/null 2>&1

# Step 7: Convert to template
echo -e "${YELLOW}[6/7]${NC} Converting to template..."
qm template "$VM_ID" >/dev/null

# Cleanup
echo -e "${YELLOW}[7/7]${NC} Cleaning up..."
rm -f "$SSH_KEYS_FILE"

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}          Template Created Successfully!                   ${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Template Name:  ${GREEN}$TEMPLATE_NAME${NC}"
echo -e "  Template ID:    ${GREEN}$VM_ID${NC}"
echo -e "  Default User:   ${GREEN}$CI_USER${NC}"
echo ""
echo -e "${BLUE}To create a VM from this template:${NC}"
echo "  ~/hl-tools/provision-vm.sh"

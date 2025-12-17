# Proxmox Homelab Setup Report
**Date:** December 3, 2025

---

## Summary

This session covered setting up ZFS storage, creating an Ubuntu VM template with cloud-init, and configuring Ansible for automated Tailscale deployment.

---

## 1. Storage Setup

### Drives Discovered
| Device | Size | Original Filesystem |
|--------|------|---------------------|
| `/dev/sda` | 1.7 TB | ext4 |
| `/dev/sdb` | 1.7 TB | ext4 |
| `/dev/sdc` | 1.7 TB | ext4 |

### ZFS Pool Created
```bash
zpool create -f -o ashift=12 ssd-pool raidz1 /dev/sda /dev/sdb /dev/sdc
```

| Pool Name | Type | Usable Capacity | Fault Tolerance |
|-----------|------|-----------------|-----------------|
| `ssd-pool` | RAIDZ1 | 3.52 TB | 1 drive failure |

### Added to Proxmox
```bash
pvesm add zfspool ssd-pool -pool ssd-pool -content images,rootdir
```

---

## 2. Ubuntu VM Template (ID: 9000)

### What is a Cloud Image?

Unlike traditional ISO installers, **cloud images** are pre-installed, minimal OS images designed for cloud environments. They include **cloud-init**, a tool that configures the system on first boot (hostname, users, SSH keys, network, etc.).

**Benefits:**
- No manual installation required
- Boots in seconds, not minutes
- Consistent, reproducible deployments
- Perfect for automation and templating

### Cloud Image Used
```
https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
```

Downloaded to: `/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img` (596 MB)

This is Ubuntu 24.04 LTS "Noble Numbat" - a Long Term Support release with updates until 2029.

---

### Step-by-Step Template Creation

#### Step 1: Download the Cloud Image
```bash
cd /var/lib/vz/template/iso
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
```
This downloads the `.img` file which is a QCOW2 disk image containing a minimal Ubuntu installation.

---

#### Step 2: Create an Empty VM Shell
```bash
qm create 9000 --name ubuntu-template --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0
```

| Parameter | Value | Explanation |
|-----------|-------|-------------|
| `9000` | VM ID | Convention: 9000+ for templates |
| `--name` | ubuntu-template | Display name in Proxmox UI |
| `--memory` | 2048 | 2 GB RAM (adjustable per clone) |
| `--cores` | 2 | 2 CPU cores (adjustable per clone) |
| `--net0` | virtio,bridge=vmbr0 | VirtIO network adapter on main bridge |

This creates a VM with no disk yet - just the configuration.

---

#### Step 3: Import the Cloud Image as a Disk
```bash
qm importdisk 9000 /var/lib/vz/template/iso/noble-server-cloudimg-amd64.img ssd-pool
```

This converts the cloud image into a ZFS volume on `ssd-pool` and attaches it to VM 9000 as an **unused disk**. The disk appears as `unused0` in the VM config.

---

#### Step 4: Attach the Disk with VirtIO SCSI Controller
```bash
qm set 9000 --scsihw virtio-scsi-pci --scsi0 ssd-pool:vm-9000-disk-0
```

| Parameter | Value | Explanation |
|-----------|-------|-------------|
| `--scsihw` | virtio-scsi-pci | Modern, high-performance SCSI controller |
| `--scsi0` | ssd-pool:vm-9000-disk-0 | Attach the imported disk to SCSI slot 0 |

**Why VirtIO SCSI?** It's faster than IDE/SATA emulation and supports advanced features like TRIM, discard, and multiple queues.

---

#### Step 5: Add Cloud-Init Drive
```bash
qm set 9000 --ide2 ssd-pool:cloudinit
```

This creates a small virtual CD-ROM drive containing cloud-init configuration. On first boot, cloud-init reads this drive and applies settings (user, SSH keys, network config, etc.).

The cloud-init drive is only ~4MB and regenerates automatically when you change cloud-init settings.

---

#### Step 6: Configure Boot Order
```bash
qm set 9000 --boot c --bootdisk scsi0
```

| Parameter | Value | Explanation |
|-----------|-------|-------------|
| `--boot` | c | Boot from disk (not network or CD) |
| `--bootdisk` | scsi0 | Specifically boot from the SCSI disk |

---

#### Step 7: Configure Serial Console
```bash
qm set 9000 --serial0 socket --vga serial0
```

| Parameter | Value | Explanation |
|-----------|-------|-------------|
| `--serial0` | socket | Create a serial port |
| `--vga` | serial0 | Redirect display to serial console |

**Why serial console?** Cloud images expect serial console output (not VGA). This allows you to see boot messages and access the console via Proxmox's xterm.js without needing VNC.

---

#### Step 8: Enable QEMU Guest Agent
```bash
qm set 9000 --agent enabled=1
```

The QEMU Guest Agent is a helper service running inside the VM that allows Proxmox to:
- Query the VM's IP address
- Perform clean shutdowns
- Freeze filesystems for consistent snapshots
- Sync time

Ubuntu cloud images have `qemu-guest-agent` pre-installed but not running. Cloud-init starts it on first boot.

---

#### Step 9: Configure Cloud-Init Settings
```bash
# Set the default user
qm set 9000 --ciuser ubuntu

# Add SSH public key for passwordless authentication
qm set 9000 --sshkeys /dev/stdin <<< "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF1WilHLdRuxd4ZxJi1SKalgBgR7EaAHHaTDWgMxO+UH gavin@gavin-macbook-pro.localdomain"

# Configure network to use DHCP
qm set 9000 --ipconfig0 ip=dhcp
```

| Parameter | Value | Explanation |
|-----------|-------|-------------|
| `--ciuser` | ubuntu | Username for the default account |
| `--sshkeys` | (your key) | SSH public key injected into `~/.ssh/authorized_keys` |
| `--ipconfig0` | ip=dhcp | First network interface uses DHCP |

**Optional settings you could add:**
```bash
qm set 9000 --cipassword "password"     # Set a password (not recommended)
qm set 9000 --searchdomain home.local   # DNS search domain
qm set 9000 --nameserver 10.0.0.13      # DNS server (e.g., your PiHole)
```

---

#### Step 10: Resize the Disk
```bash
qm resize 9000 scsi0 32G
```

Cloud images ship with small disks (~3.5 GB). This expands the virtual disk to 32 GB. 

**Note:** The filesystem inside the VM will auto-expand on first boot thanks to `cloud-init-growpart`.

---

#### Step 11: Convert to Template
```bash
qm template 9000
```

This locks the VM and marks it as a template. You cannot start a template directly - you can only clone it. The template's disk becomes a read-only base image, and clones use copy-on-write for efficiency.

---

### Template Configuration Summary

| Setting | Value |
|---------|-------|
| Name | `ubuntu-template` |
| OS | Ubuntu 24.04 LTS (Noble) |
| Storage | ssd-pool (ZFS) |
| Disk | 32 GB, VirtIO SCSI |
| RAM | 2 GB |
| Cores | 2 |
| User | `ubuntu` |
| Auth | SSH key only (no password) |
| Network | DHCP via VirtIO NIC |
| Console | Serial (xterm.js compatible) |
| Guest Agent | Enabled |

---

### How Cloud-Init Works on First Boot

When a clone starts for the first time:

1. **BIOS/UEFI** initializes and boots from scsi0
2. **GRUB** loads the Linux kernel
3. **systemd** starts and launches cloud-init
4. **cloud-init** reads the config from the IDE2 CD-ROM drive:
   - Sets hostname (from VM name)
   - Creates user `ubuntu`
   - Injects SSH key into `/home/ubuntu/.ssh/authorized_keys`
   - Configures network (DHCP)
   - Expands filesystem to fill disk
   - Starts `qemu-guest-agent`
5. **VM is ready** - SSH access works immediately

This entire process takes about 15-30 seconds.

---

### Cloning the Template

```bash
# Full clone (independent copy)
qm clone 9000 101 --name my-vm --full

# Linked clone (shares base image, faster, less storage)
qm clone 9000 102 --name my-vm-linked
```

| Clone Type | Storage | Speed | Independence |
|------------|---------|-------|--------------|
| Full | Uses more space | Slower to create | Completely independent |
| Linked | Minimal extra space | Instant | Depends on template |

After cloning, customize as needed:
```bash
qm set 101 --memory 4096 --cores 4
qm resize 101 scsi0 100G
qm start 101
```

---

## 3. Test VM Created (ID: 101)

### VM Configuration
| Setting | Value |
|---------|-------|
| Name | `ubuntu-vm` |
| Cloned From | Template 9000 |
| Disk | 100 GB |
| RAM | 4 GB |
| Cores | 2 |
| IP Address | 10.0.0.64 |

### Clone Command
```bash
qm clone 9000 101 --name ubuntu-vm --full
qm set 101 --memory 4096 --cores 2
qm resize 101 scsi0 100G
qm start 101
```

---

## 4. Ansible Playbook for Tailscale

### Files Created
Located in `/root/homelab-tools/ansible/`

#### `inventory.yml`
```yaml
all:
  vars:
    ansible_user: ubuntu
    ansible_ssh_common_args: '-o ProxyJump=root@pve-root'
  
  hosts:
    ubuntu-vm:
      ansible_host: 10.0.0.64
```

#### `ansible.cfg`
```ini
[defaults]
inventory = inventory.yml
host_key_checking = False
retry_files_enabled = False

[ssh_connection]
pipelining = True
```

#### `install-tailscale.yml`
```yaml
---
- name: Install Tailscale on VM
  hosts: all
  become: yes
  
  vars:
    tailscale_authkey: "{{ lookup('community.general.onepassword', 'tailscale', field='auth-key', vault='infra-secrets') }}"

  tasks:
    - name: Download and run Tailscale install script
      shell: curl -fsSL https://tailscale.com/install.sh | sh
      args:
        creates: /usr/bin/tailscale

    - name: Start and enable tailscaled
      systemd:
        name: tailscaled
        state: started
        enabled: yes

    - name: Authenticate with Tailscale
      command: tailscale up --authkey={{ tailscale_authkey }}

    - name: Get Tailscale IP
      command: tailscale ip -4
      register: tailscale_ip

    - name: Show Tailscale IP
      debug:
        msg: "Tailscale IP: {{ tailscale_ip.stdout }}"
```

### Usage from Mac
```bash
# One-time setup
brew install ansible
ansible-galaxy collection install community.general
scp -r root@pve-root:/root/homelab-tools/ansible ~/ansible-homelab

# Run playbook
cd ~/ansible-homelab
ansible-playbook install-tailscale.yml
```

---

## 5. Useful Commands Reference

### ZFS
```bash
zpool status ssd-pool    # Check pool health
zpool iostat ssd-pool    # View I/O statistics
zfs list                 # View space usage
```

### Proxmox VM Management
```bash
qm list                           # List all VMs
qm clone 9000 <id> --name <name> --full   # Clone template
qm set <id> --memory 4096 --cores 2       # Adjust resources
qm resize <id> scsi0 <size>G              # Resize disk
qm start <id>                             # Start VM
qm stop <id>                              # Stop VM
qm destroy <id>                           # Delete VM
```

### Network / IP Discovery
```bash
python3 /root/homelab-tools/ip-scan.py    # Scan local network
qm guest cmd <id> network-get-interfaces  # Get VM IP (requires QEMU agent)
```

---

## 6. Network Overview

| Host | Local IP | Tailscale IP | Purpose |
|------|----------|--------------|---------|
| pve-root | 10.0.0.x | 100.106.79.65 | Proxmox host |
| ubuntu-vm | 10.0.0.64 | (new) | Test VM |
| dockzilla | 10.0.0.114 | 100.80.160.9 | Docker host |
| pihole | 10.0.0.13 | - | DNS |

---

## Next Steps

1. **Set VM password** (optional): `sudo passwd ubuntu`
2. **Clone more VMs** as needed from template 9000
3. **Approve new Tailscale devices** in admin console after running playbook
4. **Add more content types** to ssd-pool if needed (ISOs, backups, etc.)

---

*Generated on Proxmox VE (pve-root)*


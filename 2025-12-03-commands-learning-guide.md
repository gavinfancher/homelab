# Command Learning Guide
**Session Date:** December 3, 2025

This document lists every command run during the session, in order, with explanations to help you learn.

---

## Part 1: Discovering and Mounting Drives

### Command 1: List Block Devices
```bash
lsblk -f
```
**Purpose:** Show all storage devices (disks, partitions) with their filesystem types and mount points.

**Key flags:**
- `-f` = Show filesystem info (type, UUID, mount point, usage)

**What we learned:** Found 3 unmounted SSDs (sda, sdb, sdc) each with ext4 partitions.

---

### Command 2: Show Block Device IDs
```bash
blkid
```
**Purpose:** Display UUIDs and filesystem types for all partitions.

**Why UUIDs matter:** Device names like `/dev/sda` can change between reboots (e.g., if you add a drive). UUIDs are permanent identifiers that always point to the same partition.

---

### Command 3: Create Mount Points and Mount Drives
```bash
mkdir -p /mnt/ssd01 /mnt/ssd02 /mnt/ssd03
mount /dev/sda1 /mnt/ssd01
mount /dev/sdb1 /mnt/ssd02
mount /dev/sdc1 /mnt/ssd03
```
**Purpose:** Create directories and mount the drives to access their contents.

**Key concepts:**
- `mkdir -p` = Create directory and any parent directories needed
- `mount <device> <directory>` = Make a filesystem accessible at that path

**Note:** These mounts are temporary - they disappear on reboot.

---

### Command 4: Verify Mounts
```bash
lsblk -f /dev/sda /dev/sdb /dev/sdc
```
**Purpose:** Confirm the drives are now mounted at the correct locations.

---

### Command 5: Make Mounts Permanent (fstab)
We edited `/etc/fstab` to add:
```
UUID=d9f3d966-690b-444f-95a5-9325f73d12e0 /mnt/ssd01 ext4 defaults 0 2
UUID=7f58000f-2164-4e9e-99a6-5d7926306b74 /mnt/ssd02 ext4 defaults 0 2
UUID=5a1e5656-32a8-48ab-9cae-86bedd608f21 /mnt/ssd03 ext4 defaults 0 2
```
**Purpose:** Tell Linux to mount these drives automatically on every boot.

**fstab columns:**
1. Filesystem (UUID or device)
2. Mount point
3. Filesystem type
4. Options (`defaults` = standard options)
5. Dump (0 = don't backup)
6. Pass (2 = check filesystem after root)

---

### Command 6: Test fstab
```bash
mount -a
```
**Purpose:** Mount everything in `/etc/fstab` that isn't already mounted. If this fails, you have a typo in fstab (which could prevent boot!).

---

## Part 2: Creating ZFS Pool

### Command 7: Unmount Drives
```bash
umount /mnt/ssd01 /mnt/ssd02 /mnt/ssd03
rmdir /mnt/ssd01 /mnt/ssd02 /mnt/ssd03
```
**Purpose:** Unmount the drives so we can repurpose them for ZFS.

---

### Command 8: Wipe Filesystem Signatures
```bash
wipefs -a /dev/sda /dev/sdb /dev/sdc
```
**Purpose:** Remove all filesystem signatures (partition tables, ext4 headers, etc.) from the drives.

**Key flags:**
- `-a` = Wipe ALL signatures, not just the first one

**Why needed:** ZFS needs clean drives. Old signatures can confuse the system.

---

### Command 9: Create ZFS Pool
```bash
zpool create -f -o ashift=12 ssd-pool raidz1 /dev/sda /dev/sdb /dev/sdc
```
**Purpose:** Create a RAIDZ1 (similar to RAID5) pool from the 3 drives.

**Key flags:**
- `-f` = Force (override warnings about existing data)
- `-o ashift=12` = Use 4K sectors (optimal for modern SSDs)

**Pool breakdown:**
- `ssd-pool` = Name of the pool
- `raidz1` = RAID level (can lose 1 drive)
- `/dev/sda /dev/sdb /dev/sdc` = The drives to use

**Result:** 3x 1.7TB drives → 3.52TB usable (one drive worth of space used for parity)

---

### Command 10: Verify Pool Status
```bash
zpool status ssd-pool
zfs list
```
**Purpose:** Confirm the pool was created correctly and show available space.

---

### Command 11: Add Pool to Proxmox Storage
```bash
pvesm add zfspool ssd-pool -pool ssd-pool -content images,rootdir
```
**Purpose:** Register the ZFS pool as a Proxmox storage location.

**Key flags:**
- `zfspool` = Storage type
- `ssd-pool` = Storage name in Proxmox
- `-pool ssd-pool` = The ZFS pool to use
- `-content images,rootdir` = Allow VM disks and container root filesystems

---

### Command 12: Verify Proxmox Storage
```bash
pvesm status
```
**Purpose:** List all Proxmox storage and confirm `ssd-pool` appears.

---

## Part 3: Creating Ubuntu VM Template

### Command 13: Download Ubuntu Cloud Image
```bash
cd /var/lib/vz/template/iso
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
```
**Purpose:** Download the Ubuntu 24.04 cloud image (pre-installed OS, ~596MB).

**Path explained:** `/var/lib/vz/template/iso` is where Proxmox stores ISO and image files.

---

### Command 14: Create Empty VM
```bash
qm create 9000 --name ubuntu-template --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0
```
**Purpose:** Create a new VM with basic settings but no disk yet.

**Key flags:**
- `9000` = VM ID (convention: 9000+ for templates)
- `--memory 2048` = 2GB RAM
- `--cores 2` = 2 CPU cores
- `--net0 virtio,bridge=vmbr0` = VirtIO network card on main bridge

---

### Command 15: Import Cloud Image as Disk
```bash
qm importdisk 9000 /var/lib/vz/template/iso/noble-server-cloudimg-amd64.img ssd-pool
```
**Purpose:** Convert the cloud image to a VM disk on the ZFS pool.

**What happens:** 
- Proxmox converts the .img file to a ZFS volume
- Creates `ssd-pool:vm-9000-disk-0`
- Appears as "unused disk" in VM config

---

### Command 16: Attach Disk with VirtIO SCSI
```bash
qm set 9000 --scsihw virtio-scsi-pci --scsi0 ssd-pool:vm-9000-disk-0
```
**Purpose:** Attach the imported disk to the VM using the fastest disk controller.

**Key flags:**
- `--scsihw virtio-scsi-pci` = Use VirtIO SCSI controller (fast, modern)
- `--scsi0` = First SCSI disk slot

---

### Command 17: Add Cloud-Init Drive
```bash
qm set 9000 --ide2 ssd-pool:cloudinit
```
**Purpose:** Create a special virtual CD-ROM that contains cloud-init configuration.

**How it works:**
1. Proxmox generates an ISO with your settings (user, SSH key, network)
2. Attaches it as a CD-ROM drive (ide2)
3. On first boot, cloud-init reads this and configures the system

---

### Command 18: Set Boot Order
```bash
qm set 9000 --boot c --bootdisk scsi0
```
**Purpose:** Tell the VM to boot from the SCSI disk.

**Key flags:**
- `--boot c` = Boot from disk (c=disk, d=cdrom, n=network)
- `--bootdisk scsi0` = Specifically use scsi0

---

### Command 19: Configure Serial Console
```bash
qm set 9000 --serial0 socket --vga serial0
```
**Purpose:** Enable serial console access for cloud images.

**Why needed:** Cloud images output to serial by default, not VGA. This lets you see boot messages in Proxmox's web console.

---

### Command 20: Enable QEMU Guest Agent
```bash
qm set 9000 --agent enabled=1
```
**Purpose:** Tell Proxmox to communicate with the qemu-guest-agent inside the VM.

**Benefits:**
- Get VM IP address from Proxmox
- Clean shutdown without ACPI
- Filesystem freeze for snapshots

---

### Command 21: Set Cloud-Init User
```bash
qm set 9000 --ciuser ubuntu
```
**Purpose:** Create a user named `ubuntu` on first boot.

---

### Command 22: Add SSH Key
```bash
qm set 9000 --sshkeys /dev/stdin <<< "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF1WilHLdRuxd4ZxJi1SKalgBgR7EaAHHaTDWgMxO+UH gavin@gavin-macbook-pro.localdomain"
```
**Purpose:** Inject your SSH public key into the VM.

**How it works:**
1. Key is stored in `/etc/pve/qemu-server/9000.conf` (URL-encoded)
2. On boot, cloud-init reads it from the cloudinit drive
3. Cloud-init writes it to `/home/ubuntu/.ssh/authorized_keys`
4. You can SSH without a password

---

### Command 23: Configure Network (DHCP)
```bash
qm set 9000 --ipconfig0 ip=dhcp
```
**Purpose:** Tell cloud-init to use DHCP for the first network interface.

**Alternatives:**
- Static IP: `--ipconfig0 ip=10.0.0.50/24,gw=10.0.0.1`

---

### Command 24: Resize Disk
```bash
qm resize 9000 scsi0 32G
```
**Purpose:** Expand the virtual disk from ~3.5GB to 32GB.

**What happens inside VM:** Cloud-init's `growpart` module automatically expands the filesystem on first boot.

---

### Command 25: Convert to Template
```bash
qm template 9000
```
**Purpose:** Lock the VM and mark it as a template.

**What changes:**
- Cannot start the VM directly
- Disk becomes read-only base image
- Clones use copy-on-write (efficient)

---

### Command 26: View Template Config
```bash
qm config 9000
```
**Purpose:** Display all configuration settings for the VM/template.

---

## Part 4: Creating a VM from Template

### Command 27: Clone Template
```bash
qm clone 9000 101 --name ubuntu-vm --full
```
**Purpose:** Create a new VM from the template.

**Key flags:**
- `9000` = Source template ID
- `101` = New VM ID
- `--name ubuntu-vm` = Name for the new VM
- `--full` = Full clone (vs linked clone)

**Full vs Linked:**
- Full: Independent copy, uses more space, can delete template
- Linked: Shares base image, fast, depends on template existing

---

### Command 28: Customize Clone
```bash
qm set 101 --memory 4096 --cores 2
qm resize 101 scsi0 100G
```
**Purpose:** Adjust RAM to 4GB and expand disk to 100GB.

---

### Command 29: Start VM
```bash
qm start 101
```
**Purpose:** Boot the virtual machine.

---

### Command 30: Check VM Status
```bash
qm status 101
```
**Purpose:** Confirm the VM is running.

---

### Command 31: Try to Get VM IP via Guest Agent
```bash
qm guest cmd 101 network-get-interfaces
```
**Purpose:** Query the QEMU guest agent for network information.

**Note:** This requires the guest agent to be running inside the VM (takes ~30 seconds after boot).

---

### Command 32: Scan Network for VM IP
```bash
python3 /root/homelab-tools/ip-scan.py
```
**Purpose:** Use nmap to scan the local network and find all hosts (including the new VM).

**Result:** Found VM at `10.0.0.64`

---

## Part 5: Tailscale Status

### Command 33: Check Tailscale Status
```bash
tailscale status | head -5
```
**Purpose:** Show connected Tailscale devices and their IPs.

**Output showed:**
- `pve-root` = This Proxmox server (100.106.79.65)
- `gavin-macbook-pro` = Your Mac (connected via relay)

---

## Summary: Command Categories

### Disk/Storage Commands
| Command | Purpose |
|---------|---------|
| `lsblk` | List block devices |
| `blkid` | Show UUIDs |
| `mount` | Mount filesystem |
| `umount` | Unmount filesystem |
| `wipefs` | Clear filesystem signatures |

### ZFS Commands
| Command | Purpose |
|---------|---------|
| `zpool create` | Create new pool |
| `zpool status` | Check pool health |
| `zfs list` | Show datasets and usage |

### Proxmox VM Commands (qm)
| Command | Purpose |
|---------|---------|
| `qm create` | Create new VM |
| `qm set` | Modify VM settings |
| `qm importdisk` | Import disk image |
| `qm resize` | Resize disk |
| `qm template` | Convert to template |
| `qm clone` | Clone VM/template |
| `qm start/stop` | Start/stop VM |
| `qm config` | Show VM config |
| `qm status` | Show VM status |
| `qm guest cmd` | Run guest agent command |

### Proxmox Storage Commands (pvesm)
| Command | Purpose |
|---------|---------|
| `pvesm add` | Add storage |
| `pvesm status` | List storage |

---

## Quick Reference Card

```bash
# See drives
lsblk -f

# Create ZFS pool
zpool create -f -o ashift=12 <name> raidz1 /dev/sda /dev/sdb /dev/sdc

# Add to Proxmox
pvesm add zfspool <name> -pool <name> -content images,rootdir

# Create VM from cloud image
qm create <id> --name <name> --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0
qm importdisk <id> <image.img> <storage>
qm set <id> --scsihw virtio-scsi-pci --scsi0 <storage>:vm-<id>-disk-0
qm set <id> --ide2 <storage>:cloudinit
qm set <id> --boot c --bootdisk scsi0
qm set <id> --serial0 socket --vga serial0
qm set <id> --agent enabled=1
qm set <id> --ciuser <username>
qm set <id> --sshkeys <keyfile>
qm set <id> --ipconfig0 ip=dhcp
qm resize <id> scsi0 <size>G
qm template <id>

# Clone and start
qm clone <template-id> <new-id> --name <name> --full
qm start <id>

# Find VM IP
python3 /root/homelab-tools/ip-scan.py
```

---

*Generated from session on December 3, 2025*


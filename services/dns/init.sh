#!/bin/bash
set -e

echo "=== DNS Stack Initial Startup ==="

# Check if port 53 is in use
if sudo lsof -i :53 >/dev/null 2>&1; then
    echo "Port 53 is in use, checking if it's systemd-resolved..."
    
    if sudo lsof -i :53 | grep -q systemd-r; then
        echo "systemd-resolved is using port 53"
        
        # Check if DNSStubListener is already disabled
        if grep -q "^DNSStubListener=no" /etc/systemd/resolved.conf 2>/dev/null; then
            echo "DNSStubListener already disabled, restarting systemd-resolved..."
            sudo systemctl restart systemd-resolved
        else
            echo "Disabling DNSStubListener..."
            sudo sed -i 's/#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf
            # Also handle case where it's uncommented but set to yes
            sudo sed -i 's/^DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf
            # If neither existed, append it
            if ! grep -q "^DNSStubListener=no" /etc/systemd/resolved.conf; then
                echo "DNSStubListener=no" | sudo tee -a /etc/systemd/resolved.conf
            fi
            sudo systemctl restart systemd-resolved
        fi
        
        # Give it a moment to release the port
        sleep 2
        
        # Verify port is now free
        if sudo lsof -i :53 >/dev/null 2>&1; then
            echo "ERROR: Port 53 is still in use after disabling stub listener"
            sudo lsof -i :53
            exit 1
        fi
        echo "Port 53 is now free"
    else
        echo "ERROR: Port 53 is in use by something other than systemd-resolved:"
        sudo lsof -i :53
        exit 1
    fi
else
    echo "Port 53 is free"
fi

# Check required files exist
echo "Checking required files..."
for file in docker-compose.yml Dockerfile Caddyfile pihole.toml; do
    if [[ ! -f "$file" ]]; then
        echo "ERROR: Missing required file: $file"
        exit 1
    fi
    echo "  ✓ $file"
done

# Check for .env file (optional but warn if missing)
if [[ ! -f ".env" ]]; then
    echo ".env file not found - make sure CLOUDFLARE_API_TOKEN is set"
fi

# Tear down any existing containers (ensures clean port bindings)
echo "Stopping any existing containers..."
docker compose down 2>/dev/null || true

# Start the stack
echo "Starting docker compose..."
docker compose up -d

echo "=== Startup complete ==="
docker compose ps

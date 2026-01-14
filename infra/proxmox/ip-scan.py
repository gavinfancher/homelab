#!/usr/bin/env python3

import subprocess
import re

SUBNET = "10.0.0.0/24"
EXCLUDE_IPS = {"10.0.0.10", "10.0.0.100"}

print(f"Scanning {SUBNET}...\n")

result = subprocess.run(['nmap', '-sn', SUBNET], capture_output=True, text=True)
output = result.stdout

hosts = []
current = {}

for line in output.split('\n'):
    if 'Nmap scan report for' in line:
        if current:
            hosts.append(current)
        
        match = re.search(r'Nmap scan report for (.+) \(([0-9.]+)\)', line)
        if match:
            current = {'ip': match.group(2), 'hostname': match.group(1), 'mac': 'N/A'}
        else:
            match = re.search(r'Nmap scan report for ([0-9.]+)', line)
            if match:
                current = {'ip': match.group(1), 'hostname': 'N/A', 'mac': 'N/A'}
    
    elif 'MAC Address:' in line and current:
        match = re.search(r'MAC Address: ([0-9A-F:]+)', line, re.IGNORECASE)
        if match:
            current['mac'] = match.group(1)

if current:
    hosts.append(current)

# Filter out local/excluded IPs
hosts = [h for h in hosts if h['ip'] not in EXCLUDE_IPS]

# Sort by hostname, N/A last
hosts.sort(key=lambda h: (h['hostname'] == 'N/A', h['hostname']))

if hosts:
    max_ip = max(len(h['ip']) for h in hosts)
    max_hostname = max(len(h['hostname']) for h in hosts)
    max_mac = max(len(h['mac']) for h in hosts)
    
    max_ip = max(max_ip, len('IP_ADDRESS'))
    max_hostname = max(max_hostname, len('HOSTNAME'))
    max_mac = max(max_mac, len('MAC_ADDRESS'))
    
    print(f"{'HOSTNAME':<{max_hostname}}  {'IP_ADDRESS':<{max_ip}}  {'MAC_ADDRESS':<{max_mac}}")
    print('-' * (max_hostname + max_ip + max_mac + 4))
    
    for h in hosts:
        print(f"{h['hostname']:<{max_hostname}}  {h['ip']:<{max_ip}}  {h['mac']:<{max_mac}}")
    
    print(f"\nTotal hosts found: {len(hosts)}")
else:
    print("No hosts found.")


#!/bin/bash
# Check if script is run as root
if [ "$EUID" -ne 0 ]; then
 echo "Please run as root"
 exit 1
fi

# Install bc based on system package manager
if command -v apt-get > /dev/null; then
    apt-get update && apt-get install -y bc
elif command -v yum > /dev/null; then
    yum update -y && yum install -y bc
elif command -v apk > /dev/null; then
    apk update && apk add bc
else
    echo "Could not install bc. Please install it manually."
    exit 1
fi

# Stop existing service if running
if command -v systemctl > /dev/null; then
    systemctl stop ak_client
elif command -v rc-service > /dev/null; then
    rc-service ak_client stop
else
    echo "Could not stop the ak_client service. Please stop it manually."
fi

# Function to detect main network interface
get_main_interface() {
   local interfaces=$(ip -o link show | \
       awk -F': ' '$2 !~ /^((lo|docker|veth|br-|virbr|tun|vnet|wg|vmbr|dummy|gre|sit|vlan|lxc|lxd|warp|tap))/{print $2}' | \
       grep -v '@')
   
   local interface_count=$(echo "$interfaces" | wc -l)
   
   # 格式化流量大小的函数
   format_bytes() {
       local bytes=$1
       if [ $bytes -lt 1024 ]; then
           echo "${bytes} B"
       elif [ $bytes -lt 1048576 ]; then # 1024*1024
           echo "$(echo "scale=2; $bytes/1024" | bc) KB"
       elif [ $bytes -lt 1048576 ]; then # 1024*1024
           echo "$(echo "scale=2; $bytes/1024" | bc) KB"
       elif [ $bytes -lt 1073741824 ]; then # 1024*1024*1024
           echo "$(echo "scale=2; $bytes/1024/1024" | bc) MB"
       elif [ $bytes -lt 1099511627776 ]; then # 1024*1024*1024*1024
           echo "$(echo "scale=2; $bytes/1024/1024/1024" | bc) GB"
       else
           echo "$(echo "scale=2; $bytes/1024/1024/1024/1024" | bc) TB"
       fi
   }
   
   # 显示网卡流量的函数
   show_interface_traffic() {
       local interface=$1
       if [ -d "/sys/class/net/$interface" ]; then
           local rx_bytes=$(cat /sys/class/net/$interface/statistics/rx_bytes)
           local tx_bytes=$(cat /sys/class/net/$interface/statistics/tx_bytes)
           echo "   ↓ Received: $(format_bytes $rx_bytes)"
           echo "   ↑ Sent: $(format_bytes $tx_bytes)"
       else
           echo "   无法读取流量信息"
       fi
   }
   
   # 如果没有找到合适的接口或有多个接口时显示所有可用接口
   echo "所有可用的网卡接口:" >&2
   echo "------------------------" >&2
   local i=1
   while read -r interface; do
       echo "$i) $interface" >&2
       show_interface_traffic "$interface" >&2
       i=$((i+1))
   done < <(ip -o link show | grep -v "lo:" | awk -F': ' '{print $2}')
   echo "------------------------" >&2
   
   while true; do
       read -p "请选择网卡，如上方显示异常或没有需要的网卡，请直接填入网卡名: " selection
       
       # 检查是否为数字
       if [[ "$selection" =~ ^[0-9]+$ ]]; then
           # 如果是数字，检查是否在有效范围内
           selected_interface=$(ip -o link show | grep -v "lo:" | sed -n "${selection}p" | awk -F': ' '{print $2}')
           if [ -n "$selected_interface" ]; then
               echo "已选择网卡: $selected_interface" >&2
               echo "$selected_interface"
               break
           else
               echo "无效的选择，请重新输入" >&2
               continue
           fi
       else
           # 直接使用输入的网卡名
           echo "已选择网卡: $selection" >&2
           echo "$selection"
           break
       fi
   done
}

# Check if all arguments are provided
if [ "$#" -ne 3 ]; then
 echo "Usage: $0 <auth_secret> <url> <name>"
 echo "Example: $0 your_secret wss://api.123.321 HK-Akile"
 exit 1
fi

# Get system architecture
ARCH=$(uname -m)
CLIENT_FILE="akile_client-linux-amd64"

# Set appropriate client file based on architecture
if [ "$ARCH" = "x86_64" ]; then
 CLIENT_FILE="akile_client-linux-amd64"
elif [ "$ARCH" = "aarch64" ]; then
 CLIENT_FILE="akile_client-linux-arm64"
elif [ "$ARCH" = "x86_64" ] && [ "$(uname -s)" = "Darwin" ]; then
 CLIENT_FILE="akile_client-darwin-amd64"
else
 echo "Unsupported architecture: $ARCH"
 exit 1
fi

# Assign command line arguments to variables
auth_secret="$1"
url="$2"
monitor_name="$3"

# Get network interface
net_name=$(get_main_interface)
echo "Using network interface: $net_name"

# Create directory and change to it
mkdir -p /etc/ak_monitor/
cd /etc/ak_monitor/

# Download client
wget -O client https://github.com/akile-network/akile_monitor/releases/latest/download/$CLIENT_FILE
chmod 777 client

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    OS=$(uname -s)
fi

# Create systemd service file
if command -v systemctl > /dev/null && { [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; }; then
cat > /etc/systemd/system/ak_client.service << 'EOF'
[Unit]
Description=AkileCloud Monitor Service
After=network.target nss-lookup.target
Wants=network.target

[Service]
User=root
Group=root
Type=simple
LimitAS=infinity
LimitRSS=infinity
LimitCORE=infinity
LimitNOFILE=999999999
WorkingDirectory=/etc/ak_monitor/
ExecStart=/etc/ak_monitor/client
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

# Create client configuration
cat > /etc/ak_monitor/client.json << EOF
{
"auth_secret": "${auth_secret}",
"url": "${url}",
"net_name": "${net_name}",
"name": "${monitor_name}"
}
EOF

# Set proper permissions
chmod 644 /etc/ak_monitor/client.json
chmod 644 /etc/systemd/system/ak_client.service

# Reload systemd and enable service
systemctl daemon-reload
systemctl enable ak_client.service
systemctl start ak_client.service

echo "Installation complete! Service status:"
systemctl status ak_client.service

elif command -v rc-service > /dev/null && [ "$OS" = "alpine" ]; then
# 系统为 Alpine (OpenRC)
    echo "Creating OpenRC service script..."

    cat > /etc/init.d/ak_client << 'EOF'
#!/sbin/openrc-run

description="AkileCloud Monitor Service"

command="/etc/ak_monitor/client"
command_args=""
pidfile="/run/ak_client.pid"
user="root"
group="root"
directory="/etc/ak_monitor"

depend() {
    after net
}

supervisor=supervise-daemon
output_log="/var/log/ak_monitor.log"
error_log="/var/log/ak_monitor.err"
respawn_delay=1
respawn_max=0

start() {
    export RC_SVCNAME="ak_client"
    ebegin "Starting AkileCloud Monitor Service"
    supervise-daemon $RC_SVCNAME --start --pidfile $pidfile --user $user --group $group --chdir $directory --stdout $output_log --stderr $error_log --respawn-delay $respawn_delay --respawn-max $respawn_max -- $command
    eend $?
}

stop() {
    export RC_SVCNAME="ak_client"
    ebegin "Stopping AkileCloud Monitor Service"
    supervise-daemon $RC_SVCNAME --stop --pidfile $pidfile
    eend $?
}

restart() {
    stop
    start
}
EOF

# Create client configuration
cat > /etc/ak_monitor/client.json << EOF
{
"auth_secret": "${auth_secret}",
"url": "${url}",
"net_name": "${net_name}",
"name": "${monitor_name}"
}
EOF

# Set proper permissions
chmod 644 /etc/ak_monitor/client.json
chmod 755 /etc/init.d/ak_client

rc-service ak_client restart
rc-update add ak_client default

echo "Installation complete! Service status:"
rc-service ak_client status

else
    echo "This script only supports systemd or OpenRC-based systems."
    exit 1
fi

#!/bin/bash

# Get Username
username=$(whoami)
admintoken=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c16)

# Identify OS
if [ -f /etc/os-release ]; then
    # freedesktop.org and systemd
    . /etc/os-release
    OS_NAME=$NAME
    OS_VERSION=$VERSION_ID

    UPSTREAM_ID=${ID_LIKE,,}

    # Fallback to ID_LIKE if ID was not 'ubuntu' or 'debian'
    if [ "${UPSTREAM_ID}" != "debian" ] && [ "${UPSTREAM_ID}" != "ubuntu" ]; then
        UPSTREAM_ID="$(echo ${ID_LIKE,,} | sed s/\"//g | cut -d' ' -f1)"
    fi

elif type lsb_release >/dev/null 2>&1; then
    # linuxbase.org
    OS_NAME=$(lsb_release -si)
    OS_VERSION=$(lsb_release -sr)
elif [ -f /etc/lsb-release ]; then
    # For some versions of Debian/Ubuntu without lsb_release command
    . /etc/lsb-release
    OS_NAME=$DISTRIB_ID
    OS_VERSION=$DISTRIB_RELEASE
elif [ -f /etc/debian_version ]; then
    # Older Debian/Ubuntu/etc.
    OS_NAME=Debian
    OS_VERSION=$(cat /etc/debian_version)
elif [ -f /etc/SuSe-release ]; then
    # Older SuSE/etc.
    OS_NAME=SuSE
    OS_VERSION=$(cat /etc/SuSe-release)
elif [ -f /etc/redhat-release ]; then
    # Older Red Hat, CentOS, etc.
    OS_NAME=RedHat
    OS_VERSION=$(cat /etc/redhat-release)
else
    # Fall back to uname, e.g. "Linux <version>", also works for BSD, etc.
    OS_NAME=$(uname -s)
    OS_VERSION=$(uname -r)
fi

# Output debugging info if $DEBUG is set
if [ "$DEBUG" = "true" ]; then
    echo "OS: $OS_NAME"
    echo "Version: $OS_VERSION"
    echo "Upstream ID: $UPSTREAM_ID"
    exit 0
fi

# Setup prerequisites for server
# Common named prerequisites
COMMON_PREREQ="curl wget unzip tar"
DEB_PREREQ="dnsutils"
RPM_PREREQ="bind-utils"

echo "Installing prerequisites"
if [ "${ID}" = "debian" ] || [ "$OS_NAME" = "Ubuntu" ] || [ "$OS_NAME" = "Debian" ]  || [ "${UPSTREAM_ID}" = "ubuntu" ] || [ "${UPSTREAM_ID}" = "debian" ]; then
    sudo apt-get update
    sudo apt-get install -y ${COMMON_PREREQ} ${DEB_PREREQ}
elif [ "$OS_NAME" = "CentOS" ] || [ "$OS_NAME" = "RedHat" ]   || [ "${UPSTREAM_ID}" = "rhel" ] ; then
    # OpenSUSE 15.4 fails to run the relay service and hangs waiting for it
    # Needs more work before it can be enabled
    # || [ "${UPSTREAM_ID}" = "suse" ]
    sudo yum update -y
    sudo yum install -y ${COMMON_PREREQ} ${RPM_PREREQ}
else
    echo "Unsupported OS"
    # Here you could ask the user for permission to try and install anyway
    # If they say yes, then do the install
    # If they say no, exit the script
    exit 1
fi

# Choice for DNS or IP
PS3='Choose your preferred option, IP or DNS/Domain:'
OPTIONS=("IP" "DNS/Domain")
select OPTION in "${OPTIONS[@]}"; do
case $OPTION in
"IP")
    wanip=$(dig @resolver4.opendns.com myip.opendns.com +short)
    break
    ;;
"DNS/Domain")
    echo -ne "Enter your preferred domain/DNS address: "
    read wanip
    # Check if wanip is a valid domain
    if ! [[ $wanip =~ ^[a-zA-Z0-9]+([a-zA-Z0-9.-]*[a-zA-Z0-9]+)?$ ]]; then
        echo "Invalid domain/DNS address"
        exit 1
    fi
    break
    ;;
*) echo "Invalid option $REPLY";;
esac
done

# Create folder /opt/rustdesk/
if [ ! -d "/opt/rustdesk" ]; then
    echo "Creating /opt/rustdesk"
    sudo mkdir -p /opt/rustdesk/
fi
sudo chown "${username}" -R /opt/rustdesk
cd /opt/rustdesk/ || exit 1

# Download latest version of Rustdesk
LATEST_VERSION=$(curl https://api.github.com/repos/rustdesk/rustdesk-server/releases/latest -s | grep "tag_name" | awk '{print substr($2, 2, length($2)-3) }')
wget "https://github.com/rustdesk/rustdesk-server/releases/download/${LATEST_VERSION}/rustdesk-server-linux-amd64.zip"
unzip rustdesk-server-linux-amd64.zip

# Create folder /var/log/rustdesk/
if [ ! -d "/var/log/rustdesk" ]; then
    echo "Creating /var/log/rustdesk"
    sudo mkdir -p /var/log/rustdesk/
fi
sudo chown "${username}" -R /var/log/rustdesk/

# Setup Systemd to launch hbbs
hbbs_service="$(cat << EOF
[Unit]
Description=Rustdesk Signal Server
[Service]
Type=simple
LimitNOFILE=1000000
ExecStart=/opt/rustdesk/amd64/hbbs -k _
WorkingDirectory=/opt/rustdesk/amd64
User=${username}
Group=${username}
Restart=always
StandardOutput=append:/var/log/rustdesk/signalserver.log
StandardError=append:/var/log/rustdesk/signalserver.error
# Restart service after 10 seconds if service crashes
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
)"
echo "${hbbs_service}" | sudo tee /etc/systemd/system/hbbs.service > /dev/null
sudo systemctl daemon-reload
sudo systemctl enable hbbs.service
sudo systemctl start hbbs.service

# Setup Systemd to launch hbbr
hbbr_service="$(cat << EOF
[Unit]
Description=Rustdesk Relay Server
[Service]
Type=simple
LimitNOFILE=1000000
ExecStart=/opt/rustdesk/amd64/hbbr -k _
WorkingDirectory=/opt/rustdesk/amd64
User=${username}
Group=${username}
Restart=always
StandardOutput=append:/var/log/rustdesk/relayserver.log
StandardError=append:/var/log/rustdesk/relayserver.error
# Restart service after 10 seconds if service crashes
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
)"
echo "${hbbr_service}" | sudo tee /etc/systemd/system/hbbr.service > /dev/null
sudo systemctl daemon-reload
sudo systemctl enable hbbr.service
sudo systemctl start hbbr.service

while ! [[ $RUSTDESK_READY ]]; do
  RUSTDESK_READY=$(sudo systemctl status hbbr.service | grep "Active: active (running)")
  echo -ne "Rustdesk Relay not ready yet...\n"
  sleep 3
done

pub_key=$(find /opt/rustdesk -name "*.pub")
public_key=$(cat "${pub_key}")

rm rustdesk-server-linux-amd64.zip

echo -e "Your IP/DNS Address is ${wanip}"
echo -e "Your public key is ${public_key}"
echo -e "Install Rustdesk on your machines and change your public key and IP/DNS name to the above"

echo "Press any key to finish the installation"
while [ true ] ; do
    read -t 3 -n 1
    if [ $? = 0 ] ; then
        exit ;
    else
        echo "Waiting for keypress"
    fi
done

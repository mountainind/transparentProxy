#!/bin/bash
# License: BSD
# A script to take Ubuntu 16.04 stock -> fully transparent Tor for all traffic
# Run this script as ROOT (sudo is fine)!

# Cleanup function
function cleanup (){
  echo "Note that dependencies of tor will not be removed..."
  echo "Stopping tor..."
  systemctl stop tor
  systemctl disable tor
  systemctl disable go-transparent
  rm /lib/systemd/system/go-transparent.service
  rm /lib/systemd/system/tor.service
  rm /usr/local/bin/torTables.sh
  VERSION=`tor --version |awk '{print $3}'`
  cd /opt/tor-${VERSION}
  make uninstall
  echo "Returning normal network connectity (in iptables)"
  iptables-restore </etc/iptables/rules.v4
  userdel debian-tor
  rm -rf /opt/tor${VERSION}
  echo "Editing Kernel Params..."
  sed -i 's/net.ipv4.ip_forward=0//' /etc/sysctl.conf
  sysctl -p

  echo "Enabling dnsmasq..."
  sed -i 's/\#dns=/dns=/' /etc/NetworkManager/NetworkManager.conf

  echo "Removing DNS override..."
  echo "You'll want to change your NetworkManager profile to NOT be address only"
  sed -i 's/nameserver 127\.0\.0\.1//' /etc/resolvconf/resolv.conf.d/head
  echo "Then you'll need to restart NetworkManager - or just reboot"
  echo "Done..."
}
EffectiveUser=`whoami`
echo "Verifying User..."
if [[ $EffectiveUser != root ]]; then
  echo "ERROR! This script must be run as root."
  echo "Please re-run with sudo..."
  exit
fi
if [[ $1 == "-?" ]]; then
  echo "This script is used to modify your networking stack to route all traffic"
  echo "over Tor. If you have already run this script, and would like to remove"
  echo "all traces of it, simply pass -r"
elif [[ $1 == "-r" ]]; then
  echo "Would you like to remove all traces of transparentProxy from your system?"
  echo -n "[Y/N]: "
  read prompt
  if [[ $prompt == "Y" || $prompt == "y" ]]; then
    echo "Clearing out transparentProxy..."
    cleanup
    exit
  fi
fi
# Verify the Disk is encrypted
echo "Verifying Encryption availability..."
EncryptedStatus=`dmsetup status`
if [[ $EncryptedStatus == "No devices found" || $EncryptedStatus == "" ]]; then
  echo "ERROR! You haven't encrypted your disk during the install..."
  echo "It is HIGHLY recommended that you start over and select encryption"
  echo "during the install process."
  echo "Exiting..."
  exit
fi

# Verify OS
OSVer=`lsb_release -c|awk '{ print $2 }'`
if [[ $OSVer == "xenial" ]]; then
  echo "Ubuntu 16.04 Detected..."
else
  echo "ERROR: You are running this on an untested OS!"
  exit
fi

echo "All pre-checks passed!"
echo "-------------------------------------------------------------------"
echo "                             !WARNING!                             "
echo "-------------------------------------------------------------------"
echo "This sript will drastically alter your OS. It will re-route all"
echo "traffic out Tor. If you don't know what this means, don't do it."
echo
echo "This script will do the following:"
echo "- Install chromium (chrome without flash)"
echo "- Install IPTables (ufw has some limitations)"
echo "- Install necessary development / build requirements"
echo "- Build + Install the latest tor daemon"
echo "- Install systemd scripts for tor + iptables rules"
while true; do
  read -p "Are you sure you want to continue? (Y/N) " yn
  case $yn in
    [Yy]* ) echo "We begin..."; break;;
    [Nn]* ) exit;;
    * ) echo "Please enter yes or no.";;
  esac
done

echo "Beginning package install..."
apt-get -y install vim chromium-browser libevent-dev libssl-dev iptables-persistent wget gcc make

echo "Creating tor user..."
useradd -d /var/lib/tor -u 122 debian-tor

echo "Finding Latest Tor..."
cd /opt
wget -q -O tmp.html https://dist.torproject.org/
RELEASE_VER=`cat tmp.html |grep -o -E "tor[^<>]*?[0-9]+.tar.gz"|sort -t . -n -k 2,2n -k 3,3n -k 4,4n|tail -1`
if [[ $RELEASE_VER == "" ]]; then
  echo "ERROR! Couldn't download Tor! Exiting..."
  exit
fi
echo "Version $RELEASE_VER Found! Downloading..."
RELEASE_URL="https://dist.torproject.org/${RELEASE_VER}"
VER=`echo $RELEASE_VER|sed 's/\.tar\.gz//'`
wget $RELEASE_URL

# GPG Verify
echo "Pulling Tor signers key"
gpg --keyserver pgp.mit.edu --recv-keys 0xFE43009C4607B1FB
wget ${RELEASE_URL}.asc
gpg --verify ${RELEASE_VER}.asc
if [[ $? -ne 0 ]]; then
  echo "GPG Verification failure..."
  echo "This probably is a false positive, but it is safer to exit."
  read -p "Continue anyway? (Y/N) " yn
  case $yn in
    [Yy]* ) echo "OK, continuing.";;
    [Nn]* ) exit;;
    * ) exit;;
  esac
fi

echo "Expanding..."
tar zxvf ./${RELEASE_VER}
echo "Configuring Tor..."
cd ./${VER}
./configure --with-tor-user=debian-tor
if [[ $? -ne 0 ]]; then
  echo "Configure error...Dropping out."
  exit
fi
echo "Compiling..."
make
if [[ $? -ne 0 ]]; then
  echo "Make error...Dropping out."
  exit
fi
echo "Installing..."
make install
if [[ $? -ne 0 ]]; then
  echo "Install error...Dropping out."
  exit
fi

echo "Tor setup stuff..."
mkdir /var/lib/tor
chown debian-tor /var/lib/tor

echo "Editing Kernel Params..."
echo "net.ipv4.ip_forward=0" >> /etc/sysctl.conf
sysctl -p

echo "Disabling dnsmasq..."
sed -i 's/dns=/\#dns=/' /etc/NetworkManager/NetworkManager.conf

echo "Re-pointing DNS to localhost..."
echo "NOTE!!!! Do Address Only when adding new connections to Network Manager"
echo "nameserver 127.0.0.1" >> /etc/resolvconf/resolv.conf.d/head

echo "Selecting Random LAN Subnet..."
NUM=`shuf -i 1-254 -n 1`
SUBNET="10.${NUM}.0.0/16"
echo "SUBNET for TOR = $SUBNET"

echo "Getting interface name..."
INTERFACE=`route -n |awk '/UG/ { print $8 }'`
if [[ $INTERFACE == "" ]]; then
  echo "Error getting internet interface..."
  exit
fi

echo "Creating torrc..."
cat << EOF > /usr/local/etc/tor/torrc
VirtualAddrNetworkIPv4 $SUBNET
AutomapHostsOnResolve 1
TransPort 9040
DNSPort 5353
EOF

echo "Creating torTables.sh"
cat << EOF >/usr/local/bin/torTables.sh
#!/bin/sh
### set variables
#your outgoing interface
_out_if="${INTERFACE}"

#the UID that Tor runs as (varies from system to system)
_tor_uid="122"

#Tor's TransPort
_trans_port="9040"

#Tor's DNSPort
_dns_port="5353"

#Tor's VirtualAddrNetworkIPv4
_virt_addr="${SUBNET}"
EOF

cat << 'EOF2' >>/usr/local/bin/torTables.sh
#LAN destinations that shouldn't be routed through Tor
#Check reserved block.
_non_tor="127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"

#Other IANA reserved blocks (These are not processed by tor and dropped by default)
_resv_iana="0.0.0.0/8 100.64.0.0/10 169.254.0.0/16 192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/3"

### Don't lock yourself out after the flush
#iptables -P INPUT ACCEPT
#iptables -P OUTPUT ACCEPT

### flush iptables
iptables -F
iptables -t nat -F
# LEAK FIX from: https://lists.torproject.org/pipermail/tor-talk/2014-March/032507.html
#iptables -A OUTPUT -m conntrack --ctstate INVALID -j LOG --log-prefix "Transproxy ctstate leak blocked: " --log-uid
#########
iptables -A OUTPUT -m conntrack --ctstate INVALID -j DROP
iptables -A OUTPUT -m state --state INVALID -j LOG --log-prefix "Transproxy state leak blocked: " --log-uid
iptables -A OUTPUT -m state --state INVALID -j DROP

iptables -A OUTPUT ! -o lo ! -d 127.0.0.1 ! -s 127.0.0.1 -p tcp -m tcp --tcp-flags ACK,FIN ACK,FIN -j LOG --log-prefix "Transproxy leak blocked: " --log-uid
iptables -A OUTPUT ! -o lo ! -d 127.0.0.1 ! -s 127.0.0.1 -p tcp -m tcp --tcp-flags ACK,RST ACK,RST -j LOG --log-prefix "Transproxy leak blocked: " --log-uid
iptables -A OUTPUT ! -o lo ! -d 127.0.0.1 ! -s 127.0.0.1 -p tcp -m tcp --tcp-flags ACK,FIN ACK,FIN -j DROP
iptables -A OUTPUT ! -o lo ! -d 127.0.0.1 ! -s 127.0.0.1 -p tcp -m tcp --tcp-flags ACK,RST ACK,RST -j DROP

### set iptables *nat

#nat .onion addresses
iptables -t nat -A OUTPUT -d $_virt_addr -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -j REDIRECT --to-ports $_trans_port

#nat dns requests to Tor
iptables -t nat -A OUTPUT -d 127.0.0.1/32 -p udp -m udp --dport 53 -j REDIRECT --to-ports $_dns_port

#don't nat the Tor process, the loopback, or the local network
iptables -t nat -A OUTPUT -m owner --uid-owner $_tor_uid -j RETURN
iptables -t nat -A OUTPUT -o lo -j RETURN

for _lan in $_non_tor; do
 iptables -t nat -A OUTPUT -d $_lan -j RETURN
done

for _iana in $_resv_iana; do
 iptables -t nat -A OUTPUT -d $_iana -j RETURN
done

#redirect whatever fell thru to Tor's TransPort
iptables -t nat -A OUTPUT -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -j REDIRECT --to-ports $_trans_port


### set iptables *filter
#*filter INPUT
iptables -A INPUT -m state --state ESTABLISHED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT

#Don't forget to grant yourself ssh access for remote machines before the DROP.
#iptables -A INPUT -i $_out_if -p tcp --dport 22 -m state --state NEW -j ACCEPT

iptables -A INPUT -j DROP

#*filter FORWARD
iptables -A FORWARD -j DROP

#*filter OUTPUT
#possible leak fix. See warning.
iptables -A OUTPUT -m state --state INVALID -j DROP

iptables -A OUTPUT -m state --state ESTABLISHED -j ACCEPT

#allow Tor process output
iptables -A OUTPUT -o $_out_if -m owner --uid-owner $_tor_uid -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -m state --state NEW -j ACCEPT

#allow loopback output
iptables -A OUTPUT -d 127.0.0.1/32 -o lo -j ACCEPT

#tor transproxy magic
iptables -A OUTPUT -d 127.0.0.1/32 -p tcp -m tcp --dport $_trans_port --tcp-flags FIN,SYN,RST,ACK SYN -j ACCEPT

#allow access to lan hosts in $_non_tor
#these 3 lines can be ommited
for _lan in $_non_tor; do
 iptables -A OUTPUT -d $_lan -j ACCEPT
done

#Log & Drop everything else.
iptables -A OUTPUT -j LOG --log-prefix "Dropped OUTPUT packet: " --log-level 7 --log-uid
iptables -A OUTPUT -j DROP

#Set default policies to DROP
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

EOF2
chmod 700 /usr/local/bin/torTables.sh

echo "Creating tor startup script / enabling"
cat << EOF > /lib/systemd/system/tor.service
# /etc/systemd/system/tor.service
[Unit]
Wants=network-online.target
After=network-online.target
Description=Tor Daemon

[Service]
User=debian-tor
ExecStart=/usr/local/bin/tor

[Install]
WantedBy=multi-user.target
EOF
systemctl enable tor

echo "Creating iptables routing script startup"
cat << EOF > /lib/systemd/system/go-transparent.service
#/etc/systemd/system/go-transparent.service
[Unit]
Wants=tor.service
After=tor.service
Description=Tor Transparent Routing

[Service]
ExecStart=/usr/local/bin/torTables.sh

[Install]
WantedBy=multi-user.target
EOF
systemctl enable go-transparent

echo "DONE!"
echo
echo "BEFORE REBOOTING... Change your wireless / wired profile"
echo "from DHCP to DHCP Address Only in Network Manager"
echo "ALSO! DISABLE IPv6 for your wireless / wired profile by selecting 'Ignore'"
echo
echo "This script has not done this so that you understand that new profiles"
echo "will require these changes"
echo
echo "Time to reboot and see if everything gets started ok!"

#### Add Tor Browser bundle download
#### Add HTTPS Everwhere plugins

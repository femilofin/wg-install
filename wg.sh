#!/bin/bash
# wg-install v0.1.01


function generate_port {
	local random_int
	random_int="$(shuf -i 2000-65535 -n 1)"
	ss -lau | grep "$random_int" > /dev/null
	if [[ "$?" == 1 ]]; then
		echo "$random_int"
	else
		generate_port
	fi
}

if [[ "$EUID" != 0 ]]; then
	echo "[-] Sorry, you need to run this as root"
	exit 13
fi

if [[ ! -e /dev/net/tun ]]; then
	echo "[-] The TUN device is not available. You need to enable TUN before running this script"
	exit 2
fi

if [ -e /etc/centos-release ]; then
	DISTRO="CentOS"
	echo "[i] OS: $DISTRO"
elif [ -e /etc/debian_version ]; then
	DISTRO="$(lsb_release -is)"
	echo "[i] OS: $DISTRO"
else
	echo -e "[-] Your distribution is not supported (yet)\n[i] Please open an issue or pull request to address you problem."
	exit 95
fi

if [ "$WG_CONFIG" == "" ]; then
	WG_CONFIG="/etc/wireguard/wg0.conf"
fi


if [ ! -f "$WG_CONFIG" ]; then
	WG_CONFIG_NAME=${WG_CONFIG:15:-5}
	# Install server and add default client
	INTERACTIVE=${INTERACTIVE:-yes}
	PRIVATE_SUBNET=${PRIVATE_SUBNET:-"10.9.0.0/24"}
	PRIVATE_SUBNET_MASK=${PRIVATE_SUBNET##*/}
	GATEWAY_ADDRESS="${PRIVATE_SUBNET::-4}1"

	if [ "$SERVER_HOST" == "" ]; then
		SERVER_HOST="$(curl -fsSL ifconfig.me 2>/dev/null || hostname -i)"
		if [ "$INTERACTIVE" == "yes" ]; then
			read -rp "[i] Servers public IP address is $SERVER_HOST  Is that correct? [y/n]: " -e -i "y" CONFIRM
			if [ "$CONFIRM" == "n" ]; then
				echo "[-] Aborted. Use environment variable SERVER_HOST to set the correct public IP address"
				exit 125
			fi
		fi
	fi

	if [ "$SERVER_PORT" == "" ]; then
		SERVER_PORT="$(generate_port)"
	fi

	if [ "$CLIENT_DNS" == "" ]; then
		echo "Which DNS do you want to use with the VPN?"
		echo "   1) Cloudflare (fastest DNS)"
		echo "   2) Google"
		echo "   3) OpenDNS (has phishing protection and other security filters)"
		echo "   4) Quad9 (Malware protection)"
		echo "   5) AdGuard DNS (automatically blocks ads)"
		read -rp "[?] DNS (1-5)[1]: " -e -i 1 DNS_CHOICE

		case $DNS_CHOICE in
		1)
			CLIENT_DNS="1.1.1.1,1.0.0.1"
			;;
		2)
			CLIENT_DNS="8.8.8.8,8.8.4.4"
			;;
		3)
			CLIENT_DNS="208.67.222.222,208.67.220.220"
			;;
		4)
			CLIENT_DNS="9.9.9.9"
			;;
		5)
			CLIENT_DNS="176.103.130.130,176.103.130.131"
			;;
		esac
	fi

	if [ "$DISTRO" == "Ubuntu" ]; then
		# Prevent iptables-persistent from prompting during installation
		echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
		echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections

		apt update
		apt install -y linux-headers-"$(uname -r)" wireguard qrencode iptables-persistent
	elif [ "$DISTRO" == "Debian" ]; then
		# Prevent iptables-persistent from prompting during installation
		echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
		echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections

		echo "deb http://deb.debian.org/debian buster-backports main" >> /etc/apt/sources.list
		apt update
		apt install -y linux-headers-"$(uname -r)" wireguard qrencode iptables-persistent
	elif [ "$DISTRO" == "CentOS" ]; then
		curl -sLo /etc/yum.repos.d/wireguard.repo https://copr.fedorainfracloud.org/coprs/jdoss/wireguard/repo/epel-7/jdoss-wireguard-epel-7.repo
		yum install epel-release -y
		yum install kernel-headers wireguard-dkms qrencode wireguard-tools -y
	fi

	SERVER_PRIVKEY="$(wg genkey)"
	SERVER_PUBKEY="$(echo "$SERVER_PRIVKEY" | wg pubkey)"
	CLIENT_PRIVKEY="$(wg genkey)"
	CLIENT_PUBKEY="$(echo "$CLIENT_PRIVKEY" | wg pubkey)"
	CLIENT_ADDRESS="${PRIVATE_SUBNET::-4}3"

	mkdir -p /etc/wireguard
	touch $WG_CONFIG && chmod 600 $WG_CONFIG

	{
		echo "# $PRIVATE_SUBNET $SERVER_HOST:$SERVER_PORT $SERVER_PUBKEY $CLIENT_DNS
[Interface]
Address = $GATEWAY_ADDRESS/$PRIVATE_SUBNET_MASK
ListenPort = $SERVER_PORT
PrivateKey = $SERVER_PRIVKEY
SaveConfig = false";

	echo "# client
[Peer]
PublicKey = $CLIENT_PUBKEY
AllowedIPs = $CLIENT_ADDRESS/32";
	} >> $WG_CONFIG

	echo "[Interface]
PrivateKey = $CLIENT_PRIVKEY
Address = $CLIENT_ADDRESS/$PRIVATE_SUBNET_MASK
DNS = $CLIENT_DNS
[Peer]
PublicKey = $SERVER_PUBKEY
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $SERVER_HOST:$SERVER_PORT
PersistentKeepalive = 25" > "$HOME/client-$WG_CONFIG_NAME.conf"
	qrencode -t ansiutf8 -l L < "$HOME/client-$WG_CONFIG_NAME.conf"

	{
		echo "net.ipv4.ip_forward=1";
		echo "net.ipv4.conf.all.forwarding=1";
		echo "net.ipv6.conf.all.forwarding=1";
	}  >> /etc/sysctl.conf
	sysctl -p

	if [ "$DISTRO" == "CentOS" ]; then
		firewall-cmd --zone=public --add-port="$SERVER_PORT/udp"
		firewall-cmd --zone=trusted --add-source="$PRIVATE_SUBNET"
		firewall-cmd --permanent --zone=public --add-port="$SERVER_PORT/udp"
		firewall-cmd --permanent --zone=trusted --add-source="$PRIVATE_SUBNET"
		firewall-cmd --direct --add-rule ipv4 nat POSTROUTING 0 -s "$PRIVATE_SUBNET" ! -d "$PRIVATE_SUBNET" -j SNAT --to "$SERVER_HOST"
		firewall-cmd --permanent --direct --add-rule ipv4 nat POSTROUTING 0 -s "$PRIVATE_SUBNET" ! -d "$PRIVATE_SUBNET" -j SNAT --to "$SERVER_HOST"
	else
		iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
		iptables -A FORWARD -m conntrack --ctstate NEW -s "$PRIVATE_SUBNET" -m policy --pol none --dir in -j ACCEPT
		iptables -t nat -A POSTROUTING -s "$PRIVATE_SUBNET" -m policy --pol none --dir out -j MASQUERADE
		iptables -A INPUT -p udp --dport "$SERVER_PORT" -j ACCEPT
		iptables-save > /etc/iptables/rules.v4
	fi

	systemctl enable wg-quick@$WG_CONFIG_NAME.service
	systemctl start wg-quick@$WG_CONFIG_NAME.service

	# TODO: unattended updates, apt install dnsmasq ntp
	echo "[+] Client config --> $HOME/client-$WG_CONFIG_NAME.conf"
	echo "[+] Now reboot the server and enjoy your fresh VPN installation! :^)"
else
	# Server is installed, handle command line arguments
	if [ $# -eq 0 ]; then
		echo "Usage:"
		echo "  $0 1     - Remove WireGuard"
		echo "  $0 2 [client_name]  - Add new client (client_name optional)"
		exit 1
	fi

	ADD_REMOVE="$1"
	if [[ ! "$ADD_REMOVE" =~ ^[12]$ ]]; then
		echo "[-] First argument must be either 1 (remove) or 2 (add client)"
		exit 1
	fi

	if [ "$ADD_REMOVE" == "1" ]; then
		echo "[*] Removing WireGuard from the server..."
		rm -rf "$WG_CONFIG";
		if [ "$DISTRO" == "Ubuntu" ]; then
			apt remove wireguard* -y && apt autoremove -y && apt autoclean -y
		elif [ "$DISTRO" == "Debian" ]; then
			apt remove wireguard* -y && apt autoremove -y && apt autoclean -y
		elif [ "$DISTRO" == "CentOS" ]; then
			yum remove wireguard-dkms -y
		fi

		echo "[i] WireGuard removed from the server!"
		exit 0
	fi

	# Handle add client case
	CLIENT_NAME="$2"
	if [ "$CLIENT_NAME" == "" ]; then
		echo "[?] Tell me a name for the client config file [no special characters]."
		read -rp "[+] Client name: " -e CLIENT_NAME
	fi

	# Validate client name
	if [[ ! "$CLIENT_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
		echo "[-] Client name can only contain alphanumeric characters, underscores and hyphens"
		exit 1
	fi

	WG_CONFIG_NAME="$(basename "$WG_CONFIG" .conf)"

	CLIENT_PRIVKEY="$(wg genkey)"
	CLIENT_PUBKEY="$(echo "$CLIENT_PRIVKEY" | wg pubkey)"
	PRIVATE_SUBNET="$(head -n1 "$WG_CONFIG" | awk '{print $2}')"
	PRIVATE_SUBNET_MASK="$(echo "$PRIVATE_SUBNET" | cut -d "/" -f 2)"
	SERVER_ENDPOINT="$(head -n1 "$WG_CONFIG" | awk '{print $3}')"
	SERVER_PUBKEY="$(head -n1 "$WG_CONFIG" | awk '{print $4}')"
	CLIENT_DNS="$(head -n1 "$WG_CONFIG" | awk '{print $5}')"
	LASTIP="$(grep "/32" "$WG_CONFIG" | tail -n1 | awk '{print $3}' | cut -d "/" -f 1 | cut -d "." -f 4)"
	CLIENT_ADDRESS="${PRIVATE_SUBNET::-4}$((LASTIP + 1))"
	echo "# $CLIENT_NAME
[Peer]
PublicKey = $CLIENT_PUBKEY
AllowedIPs = $CLIENT_ADDRESS/32" >> $WG_CONFIG

	echo "[Interface]
PrivateKey = $CLIENT_PRIVKEY
Address = $CLIENT_ADDRESS/$PRIVATE_SUBNET_MASK
DNS = $CLIENT_DNS
[Peer]
PublicKey = $SERVER_PUBKEY
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $SERVER_ENDPOINT
PersistentKeepalive = 25" > "$HOME/$CLIENT_NAME-$WG_CONFIG_NAME.conf"
	qrencode -t ansiutf8 -l L < "$HOME/$CLIENT_NAME-$WG_CONFIG_NAME.conf"

	ip address | grep -q $WG_CONFIG_NAME && wg set $WG_CONFIG_NAME peer "$CLIENT_PUBKEY" allowed-ips "$CLIENT_ADDRESS/32"
	echo "[+] Client added, new configuration file --> $HOME/$CLIENT_NAME-$WG_CONFIG_NAME.conf"
fi
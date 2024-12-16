#!/bin/bash

VERSION="0.2.0"
ALLOPTIONS=$@

while [ "$1" != "" ];
do
   case $1 in
    -v | --version )
        echo "Wireguard Config Files for NordVPN v$VERSION"
	      exit
        ;;
    -h | --help )
         echo "Usage: NordVpnToWireguard [command options] [<country>|<server>|<country_code>|<city>|<group>|<country> <city>]"
         echo "Command Options includes:"
         echo "   <country>       argument to create a Wireguard config for a specific country. For example: 'NordVpnToWireguard Australia'"
	       echo "   <server>        argument to create a Wireguard config for a specific server. For example: 'NordVpnToWireguard jp35'"
	       echo "   <country_code>  argument to create a Wireguard config for a specific country. For example: 'NordVpnToWireguard us'"
	       echo "   <city>          argument to create a Wireguard config for a specific city. For example: 'NordVpnToWireguard Hungary Budapest'"
	       echo "   <group>         argument to create a Wireguard config for a specific servers group. For example: 'NordVpnToWireguard connect Onion_Over_VPN'"
         echo "   -h | --help     - displays this message."
         exit
      ;;
  esac
  shift
done

# Connect to NordVPN
echo "Connect to NordVPN to gather connection parameters...."
nordvpn connect $ALLOPTIONS  > /dev/null 2>&1 || {
    echo "Unable to connect to NordVPN."
    exit 1
}

# Use ip or ifconfig to get
if [ $(command -v ip &> /dev/null) ]; then
        IP_ADDR_COMMAND="ip addr show"
else
        IP_ADDR_COMMAND="ifconfig"
fi

# Preparing the I

# Gather all info
MYIP=$($IP_ADDR_COMMAND nordlynx | grep inet | awk '{print $2}')/32
PRIVATE=$(sudo wg show nordlynx private-key)
PUBKEY=$(sudo wg show nordlynx | grep peer | awk '{print $2}')
ENDPOINT=$(nordvpn status | grep 'Hostname' | awk '{print $2}')
OUTPUFILENAME="NordVPN-`echo $ENDPOINT | grep -o '^[^.]*'`.conf"

interfacePublicKey=`sudo wg show nordlynx public-key` # Custom
gateway=$(ifconfig nordlynx | grep -oP 'inet\s+\K(\d+\.){3}\d+' | awk 'NR==1{print $1}')

# Gathering info for the Peer section
curl -s "https://api.nordvpn.com/v1/servers/recommendations?&filters\[servers_technologies\]\[identifier\]=wireguard_udp&limit=1"|jq -r '.[]|.hostname, .station, (.locations|.[]|.country|.city.name), (.locations|.[]|.country|.name), (.technologies|.[].metadata|.[].value), .load' >> Peer.txt

# Preparing the Peer section 
endpoint=`grep -m 1 -o '.*' Peer.txt | tail -n 1`
station=`grep -m 2 -o '.*' Peer.txt | tail -n 1`
city=`grep -m 3 -o '.*' Peer.txt | tail -n 1`
country=`grep -m 4 -o '.*' Peer.txt | tail -n 1`
publicKey=`grep -m 5 -o '.*' Peer.txt | tail -n 1`

rm Peer.txt

# Disconnect from NordVPN
nordvpn d > /dev/null 2>&1 || {
    echo "Unable to disconnect from NordVPN."
    exit 1
}

# Creating Wireguard Configuration file
cat <<EOF > $OUTPUFILENAME
[Interface]
Address = ${MYIP}
PublicKey = ${interfacePublicKey}
PrivateKey = ${PRIVATE}
Gateway = ${gateway}
ListenPort = 51820
DNS = 103.86.96.100, 103.86.99.100

[Peer]
PublicKey = ${PUBKEY}
AllowedIPs = 0.0.0.0/0, ::0/0
Endpoint = ${ENDPOINT}:51820
EndpointIp = ${station}
Country = ${country}
City = ${city}
PersistentKeepalive = 25
EOF

echo "Wireguard configuration file $OUTPUFILENAME created successfully!"
exit 0
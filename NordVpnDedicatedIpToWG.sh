#!/bin/bash

# NordVpnDedicatedIpToWG.sh
# -------------------------
# Generates a WireGuard configuration file for a NordVPN DEDICATED IP server.
#
# WHY THIS IS A SEPARATE SCRIPT (vs NordVpnToWireguard-v2.sh):
#   The regular script gets the [Peer] details from the NordVPN
#   "recommendations" API:
#       /v1/servers/recommendations?...wireguard_udp
#   That endpoint ONLY returns shared/public servers and ranks them by load.
#   It NEVER returns the dedicated-IP server assigned to your account, so for a
#   dedicated IP it would write the wrong server's IP and public key into the
#   config and the WireGuard handshake would fail.
#
#   For a dedicated IP we therefore skip the API entirely and read everything
#   from the live tunnel after connecting:
#     - [Peer] PublicKey  -> the connected (i.e. your dedicated) server's public
#                            key, read directly with `wg show nordlynx peers`.
#     - [Peer] Endpoint   -> the IP/port that WireGuard actually negotiated, read
#                            from `wg show nordlynx endpoints`. NOTE: NordLynx uses
#                            a double-NAT layer, so the WireGuard endpoint IP can
#                            differ from the public "exit" IP shown by
#                            `nordvpn status` (which is your dedicated IP). The
#                            value that makes the handshake work is the negotiated
#                            endpoint, so that is what goes in Endpoint. The
#                            dedicated exit IP is recorded separately for reference.
#     - Country / City    -> parsed from `nordvpn status` instead of the API.
#
# OUTPUT FORMAT:
#   This file matches the format used by NordVpnToWireguard-v2.sh, which is built
#   for this repo's OPNsense WireGuard GUI import workflow. It deliberately carries
#   extra, non-standard keys (PublicKey/Gateway in [Interface]; EndpointIp/Country/
#   City in [Peer]) that the OPNsense importer/operator uses. It is therefore NOT a
#   plain `wg-quick` config: `wg-quick up <file>` would reject those keys. Strip the
#   non-standard keys first if you need a standalone wg-quick file.
#
# PREREQUISITES:
#   - A dedicated IP must be activated/assigned in your Nord Account.
#   - You must know either the dedicated server group or its exact hostname.

VERSION="0.1.0"
ALLOPTIONS=$@

while [ "$1" != "" ];
do
   case $1 in
    -v | --version )
        echo "Wireguard Config Files for NordVPN Dedicated IP v$VERSION"
        exit
        ;;
    -h | --help )
         echo "Usage: NordVpnDedicatedIpToWG [<dedicated_server_hostname>]"
         echo ""
         echo "Creates a Wireguard config for your NordVPN dedicated IP server."
         echo ""
         echo "Arguments:"
         echo "   <dedicated_server_hostname>  Optional. The specific dedicated server to"
         echo "                                connect to, e.g. 'NordVpnDedicatedIpToWG us4955'."
         echo "                                If omitted, connects with '--group dedicated_ip'."
         echo "   -h | --help                  Displays this message."
         echo ""
         echo "Note: the recommendations API is NOT used here because it does not"
         echo "      return dedicated-IP servers. All peer data is read from the live"
         echo "      'nordvpn'/'wg' connection instead."
         exit
      ;;
  esac
  shift
done

# Connect to NordVPN dedicated IP.
# If a specific server/argument was given, use it; otherwise target the
# Dedicated_IP group so NordVPN routes you to your assigned dedicated server.
if [ -n "$ALLOPTIONS" ]; then
    echo "Connecting to NordVPN dedicated server '$ALLOPTIONS' to gather connection parameters...."
    CONNECT_TARGET="$ALLOPTIONS"
else
    echo "Connecting to NordVPN dedicated IP group to gather connection parameters...."
    # Note: the CLI group token is the lowercase 'dedicated_ip' (the capitalized
    # 'Dedicated_IP' is only the human-readable label and is not accepted as a token).
    # Connecting by the specific assigned hostname (passed as an argument) is more
    # reliable, since --group routes you to *a* dedicated server in your region.
    CONNECT_TARGET="--group dedicated_ip"
fi

nordvpn connect $CONNECT_TARGET > /dev/null 2>&1 || {
    echo "Unable to connect to NordVPN dedicated IP."
    echo "Make sure a dedicated IP is assigned to your account and the server/group name is correct."
    exit 1
}

# Give the tunnel a moment to complete the handshake before we read it.
sleep 2

# Use ip or ifconfig to get interface information
if command -v ip &> /dev/null; then
        USE_IP=true
else
        if command -v ifconfig &> /dev/null; then
                USE_IP=false
        else
                echo "Error: Neither 'ip' nor 'ifconfig' command is available. Please install iproute2 or net-tools package."
                nordvpn d > /dev/null 2>&1
                exit 1
        fi
fi

# --- Client / [Interface] details (read locally) ---

# Client tunnel address (NordLynx assigns a fixed 10.5.0.2/32 per device).
if [ "$USE_IP" = true ]; then
        MYIP=$(ip addr show nordlynx | grep 'inet ' | awk '{print $2}')
else
        MYIP=$(ifconfig nordlynx | grep -oP 'inet\s+\K(\d+\.){3}\d+' | awk 'NR==1{print $1}')/32
fi

PRIVATE=$(sudo wg show nordlynx private-key)
interfacePublicKey=$(sudo wg show nordlynx public-key)   # the CLIENT public key

# Gateway: per the OPNsense notes, the gateway is the .1 of the tunnel subnet
# (e.g. tunnel 10.5.0.2 -> gateway 10.5.0.1), NOT the client address itself.
TUNNEL_IP=$(echo "$MYIP" | cut -d'/' -f1)
gateway=$(echo "$TUNNEL_IP" | awk -F'.' '{print $1"."$2"."$3".1"}')

# --- Server / [Peer] details (read locally from the live tunnel) ---

# The peer of the nordlynx interface is the connected server. For a dedicated-IP
# connection that connected server IS your dedicated server, so its public key is
# exactly what we need. `wg show nordlynx peers` prints the bare key (script-safe).
PUBKEY=$(sudo wg show nordlynx peers)

# The WireGuard endpoint that was actually negotiated (IP:port). This is the value
# that makes the handshake work and is what belongs in Endpoint. Under NordLynx's
# double-NAT this can differ from the public "exit" IP reported by `nordvpn status`.
ENDPOINT_IP_PORT=$(sudo wg show nordlynx endpoints | awk '{print $2}')
WG_ENDPOINT_IP=$(echo "$ENDPOINT_IP_PORT" | cut -d':' -f1)

# Hostname, public-facing exit IP (your dedicated IP), country and city from status.
# Labels are anchored and parsed with ': ' to tolerate multi-word values (e.g.
# "United States", "New York") and avoid matching unrelated lines (e.g. IPv6).
ENDPOINT=$(nordvpn status | grep -m1 'Hostname' | awk -F': ' '{print $2}')
DEDICATED_EXIT_IP=$(nordvpn status | grep -m1 '^IP:' | awk -F': ' '{print $2}')
country=$(nordvpn status | grep -m1 'Country' | awk -F': ' '{print $2}')
city=$(nordvpn status | grep -m1 'City' | awk -F': ' '{print $2}')

# Fall back to the WireGuard endpoint IP if `nordvpn status` did not expose an IP.
if [ -z "$DEDICATED_EXIT_IP" ]; then
    DEDICATED_EXIT_IP="$WG_ENDPOINT_IP"
fi

# Disconnect from NordVPN
nordvpn d > /dev/null 2>&1 || {
    echo "Unable to disconnect from NordVPN."
    exit 1
}

# Sanity check: we must have a peer public key and a negotiated endpoint,
# otherwise the handshake never completed and the config would be useless.
if [ -z "$PUBKEY" ] || [ -z "$WG_ENDPOINT_IP" ]; then
    echo "Error: could not read the dedicated server's public key/endpoint from the tunnel."
    echo "The connection may not have established. Please try again."
    exit 1
fi

# Create Connections directory if it doesn't exist
mkdir -p Connections

# Generate date and prepare filename components
CURRENT_DATE=$(date +%Y%m%d)
ENDPOINT_SHORT=$(echo $ENDPOINT | grep -o '^[^.]*')

# Clean up country and city names for filename (remove spaces and special characters)
COUNTRY_CLEAN=$(echo "$country" | tr ' ' '_' | sed 's/[^a-zA-Z0-9_]//g')
CITY_CLEAN=$(echo "$city" | tr ' ' '_' | sed 's/[^a-zA-Z0-9_]//g')

# Create new filename with format: yyyymmdd-DedicatedIP-Country-City-Endpoint.conf
OUTPUTFILENAME="Connections/${CURRENT_DATE}-DedicatedIP-${COUNTRY_CLEAN}-${CITY_CLEAN}-${ENDPOINT_SHORT}.conf"

# Creating Wireguard Configuration file.
# Endpoint uses the WireGuard-negotiated server IP (not the hostname): a dedicated
# hostname does not reliably resolve to your reserved IP, and WireGuard resolves a
# hostname only once at load time anyway. The public dedicated exit IP is recorded
# as a comment so it can be cross-checked against your Nord Account assignment.
cat <<EOF > $OUTPUTFILENAME
# NordVPN Dedicated IP - generated by NordVpnDedicatedIpToWG.sh
# Dedicated exit IP (as seen externally): ${DEDICATED_EXIT_IP}
# Server hostname: ${ENDPOINT}
[Interface]
Address = ${MYIP}
PublicKey = ${interfacePublicKey}
PrivateKey = ${PRIVATE}
Gateway = ${gateway}
ListenPort = 51820
MTU = 1420
DNS = 103.86.96.100, 103.86.99.100

[Peer]
PublicKey = ${PUBKEY}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${WG_ENDPOINT_IP}:51820
EndpointIp = ${WG_ENDPOINT_IP}
Hostname = ${ENDPOINT}
Country = ${country}
City = ${city}
PersistentKeepalive = 25
EOF

echo "Wireguard configuration file $OUTPUTFILENAME created successfully!"
echo "WireGuard endpoint: ${WG_ENDPOINT_IP}:51820  (server ${ENDPOINT})"
echo "Dedicated exit IP:  ${DEDICATED_EXIT_IP}"
exit 0

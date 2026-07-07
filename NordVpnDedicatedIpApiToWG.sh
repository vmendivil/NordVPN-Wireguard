#!/bin/bash

# NordVpnDedicatedIpApiToWG.sh
# ----------------------------
# Generates a WireGuard configuration file for a NordVPN DEDICATED IP server
# using the NordVPN ACCOUNT REST API (no `nordvpn connect` required).
#
# WHY THIS EXISTS (vs the other two scripts in this repo):
#   * NordVpnToWireguard-v2.sh reads its [Peer] from the *unauthenticated*
#     /v1/servers/recommendations endpoint. That endpoint only returns
#     shared/public servers ranked by load and NEVER your dedicated server.
#   * NordVpnDedicatedIpToWG.sh (live-tunnel approach) runs
#     `nordvpn connect --group dedicated_ip` and reads keys from the live
#     `wg`/`nordvpn status` output. That works, but `--group` only routes you
#     to *a* dedicated server in your region, not provably the one assigned to
#     your account.
#   * THIS script talks to the *account-authenticated* API and reads the exact
#     dedicated server id that NordVPN has reserved for you, so the endpoint and
#     public key are guaranteed to match your dedicated IP. Source of the method:
#     https://forum.gl-inet.com/t/connecting-to-nordvpn-dedicated-ip-via-wireguard-on-gl-inet-mudi-gl-e5800-or-other/68697
#
# API FLOW:
#   1. GET /v1/users/services/credentials       -> nordlynx_private_key
#   2. GET /v1/users/services                    -> find service.identifier
#                                                   == "dedicated_ip", read the
#                                                   assigned server id(s) from
#                                                   details.servers[].id
#   3. GET /v1/servers?filters[servers.id]=<id>  -> hostname, station (exit IP),
#                                                   wireguard public_key, country,
#                                                   city
#
# AUTHENTICATION:
#   These account endpoints use HTTP Basic auth as `token:<ACCESS_TOKEN>`.
#   The access token is generated ONCE in your Nord Account dashboard
#   ("Set up NordVPN manually" -> access token). It is NOT the same thing as a
#   `nordvpn login` CLI session and cannot be read back from the CLI, so it must
#   be supplied to this script (see USAGE / token resolution below).
#
# OUTPUT FORMAT:
#   Matches NordVpnToWireguard-v2.sh (this repo's OPNsense WireGuard GUI import
#   workflow). It carries non-standard keys (PublicKey/Gateway in [Interface];
#   EndpointIp/Hostname/Country/City in [Peer]) that the OPNsense operator uses.
#   It is therefore NOT a plain `wg-quick` config; strip the extra keys if you
#   need a standalone wg-quick file.
#
# PREREQUISITES:  curl, jq, wireguard-tools (`wg`).  No sudo, no nordvpn CLI.

VERSION="0.1.0"

# ---------------------------------------------------------------------------
# Configurable defaults (edit these to taste; see the blog post for context).
# The API approach cannot read a live nordlynx interface, so the client tunnel
# address and gateway are fixed values rather than discovered ones.
#
# These defaults are chosen to coexist with the existing OPNsense WG_NordVpn
# instance on this router (tunnel 10.5.0.2/32, gateway 10.5.0.1, port 51820)
# and WG_RoadWarrior (tunnel 10.10.7.1/24, port 51823):
#   * INTERFACE_ADDRESS: .3 host inside 10.5.0.0/16 (NordLynx's expected client
#     range) with /32 so no overlapping subnet route is added alongside
#     WG_NordVpn's 10.5.0.2/32. Staying in 10.5.0.0/16 keeps the client source
#     IP inside whatever range NordVPN's peer accepts for this account key.
#   * GATEWAY: 10.5.0.4. The gateway value is only a routing-table label used
#     on the OPNsense side (WireGuard has no ARP/L2; the "Far Gateway" flag lets
#     the next-hop IP be off-subnet). OPNsense enforces uniqueness of the
#     gateway IP across all gateways, so Gateway_WG_NordVpn's 10.5.0.1 cannot
#     be reused — 10.5.0.4 is the next free host after .1 (gateway), .2 (WG_NordVpn
#     tunnel address) and .3 (this instance's tunnel address).
#   * LISTEN_PORT: 51821 (51820 = WG_NordVpn, 51823 = WG_RoadWarrior).
# ---------------------------------------------------------------------------
INTERFACE_ADDRESS="10.5.0.3/32"           # unique client IP in 10.5.0.0/16; /32 avoids subnet-route overlap.
GATEWAY="10.5.0.4"                        # OPNsense-side routing-table label only; must be unique across all gateways.
DNS="103.86.96.100, 103.86.99.100"        # NordVPN resolvers.
MTU="1420"                                # correct for NordLynx.
LISTEN_PORT="51821"                       # local OPNsense listen port; must be unique per instance
                                          # (WG_NordVpn already uses 51820, WG_RoadWarrior 51823).
                                          # NOTE: unrelated to Endpoint's :51820, which is NordVPN's remote port.
ENDPOINT_PORT="51820"
ALLOWED_IPS="0.0.0.0/0, ::/0"
PERSISTENT_KEEPALIVE="25"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
SERVER_FILTER=""      # optional: restrict output to a single server id
POSITIONAL=()

while [ "$1" != "" ]; do
   case $1 in
    -v | --version )
        echo "Wireguard Config Files for NordVPN Dedicated IP (API) v$VERSION"
        exit
        ;;
    -h | --help )
        echo "Usage: NordVpnDedicatedIpApiToWG [<access_token>] [<server_id>]"
        echo ""
        echo "Creates Wireguard config file(s) for the NordVPN dedicated IP server(s)"
        echo "assigned to your account, by querying the NordVPN account API."
        echo ""
        echo "Access token (required):"
        echo "   Resolved in this order:"
        echo "     1. NORDVPN_TOKEN environment variable   (export NORDVPN_TOKEN=...)"
        echo "     2. First command-line argument"
        echo "   Generate it in your Nord Account dashboard:"
        echo "     Services -> NordVPN -> 'Set up NordVPN manually' -> access token."
        echo ""
        echo "Arguments:"
        echo "   <access_token>  Optional if NORDVPN_TOKEN is exported."
        echo "   <server_id>     Optional. Restrict output to a single dedicated"
        echo "                   server id (useful if you have more than one)."
        echo "   -h | --help     Displays this message."
        exit
        ;;
    * )
        POSITIONAL+=("$1")
        ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Token resolution: NORDVPN_TOKEN env var, else first positional argument.
# ---------------------------------------------------------------------------
if [ -n "$NORDVPN_TOKEN" ]; then
    TOKEN="$NORDVPN_TOKEN"
    # If a token came from the env var, the (only) positional arg is the server id.
    SERVER_FILTER="${POSITIONAL[0]}"
else
    TOKEN="${POSITIONAL[0]}"
    SERVER_FILTER="${POSITIONAL[1]}"
fi

if [ -z "$TOKEN" ]; then
    echo "Error: no NordVPN access token provided." >&2
    echo "Set it once with:   export NORDVPN_TOKEN=<your-access-token>" >&2
    echo "or pass it as the first argument:   ./NordVpnDedicatedIpApiToWG.sh <token>" >&2
    echo "Generate the token in Nord Account -> Services -> NordVPN ->" >&2
    echo "'Set up NordVPN manually' -> access token." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
for dep in curl jq wg; do
    if ! command -v "$dep" &> /dev/null; then
        echo "Error: required command '$dep' not found." >&2
        echo "Install it (e.g. 'sudo apt install wireguard-tools curl jq')." >&2
        exit 1
    fi
done

API="https://api.nordvpn.com/v1"

# ---------------------------------------------------------------------------
# Step 1: client WireGuard private key (from your account credentials)
# ---------------------------------------------------------------------------
echo "Fetching account WireGuard credentials..."
CREDENTIALS=$(curl -s -u "token:${TOKEN}" "${API}/users/services/credentials")
PRIVATE=$(echo "$CREDENTIALS" | jq -r '.nordlynx_private_key // empty')

if [ -z "$PRIVATE" ]; then
    echo "Error: could not read your WireGuard private key from the API." >&2
    echo "This usually means the access token is wrong/expired. API said:" >&2
    echo "$CREDENTIALS" | jq -r '.errors.message? // .message? // .' 2>/dev/null | head -n 3 >&2
    exit 1
fi

# Derive the client public key from the private key (for the custom [Interface] key).
interfacePublicKey=$(echo "$PRIVATE" | wg pubkey)

# ---------------------------------------------------------------------------
# Step 2: find the dedicated-IP server id(s) assigned to your account
# ---------------------------------------------------------------------------
echo "Looking up dedicated IP server(s) assigned to your account..."
SERVICES=$(curl -s -u "token:${TOKEN}" "${API}/users/services")

SERVER_IDS=$(echo "$SERVICES" \
    | jq -r '.[] | select(.service.identifier=="dedicated_ip") | .details.servers[]?.id' \
    | sort -u)

if [ -z "$SERVER_IDS" ]; then
    echo "Error: no dedicated IP server found on your account." >&2
    echo "Make sure a Dedicated IP add-on is active and assigned in Nord Account." >&2
    exit 1
fi

# If a specific server id was requested, keep only that one.
if [ -n "$SERVER_FILTER" ]; then
    SERVER_IDS=$(echo "$SERVER_IDS" | grep -x "$SERVER_FILTER" || true)
    if [ -z "$SERVER_IDS" ]; then
        echo "Error: server id '$SERVER_FILTER' is not one of your dedicated servers." >&2
        exit 1
    fi
fi

mkdir -p Connections
CURRENT_DATE=$(date +%Y%m%d)
GENERATED=0

# ---------------------------------------------------------------------------
# Step 3: per dedicated server, fetch endpoint/public key and write the config
# ---------------------------------------------------------------------------
for SERVER_ID in $SERVER_IDS; do
    echo "Fetching server details for dedicated server id ${SERVER_ID}..."
    SERVER=$(curl -s "${API}/servers?filters\[servers.id\]=${SERVER_ID}&limit=1")

    # The response is an array with a single server object.
    ENDPOINT=$(echo "$SERVER"    | jq -r '.[0].hostname // empty')
    STATION=$(echo "$SERVER"     | jq -r '.[0].station // empty')          # public dedicated exit IP
    country=$(echo "$SERVER"     | jq -r '.[0].locations[]?.country.name // empty' | head -n 1)
    city=$(echo "$SERVER"        | jq -r '.[0].locations[]?.country.city.name // empty' | head -n 1)
    PUBKEY=$(echo "$SERVER"      | jq -r '.[0].technologies[]?
                                            | select(.identifier | test("wireguard"))
                                            | .metadata[]?
                                            | select(.name=="public_key")
                                            | .value' | head -n 1)

    if [ -z "$STATION" ] || [ -z "$PUBKEY" ]; then
        echo "Warning: could not read station IP / public key for server id ${SERVER_ID}; skipping." >&2
        continue
    fi

    # Filename: yyyymmdd-DedicatedIP-Country-City-Endpoint.conf (matches v2 style).
    ENDPOINT_SHORT=$(echo "$ENDPOINT" | grep -o '^[^.]*')
    COUNTRY_CLEAN=$(echo "$country" | tr ' ' '_' | sed 's/[^a-zA-Z0-9_]//g')
    CITY_CLEAN=$(echo "$city" | tr ' ' '_' | sed 's/[^a-zA-Z0-9_]//g')
    OUTPUTFILENAME="Connections/${CURRENT_DATE}-DedicatedIP-${COUNTRY_CLEAN}-${CITY_CLEAN}-${ENDPOINT_SHORT}.conf"

    # Endpoint uses the station IP (the dedicated exit IP), not the hostname:
    # per the blog, dedicated hostnames do not reliably resolve, and WireGuard
    # resolves a hostname only once at load time anyway.
    cat <<EOF > "$OUTPUTFILENAME"
# NordVPN Dedicated IP - generated by NordVpnDedicatedIpApiToWG.sh (API method)
# Dedicated server id: ${SERVER_ID}
# Server hostname:     ${ENDPOINT}
# Dedicated exit IP:   ${STATION}
[Interface]
Address = ${INTERFACE_ADDRESS}
PublicKey = ${interfacePublicKey}
PrivateKey = ${PRIVATE}
Gateway = ${GATEWAY}
ListenPort = ${LISTEN_PORT}
MTU = ${MTU}
DNS = ${DNS}

[Peer]
PublicKey = ${PUBKEY}
AllowedIPs = ${ALLOWED_IPS}
Endpoint = ${STATION}:${ENDPOINT_PORT}
EndpointIp = ${STATION}
Hostname = ${ENDPOINT}
Country = ${country}
City = ${city}
PersistentKeepalive = ${PERSISTENT_KEEPALIVE}
EOF

    echo "Wireguard configuration file $OUTPUTFILENAME created successfully!"
    echo "   Endpoint (station IP): ${STATION}:${ENDPOINT_PORT}  (server ${ENDPOINT})"
    GENERATED=$((GENERATED + 1))
done

if [ "$GENERATED" -eq 0 ]; then
    echo "Error: no configuration files were generated." >&2
    exit 1
fi

exit 0

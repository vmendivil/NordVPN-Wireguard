# [Wireguard](https://www.wireguard.com) configuration file generator for a [NordVPN](https://nordvpn.com)

A `bash` scripts that generates [Wireguard](https://www.wireguard.com) configuration file for a [NordVPN](https://nordvpn.com) connection.

## INSTALL

This guide assumes the use of [Ubuntu](https://ubuntu.com). A similar install procedure will work on other distros.

### Clone this project

First let's clone this project so that you'll have the script on your target [Ubuntu](https://ubuntu.com) system.

### Install required packages

```bash
sudo apt install wireguard curl jq net-tools
```

### Install [NordVPN](https://nordvpn.com) client

Execute the following command and follow the on screen instructions:

```bash
sh <(curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh)
```

## Login to your [NordVPN](https://nordvpn.com) account

The procedure differs if you have `MFA` enabled on your account:

1. `MFA` is ENABLED on your account

   ```bash
   nordvpn login
   ```

   This will return a URL link.  
   Open the link on any browser, on any machine and perform the login.  
   Cancel out of the `Open with` popup, and copy the link that is assigned to the `Continue` link, under the message saying `You've successfully logged in`.

   Back to the terminal

   ```bash
   nordvpn login --callback "<The link you copied>"
   ```

   And it will log you in.

2. `MFA` is NOT ENABLED on your account

   Use `legacy` username and password to login.

   > Note: This will NOT work if you have `Multi Factor Authentication` enabled. (See above for the `MFA` method)

   ```bash
   nordvpn login --legacy​
   ```

## Change protocol to NordLynx

After a successful login, please set [NordVPN](https://nordvpn.com) to use `NordLynx` protocol.

```bash
sudo nordvpn set technology nordlynx
```

## Generate [Wireguard](https://www.wireguard.com) configuration files

The script is quite simple and can be run without parameters to generate a config file for the recommended server:

```bash
$ ./NordVpnToWireguard.sh
Connect to NordVPN to gather connection parameters....
Wireguard configuration file NordVPN-us1234.conf created successfully!
```

Requesting a specific country:

```bash
$ ./NordVpnToWireguard.sh Canada
Connect to NordVPN to gather connection parameters....
Wireguard configuration file NordVPN-ca1234.conf created successfully!
```

Requesting a specific city

```bash
$ ./NordVpnToWireguard.sh Berlin
Connect to NordVPN to gather connection parameters....
Wireguard configuration file NordVPN-de1234.conf created successfully!
```

Requesting a specific country and city

```bash
$ ./NordVpnToWireguard.sh Japan Tokyo
Connect to NordVPN to gather connection parameters....
Wireguard configuration file NordVPN-jp1234.conf created successfully!
```

Requesting a specific server group

```bash
$ ./NordVpnToWireguard.sh Double_VPN
Connect to NordVPN to gather connection parameters....
Wireguard configuration file NordVPN-ca-us1234.conf created successfully!
```

Getting help:

```bash
$ ./NordVpnToWireguard.sh --help
Usage: NordVpnToWireguard [command options] [<country>|<server>|<country_code>|<city>|<group>|<country> <city>]
Command Options includes:
   <country>       argument to create a Wireguard config for a specific country. For example: 'NordVpnToWireguard Australia'
   <server>        argument to create a Wireguard config for a specific server. For example: 'NordVpnToWireguard jp35'
   <country_code>  argument to create a Wireguard config for a specific country. For example: 'NordVpnToWireguard us'
   <city>          argument to create a Wireguard config for a specific city. For example: 'NordVpnToWireguard Hungary Budapest'
   <group>         argument to create a Wireguard config for a specific servers group. For example: 'NordVpnToWireguard connect Onion_Over_VPN'
   -h | --help     - displays this message.
```

## Generate a configuration file for a NordVPN Dedicated IP

For a [NordVPN Dedicated IP](https://support.nordvpn.com/hc/en-us/articles/19507808024209-Dedicated-NordVPN-IP-addresses), use `NordVpnDedicatedIpToWG.sh` instead.

> **Why a separate script?** The standard script reads the `[Peer]` details from NordVPN's
> `recommendations` API. That API only returns shared/public servers — it never returns the
> dedicated-IP server assigned to your account, so using it for a dedicated IP would write the
> wrong server's IP and public key and the WireGuard handshake would fail. The dedicated-IP
> script skips the API entirely and reads everything from the live tunnel after connecting:
> the peer public key from `wg show nordlynx peers`, the endpoint from `wg show nordlynx endpoints`,
> and the hostname/IP/country/city from `nordvpn status`.

Prerequisite: a Dedicated IP must already be activated/assigned in your Nord Account.

Connect using the dedicated IP group (default):

```bash
$ ./NordVpnDedicatedIpToWG.sh
Connecting to NordVPN dedicated IP group to gather connection parameters....
Wireguard configuration file Connections/20260615-DedicatedIP-United_States-New_York-us4955.conf created successfully!
WireGuard endpoint: 185.93.0.116:51820  (server us4955.nordvpn.com)
Dedicated exit IP:  198.51.100.22
```

Connect to a specific dedicated server (recommended — `--group` only routes you to *a* dedicated
server in your region, while the hostname pins your exact assigned server). Find your assigned
server in your Nord Account, then:

```bash
$ ./NordVpnDedicatedIpToWG.sh us4955
Connecting to NordVPN dedicated server 'us4955' to gather connection parameters....
Wireguard configuration file Connections/20260615-DedicatedIP-United_States-New_York-us4955.conf created successfully!
```

> **Note on the config format.** Like `NordVpnToWireguard-v2.sh`, the generated file is intended for
> this repo's OPNsense import workflow and carries extra, non-standard keys (`Gateway`, `EndpointIp`,
> `Country`, `City`, etc.). It is therefore **not** a plain `wg-quick` file — `wg-quick up <file>`
> would reject those keys. Strip the non-standard keys first if you need a standalone wg-quick config.
>
> **Note on the endpoint.** NordLynx uses a double-NAT layer, so the WireGuard `Endpoint` IP can differ
> from your public dedicated "exit" IP. The script puts the *negotiated* endpoint (what makes the
> handshake work) in `Endpoint`, and records the dedicated exit IP as a comment at the top of the file
> for cross-checking against your Nord Account assignment.

## Use the generated [Wireguard](https://www.wireguard.com) configuration files

Import the file/s with the  [Wireguard](https://www.wireguard.com) client in any platform and activate the `VPN`.
# Dedicated IP script — testing context & handoff

Context doc for testing `NordVpnDedicatedIpToWG.sh`. Read this first when resuming in a fresh session.

## Status
- Branch: **`dev_dedicatedIP`** (pushed to origin, tracking set). Isolated from `master` until verified.
- Files added/changed in this branch: `NordVpnDedicatedIpToWG.sh` (new), `README.md` (Dedicated IP section), `How To.txt`, this doc.
- Built and statically validated only. **Not yet run against a live NordVPN connection** (no CLI available on the dev machine).

## What the script does (and why it differs from v2)
`NordVpnToWireguard-v2.sh` reads `[Peer]` details from NordVPN's `recommendations` API.
That API **only returns shared/public servers — never the account's dedicated-IP server**, so it
would write the wrong server IP + public key and the handshake would fail.

So the dedicated-IP script **skips the API** and reads everything from the live tunnel after connecting:
- `[Peer] PublicKey` ← `sudo wg show nordlynx peers` (the connected = dedicated server's key)
- `[Peer] Endpoint`  ← `sudo wg show nordlynx endpoints` (the **negotiated** WG endpoint IP:port)
- Hostname / exit IP / Country / City ← `nordvpn status`
- `[Interface]` private key ← `wg show nordlynx private-key`; client address ← `ip addr show nordlynx` (10.5.0.2/32)

Connect target: `--group dedicated_ip` by default, or a specific assigned hostname passed as `$1`
(preferred — `--group` only routes to *a* dedicated server in the region, not necessarily yours).

Output format intentionally matches v2 (OPNsense GUI import): carries non-standard keys
(`Gateway`, `EndpointIp`, `Country`, `City`, `PublicKey` in `[Interface]`). **Not a plain wg-quick file.**
Adds `MTU = 1420`, canonical `::/0`, and a `.1` gateway per the repo's OPNsense notes.

## How to test (on a machine with the NordVPN CLI + dedicated IP assigned)
```bash
git fetch origin && git checkout dev_dedicatedIP
chmod +x NordVpnDedicatedIpToWG.sh        # in case exec bit didn't survive
sudo nordvpn set technology nordlynx       # ensure NordLynx
./NordVpnDedicatedIpToWG.sh <your-assigned-dedicated-hostname>   # e.g. us4955
# or, default group form:
./NordVpnDedicatedIpToWG.sh
```
Output file lands in `Connections/YYYYMMDD-DedicatedIP-<Country>-<City>-<server>.conf`.

## Checklist for the live run
1. **Connects** and writes a file in `Connections/`.
2. **`--group dedicated_ip` token is correct** for the installed client — confirm with `nordvpn groups`.
   If wrong, that's the first thing to fix (see "open questions").
3. **`nordvpn status` exposes an `IP:` field** — confirm labels are exactly `Hostname:`, `IP:`,
   `Country:`, `City:` with `": "` separator and no ANSI codes when piped. Script falls back to the
   WG endpoint IP if `IP:` is missing.
4. **Endpoint vs exit IP (the key uncertainty):** NordLynx double-NAT means the `Endpoint` IP
   (`wg show endpoints`) can differ from the public dedicated exit IP (`nordvpn status` IP). The script
   writes the negotiated endpoint into `Endpoint` and records the exit IP as a comment at the top of
   the `.conf`. **Compare the two on first run.** If they differ, confirm which one the dedicated IP
   actually needs for a working handshake + correct exit IP.
5. **Handshake completes** when the config is imported (check `latest handshake` / OPNsense status),
   and traffic exits via the dedicated IP (verify external IP).

## Open questions to resolve during testing
- Exact `--group` token (`dedicated_ip` vs other casing) on the target client version.
- Whether `Endpoint` should be the negotiated WG endpoint (current choice) or the dedicated exit IP,
  under double-NAT — only a live handshake confirms this.
- Whether `nordvpn status` field labels/format match assumptions on the installed version.

## Validation already done (static, via research)
- Group token corrected `Dedicated_IP` → `dedicated_ip`.
- `::0/0` → canonical `::/0`.
- Peer key via `wg show nordlynx peers` (script-stable) instead of grep/awk on default output.
- `^IP:` anchored to avoid matching IPv6/other lines; `awk -F': '` handles multi-word Country/City.
- DNS `103.86.96.100, 103.86.99.100` confirmed current. `MTU = 1420` correct for NordLynx.
- Parsing logic dry-tested against mock `nordvpn status` / `wg show endpoints` outputs — all fields extract correctly.

## After it works
Merge `dev_dedicatedIP` → `master`. Update this doc / README with the resolved endpoint-vs-exit-IP answer.

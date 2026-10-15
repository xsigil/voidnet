# voidnet

A high-assurance, ephemeral network routing and service confinement engine written in **OCaml 5** (`Eio`).

`voidnet` orchestrates heterogeneous egress tunnels (**WireGuard**, **OpenVPN**, and **Tor**) under unified, load-balanced local SOCKS5 endpoints. Each network route is strictly isolated inside a dedicated Linux Network Namespace (`netns`) and wrapped within a volatile RAM jail (`void jail` / `tmpfs`) to prevent DNS leaks, host contamination, and runtime data persistence.

---

## Key Features

- **Multi-Protocol Aggregation:** Round-robin or weighted balancing across WireGuard, OpenVPN, and Tor egress nodes through a single SOCKS5 endpoint (`127.0.0.1:1080`).
- **Complete Kernel Isolation:** Dedicated network namespaces per tunnel with point-to-point `veth` routing and deterministic DNS isolation (`/etc/netns/<NS>/resolv.conf`).
- **Zero-Trace Confinement:** External binaries (`openvpn`, `wg`, `tor`) execute inside volatile RAM (`tmpfs`) via `void jail`. When stopped, all execution artifacts vanish completely.
- **Traffic Confinement & Firewall:** Host-level `nftables` synthesis strictly drops inter-namespace cross-traffic while masquerading authorized egress traffic.
- **Graceful Lifecycle Management:** Automatic recovery from crashes and clean teardown of network namespaces, interfaces, and jail mounts on `SIGINT` / `SIGTERM`.

---

## Architecture Overview

```text
 ┌────────────────────────────────────────────────────────────────────────┐
 │                      Host Network Namespace (Root)                     │
 │                                                                        │
 │   OCaml 5 Monolith (Eio Runtime)                                       │
 │     • SOCKS5 Inbound Listener (:1080)                                  │
 │     • Load Balancing Dispatcher (Round-Robin / Weighted)               │
 │     • Dynamic netns Provisioning & nftables Synthesizer                │
 │     • Process Supervisor for `void jail` instances                     │
 └──────────────┬──────────────────┬──────────────────┬───────────────────┘
                │ veth1            │ veth2            │ veth3
                ▼                  ▼                  ▼
       ┌─────────────────┐┌─────────────────┐┌─────────────────┐
       │ netns: ns-wg-01 ││ netns: ns-ovpn1 ││ netns: ns-tor-01│
       │ IP: 10.200.1.2  ││ IP: 10.200.2.2  ││ IP: 10.200.3.2  │
       │ Gateway: .1     ││ Gateway: .1     ││ Gateway: .1     │
       │ ┌─────────────┐ ││ ┌─────────────┐ ││ ┌─────────────┐ │
       │ │ void jail   │ ││ │ void jail   │ ││ │ void jail   │ │
       │ │ [wireguard] │ ││ │ [openvpn]   │ ││ │ [tor daemon]│ │
       │ └─────────────┘ ││ └─────────────┘ ││ └─────────────┘ │
       └─────────────────┘└─────────────────┘└─────────────────┘

```

---

## Prerequisites

* **OS:** Linux (x86_64) with kernel packet forwarding enabled:
```bash
sudo sysctl -w net.ipv4.ip_forward=1

```


* **System Tools:** `iproute2`, `nftables`, `wireguard-tools`, `openvpn`, `tor`, and `void` CLI.
* **OCaml:** OCaml 5.x, `opam`, `dune` (>= 3.x), `eio`, `eio_main`.

---

## Configuration

Define tunnel nodes and listeners in a YAML configuration file (e.g., `config.yaml`):

```yaml
version: "1.0"

tunnels:
  - id: wg-node-01
    type: wireguard
    config: ./wg_configs/node01.conf
    subnet: 10.200.1.0/24
    dns: 10.200.1.1
    jail:
      lib_path: ./jail_libs

  - id: ovpn-node-01
    type: openvpn
    config: ./ovpn_configs/node01.ovpn
    auth_file: ./ovpn_configs/auth.txt
    subnet: 10.200.2.0/24
    jail:
      lib_path: ./jail_libs

  - id: tor-node-01
    type: tor
    subnet: 10.200.3.0/24
    socks_port: 9050
    jail:
      lib_path: ./jail_libs

listeners:
  - bind: "127.0.0.1:1080"
    strategy: round-robin
    pool:
      - wg-node-01
      - ovpn-node-01
      - tor-node-01

```

---

## Usage

### 1. Build and Prepare Runtime Libraries

Extract the shared library dependencies needed for jailed execution:

```bash
# Build the binary
make build

# Extract required libraries using void ldd into ./jail_libs
make prepare

```

### 2. Run the Engine

Root privileges are required to configure network namespaces and launch jails:

```bash
# Run with default config (config.example.yaml)
make run

# Run with a custom config file
make run CONFIG=path/to/config.yaml

# Alternatively, run the binary directly
sudo ./_build/default/bin/main.exe run path/to/config.yaml

# Run with verbose / debug tracing enabled
sudo ./_build/default/bin/main.exe run path/to/config.yaml --debug

```

### 3. Verify SOCKS5 Connectivity

Query an external IP check service through the local SOCKS5 endpoint to verify traffic egress:

```bash
curl -x socks5h://127.0.0.1:1080 [https://ifconfig.me/ip](https://ifconfig.me/ip)

```

Repeat requests to confirm that traffic is dynamically distributed across active tunnel endpoints.

---

## Cleanup & Teardown

`voidnet` automatically performs a graceful teardown upon receiving `SIGINT` (Ctrl+C) or `SIGTERM`.

If a process was terminated abnormally and left orphaned namespaces:

```bash
# Clean up residual netns instances (ns-*)
make clean-netns

# Remove build artifacts, jail libraries, and netns
make clean

```
---

### Disclaimer

This software, architecture, and associated documentation are provided strictly for **educational, research, and defensive security purposes**. 

* **Authorized Use Only:** The techniques described herein (including network namespace manipulation, routing control, and multi-protocol traffic orchestration) are intended for authorized testing, privacy research, and secure infrastructure design.
* **No Unlawful Activity:** The author strictly prohibits the use of this project for any illegal activities, malicious operations, unauthorized surveillance evasion, or actions violating the terms of service of any third-party network, ISP, or service provider.
* **No Warranty & Limitation of Liability:** This software is provided "AS IS", without warranty of any kind, express or implied. In no event shall the author or copyright holders be liable for any claim, damages, network misconfigurations, administrative sanctions, or other liability arising from the use or misuse of this software.

Users are solely responsible for ensuring compliance with all applicable local, national, and international laws, regulations, and institutional policies before deploying or running this architecture.

---

## License

MIT

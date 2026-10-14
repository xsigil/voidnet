特定の商用サービス名（ProtonVPN等）やローカル固有のパス構成（`/var/lib/void/lib`、ローカル構成ファイル参照など）を抽象化・汎用化し、アーキテクチャ仕様書として外部公開可能な状態に校正した内容です。

---

# SPEC.md: Unified Multi-Tunnel Orchestrator & Void Containment Architecture

## 1. System Overview & Invariants

This specification defines the architecture of `voidnet`, a high-assurance network routing and service confinement engine written in **OCaml 5** (`Eio`).

It provides an orchestration layer that:

1. Provisions isolated Linux Network Namespaces (`netns`) per egress/ingress route.


2. Isolates routing tables, avoiding host IP leaks and DNS cross-contamination.


3. Confines external binary runtimes (WireGuard utilities, OpenVPN, Tor daemons) inside **Void-9 volatile RAM jails** via `void jail` (`CLONE_NEWNS`, `CLONE_NEWPID`, `tmpfs` rootfs).


4. Aggregates multi-homed egress channels into unified, load-balanced local SOCKS5 endpoints.


5. Ingresses encrypted traffic via Tor Onion Services and peer-to-peer WireGuard internal listeners simultaneously.



---

## 2. Kernel Isolation & Networking Invariants

```text
 ┌────────────────────────────────────────────────────────────────────────┐
 │                      Host Network Namespace (Root)                     │
 │                                                                        │
 │   OCaml 5 Monolith (Eio Runtime)                                       │
 │     • SOCKS5 Inbound Listener (:1080)                                  │
 │     • Load Balancing Dispatcher (RoundRobin / Weighted)                │
 │     • Dynamic netns Provisioning & nftables Synthesizer                │
 │     • Process Supervisor for `void jail` instances                     │
 └──────────────┬──────────────────┬──────────────────┬───────────────────┘
                │ veth1            │ veth2            │ veth3
                ▼                  ▼                  ▼
       ┌─────────────────┐┌─────────────────┐┌─────────────────┐
       │ netns: ns-wg1   ││ netns: ns-ovpn1 ││ netns: ns-tor1  │
       │ IP: 10.200.1.2  ││ IP: 10.200.2.2  ││ IP: 10.200.3.2  │
       │ Gateway: .1     ││ Gateway: .1     ││ Gateway: .1     │
       │ DNS: Tunnel DNS ││ DNS: Tunnel DNS ││ DNS: 127.0.0.1  │
       │                 ││                 ││                 │
       │ ┌─────────────┐ ││ ┌─────────────┐ ││ ┌─────────────┐ │
       │ │ void jail   │ ││ │ void jail   │ ││ │ void jail   │ │
       │ │ [wireguard] │ ││ │ [openvpn]   │ ││ │ [tor daemon]│ │
       │ └─────────────┘ ││ └─────────────┘ ││ └─────────────┘ │
       └─────────────────┘└─────────────────┘└─────────────────┘

```

### 2.1. Netns & Virtual Ethernet (`veth`) Topology

Each configured tunnel node is bound to a dedicated Linux Network Namespace (`ns-<id>`):

* **Host Interconnect (veth pair):**
* `veth-<id>-br` resides in the host root namespace (`10.200.X.1/24`).


* `veth-<id>-ns` is moved into `ns-<id>` and renamed to `veth0` (`10.200.X.2/24`).




* **Point-to-Point Routing Invariant:**
* Inside `ns-<id>`, the default gateway is unconditionally pinned to `10.200.X.1` prior to tunnel activation.


* Direct host loopback (`lo`) is brought up (`ip link set lo up`).





### 2.2. Kernel Packet Forwarding & sysctl Enforcements

The host must enforce the following kernel controls:

```ini
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

```

---

## 3. DNS Leak Elimination Specification

DNS leakage represents a primary failure mode when multiplexing multi-provider tunnels on Linux. The following strict rules are enforced:

### 3.1. Namespace-Specific Overlay (`/etc/netns/<NS>/resolv.conf`)

The Linux C library (`glibc` / `musl`) resolves DNS via `/etc/resolv.conf`. When entering a namespace via `ip netns exec` or `setns(CLONE_NEWNET)`, the kernel intercepts `/etc/resolv.conf` with `/etc/netns/<NS>/resolv.conf` if present:

1. For every provisioned namespace `ns-<id>`, the engine mounts or writes `/etc/netns/ns-<id>/resolv.conf`.


2. **WireGuard / OpenVPN nodes:** Pinned strictly to the internal DNS pushed by the respective gateway or dedicated tunnel resolver (e.g., `<tunnel-gateway-dns>`).


3. **Tor nodes:** Pinned to `nameserver 127.0.0.1` (listening on Tor `DNSPort 5353`).


4. **Host fallback isolation:** Public resolvers (`1.1.1.1`, `8.8.8.8`) are strictly prohibited inside tenant namespaces to prevent out-of-band egress leaks.



---

## 4. `nftables` Firewall & Traffic Confinement

The host firewall isolates tenant traffic, enforces NAT translation, and prevents forward leakage across namespaces.

### 4.1. Ruleset Template (`voidnet.nft`)

```nft
table inet voidnet {
    chain forward {
        type filter hook forward priority filter; policy drop;

        # Allow established and related traffic
        ct state established,related accept

        # Authorize inter-namespace egress to external WAN (e.g., wlan0, eth0)
        iifname "veth-*-br" oifname "$WAN_IF" accept

        # Inter-netns cross-traffic is categorically dropped
        iifname "veth-*-br" oifname "veth-*-br" drop
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;

        # Masquerade traffic exiting to WAN
        ip saddr 10.200.0.0/16 oifname "$WAN_IF" masquerade
    }
}

```

---

## 5. Void-9 Confinement Integration (`void jail`)

External tunnel executables (`wireguard-tools`, `openvpn`, `tor`) must not execute unconfined directly inside the root filesystem. They are wrapped inside **Void-9 volatile RAM jails**.

### 5.1. Confinement Principles

* **Pure Volatile Storage (`tmpfs`):** The jail rootfs resides entirely in physical RAM.


* **Namespace Isolation:** Execution invokes `void jail` with `CLONE_NEWNS`, `CLONE_NEWPID`, `CLONE_NEWIPC`, and `CLONE_NEWUTS`.


* **Zero Persistence:** When a tunnel crashes or is terminated by OCaml, all execution artifacts, runtime memory, and file sockets vanish immediately with zero residual bytes written to non-volatile disks.



### 5.2. Service Confinement Implementations

#### 5.2.1. WireGuard Node

Because WireGuard kernel devices operate at L3 within the network namespace, interface setup is decoupled from process lifecycle:

1. Interface created in root namespace: `ip link add dev wg-<id> type wireguard`.


2. Transferred into target netns: `ip link set dev wg-<id> netns ns-<id>`.


3. Private key / peer configuration applied inside `ns-<id>` via `void jail`:



```bash
ip netns exec ns-<id> void jail \
  --bind=/etc/voidnet/wireguard/wg-<id>.conf:/etc/wireguard/wg.conf:ro \
  --lib /usr/lib/void \
  /usr/bin/wg setconf wg-<id> /etc/wireguard/wg.conf

```

#### 5.2.2. OpenVPN Node

OpenVPN requires dynamic TLS negotiation and an active process loop:

```bash
ip netns exec ns-<id> void jail \
  --bind=/etc/voidnet/openvpn/client.ovpn:/etc/openvpn/config.ovpn:ro,/etc/voidnet/openvpn/auth.txt:/etc/openvpn/auth.txt:ro \
  --lib /usr/lib/void \
  /usr/bin/openvpn \
    --config /etc/openvpn/config.ovpn \
    --auth-user-pass /etc/openvpn/auth.txt \
    --dev tun0 \
    --script-security 2 \
    --redirect-gateway def1 bypass-dhcp

```

#### 5.2.3. Tor Onion Service & Egress Node

Tor processes run enclosed in a volatile ramfs jail, projecting only the hidden service private key directory:

```bash
ip netns exec ns-<id> void jail \
  --bind=/var/lib/voidnet/tor-<id>/keys:/var/lib/tor/hidden_service:rw,/etc/voidnet/tor/torrc:/etc/tor/torrc:ro \
  --lib /usr/lib/void \
  /usr/bin/tor -f /etc/tor/torrc

```

* **Dynamic Hostname Harvest:** OCaml monitors `/var/lib/voidnet/tor-<id>/keys/hostname` to extract the dynamically assigned `.onion` address without network probes.



---

## 6. OCaml 5 Engine Architecture

### 6.1. Domain Configuration Model (`config.yaml`)

```yaml
version: "1.0"

tunnels:
  - id: wg-node-1
    type: wireguard
    config: /etc/voidnet/wireguard/node1.conf
    subnet: 10.200.1.0/24
    dns: 10.200.1.1
    jail:
      lib_path: /usr/lib/void

  - id: ovpn-node-1
    type: openvpn
    config: /etc/voidnet/openvpn/node1.ovpn
    auth_file: /etc/voidnet/openvpn/auth.txt
    subnet: 10.200.2.0/24
    dns: 10.200.2.1
    jail:
      lib_path: /usr/lib/void

  - id: tor-node-1
    type: tor
    subnet: 10.200.3.0/24
    socks_port: 9050
    services:
      - name: hidden-admin
        type: onion
        target_port: 8080
        virtual_port: 80
        key_dir: /var/lib/voidnet/tor-1/keys
    jail:
      lib_path: /usr/lib/void

listeners:
  - bind: "127.0.0.1:1080"
    strategy: round-robin
    pool:
      - wg-node-1
      - ovpn-node-1
      - tor-node-1

```

### 6.2. Core Module Layout

```text
voidnet/
├── bin/
│   └── main.ml               # CLI entrypoint & Eio lifecycle supervisor
├── lib/
│   ├── config.ml             # YAML deserializer & ADT validations
│   ├── netns.ml              # Linux Netlink / veth / netns primitives
│   ├── firewall.ml           # nftables dynamic rule synthesis
│   ├── jail.ml               # Process invocation via `void jail` wrapper
│   ├── socks5.ml             # Pure OCaml SOCKS5 state-machine (RFC 1928)
│   └── balancer.ml           # Multi-pool connection balancing engine
└── test/
    └── test_config.ml

```

### 6.3. SOCKS5 Monolithic Forwarding Loop

Instead of spawning third-party proxies (`microsocks`, `tinyproxy`), incoming connections to `:1080` are handled directly by `Eio`:

1. Client establishes connection to `127.0.0.1:1080`.


2. OCaml performs SOCKS5 handshake (No Auth, RFC 1928).


3. The balancer selects a healthy target namespace based on the defined strategy.


4. An outbound socket is established towards the egress gateway inside target namespace (`10.200.X.2`).


5. `Eio.Flow.copy` bridges streams bidirectionally in userspace with zero external process spawning.



---

## 7. Lifecycle & Failure Recovery

1. **Graceful Shutdown (`SIGINT` / `SIGTERM`):**
* Stop incoming TCP listeners.


* Terminate supervised `void jail` processes.


* Delete virtual ethernet host pairs (`ip link del veth-<id>-br`), triggering automatic kernel-side deletion of paired peer interfaces inside namespaces.


* Delete network namespaces (`ip netns del ns-<id>`).


* Flush `inet voidnet` nftables table.




2. **Crash Resilience:**
* Any orphaned namespace or veth interface is detected during startup synchronization and purged idempotently before spinning up the configured state.

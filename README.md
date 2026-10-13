# voidnet

**Next-Gen Ephemeral Multi-Protocol Tunnel Balancer in OCaml / Eio**

`voidnet` is a lightweight, zero-trace network balancer that unifies heterogeneous egress technologies (**WireGuard**, **OpenVPN**, and **Tor**) under a single SOCKS5 endpoint (`127.0.0.1:1080`).

Each outgoing request is transparently round-robin dispatched across isolated Linux network namespaces (`netns`) and contained inside ephemeral `tmpfs` jails.

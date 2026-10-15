open Eio.Std

let run_cmd cmd =
  let cmd_str = String.concat " " cmd in
  let ret = Sys.command cmd_str in
  if ret <> 0 then
    traceln "[Netns][WARN] Command exited with code %d: %s" ret cmd_str

let run_cmd_strict cmd =
  (* すべての引数を Filename.quote して # や空白によるシェル誤パースを完全防止 *)
  let cmd_str = String.concat " " (List.map Filename.quote cmd) in
  let ret = Sys.command cmd_str in
  if ret <> 0 then
    failwith (Printf.sprintf "Command failed (%d): %s" ret cmd_str)

let teardown ~netns ~veth_host =
  let q_veth = Filename.quote veth_host in
  let q_netns = Filename.quote netns in
  (* down にしてから del することでカーネルのリファレンスカウントを即時解放 *)
  ignore (Sys.command (Printf.sprintf "ip link set %s down 2>/dev/null || true" q_veth));
  ignore (Sys.command (Printf.sprintf "ip link del %s 2>/dev/null || true" q_veth));
  ignore (Sys.command (Printf.sprintf "ip netns del %s 2>/dev/null || true" q_netns));
  let dir = Printf.sprintf "/etc/netns/%s" netns in
  ignore (Sys.command (Printf.sprintf "rm -rf %s 2>/dev/null || true" (Filename.quote dir)))

let setup_resolv_conf ~netns ~dns_opt =
  let dir = Printf.sprintf "/etc/netns/%s" netns in
  run_cmd [ "mkdir"; "-p"; Filename.quote dir ];
  let conf_path = Filename.concat dir "resolv.conf" in
  let dns_server = Option.value dns_opt ~default:"10.2.0.1" in
  (* timeout を 2 秒、attempts を 2 回に設定して DNS 待ちを短縮 *)
  let content = Printf.sprintf "nameserver %s\noptions timeout:2 attempts:2\n" dns_server in
  Out_channel.with_open_text conf_path (fun oc ->
    Out_channel.output_string oc content);
  traceln "[Netns] Configured DNS for %s -> %s" netns dns_server

let parse_subnet subnet_str =
  match String.split_on_char '/' subnet_str with
  | base :: _ ->
    let parts = String.split_on_char '.' base in
    (match parts with
     | [a; b; c; _] ->
       let host_ip = Printf.sprintf "%s.%s.%s.1" a b c in
       let ns_ip = Printf.sprintf "%s.%s.%s.2" a b c in
       (host_ip, ns_ip)
     | _ -> failwith ("Invalid subnet format: " ^ subnet_str))
  | [] -> failwith "Empty subnet"

let setup ~sw (tunnel : Config.tunnel_spec) =
  let netns = "ns-" ^ tunnel.id in
  let veth_host = Printf.sprintf "veth-%s-br" tunnel.id in
  let veth_ns = "veth0" in
  let host_ip, ns_ip = parse_subnet tunnel.subnet in

  traceln "[Netns] Provisioning %s (Subnet: %s)..." netns tunnel.subnet;

  (* 起動前の残骸を掃除 *)
  teardown ~netns ~veth_host;

  (* Switch 解放時にも登録 *)
  Switch.on_release sw (fun () ->
    teardown ~netns ~veth_host
  );

  (* 1. netns 作成 *)
  run_cmd_strict [ "ip"; "netns"; "add"; netns ];

  (* 2. loopback を UP *)
  run_cmd_strict [ "ip"; "netns"; "exec"; netns; "ip"; "link"; "set"; "lo"; "up" ];

  (* 3. veth ペア作成と netns への移動 *)
  run_cmd_strict [
    "ip"; "link"; "add"; veth_host; "type"; "veth";
    "peer"; "name"; "veth-tmp"
  ];
  run_cmd_strict [ "ip"; "link"; "set"; "veth-tmp"; "netns"; netns ];
  run_cmd_strict [ "ip"; "netns"; "exec"; netns; "ip"; "link"; "set"; "veth-tmp"; "name"; veth_ns ];

  (* 4. veth IP 付与 & UP *)
  run_cmd_strict [ "ip"; "addr"; "add"; Printf.sprintf "%s/24" host_ip; "dev"; veth_host ];
  run_cmd_strict [ "ip"; "link"; "set"; veth_host; "up" ];
  run_cmd_strict [ "ip"; "netns"; "exec"; netns; "ip"; "addr"; "add"; Printf.sprintf "%s/24" ns_ip; "dev"; veth_ns ];
  run_cmd_strict [ "ip"; "netns"; "exec"; netns; "ip"; "link"; "set"; veth_ns; "up" ];

  (* 5. トンネル種別に応じたインターフェースとルーティング設定 *)
  (match tunnel.tunnel_type with
  | "wireguard" ->
     let wg_dev = "wg0" in
     run_cmd_strict [ "ip"; "link"; "add"; "dev"; wg_dev; "type"; "wireguard" ];
     run_cmd_strict [ "ip"; "link"; "set"; wg_dev; "netns"; netns ];

     (match tunnel.config with
      | Some conf_path ->
        let client_ip = Option.value tunnel.client_ip ~default:"10.2.0.2/32" in
        run_cmd_strict [ "ip"; "netns"; "exec"; netns; "wg"; "setconf"; wg_dev; conf_path ];
        run_cmd_strict [ "ip"; "netns"; "exec"; netns; "ip"; "addr"; "add"; client_ip; "dev"; wg_dev ];
        (* run_cmd_strict [ "ip"; "netns"; "exec"; netns; "ip"; "link"; "set"; wg_dev; "mtu"; "1420" ]; *)
        (* run_cmd_strict [ "ip"; "netns"; "exec"; netns; "ip"; "link"; "set"; wg_dev; "mtu"; "1280" ]; *)
        run_cmd_strict [ "ip"; "netns"; "exec"; netns; "ip"; "link"; "set"; wg_dev; "up" ];
        run_cmd_strict [ "ip"; "netns"; "exec"; netns; "ip"; "route"; "add"; "default"; "dev"; wg_dev ]
      | None ->
        failwith (Printf.sprintf "WireGuard tunnel '%s' requires 'config' path" tunnel.id))

  | "openvpn" ->
     (* /dev/net/tun の作成 *)
     run_cmd_strict [ "ip"; "netns"; "exec"; netns; "mkdir"; "-p"; "/dev/net" ];
     run_cmd [ Printf.sprintf "ip netns exec %s mknod -m 666 /dev/net/tun c 10 200 2>/dev/null || true" (Filename.quote netns) ];

     (* netns 内のフォワーディング有効化 *)
     run_cmd_strict [ "ip"; "netns"; "exec"; netns; "sysctl"; "-w"; "net.ipv4.ip_forward=1" ];

     (* nftables による NAT/マスカレードルールの適用 *)
     let nft_cmd = Printf.sprintf
       "ip netns exec %s nft -f - << 'EOF'\n\
        flush ruleset\n\
        table ip void_nat {\n\
          chain postrouting {\n\
            type nat hook postrouting priority srcnat; policy accept;\n\
            oifname \"tun*\" masquerade\n\
          }\n\
        }\n\
        EOF" (Filename.quote netns)
     in
     run_cmd [ nft_cmd ];

     (* 初期デフォルトルート（OpenVPN 接続用） *)
     run_cmd_strict [ "ip"; "netns"; "exec"; netns; "ip"; "route"; "replace"; "default"; "via"; host_ip; "dev"; veth_ns ]

  | _ ->
     run_cmd_strict [ "ip"; "netns"; "exec"; netns; "ip"; "route"; "add"; "default"; "via"; host_ip ]
  );

  (* 6. DNS 設定 *)
  setup_resolv_conf ~netns ~dns_opt:tunnel.dns;

  traceln "[Netns] %s successfully initialized." netns

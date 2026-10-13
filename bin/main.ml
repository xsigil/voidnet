open Eio.Std

let debug_enabled = ref false

let log_debug fmt =
  if !debug_enabled then
    Eio.Std.traceln fmt
  else
    Format.ifprintf Format.std_formatter fmt

let run_prepare config_path =
  traceln "[Prepare] Reading specification from %s..." config_path;
  let cfg = Voidnet.Config.load_file config_path in
  let default_lib_dir = "./jail_libs" in
  Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote default_lib_dir)) |> ignore;

  let binaries = Hashtbl.create 8 in
  List.iter (fun (tunnel : Voidnet.Config.tunnel_spec) ->
    let lib_dir =
      match tunnel.jail with
      | Some j -> j.lib_path
      | None -> default_lib_dir
    in
    Sys.command (Printf.sprintf "mkdir -p %s" (Filename.quote lib_dir)) |> ignore;

    let bin =
      match tunnel.tunnel_type with
      | "wireguard" -> Some "wg"
      | "openvpn" -> Some "openvpn"
      | "tor" -> Some "tor"
      | _ -> None
    in
    match bin with
    | Some b -> Hashtbl.replace binaries b lib_dir
    | None -> ()
  ) cfg.tunnels;

  Hashtbl.iter (fun bin lib_dir ->
    Voidnet.Jail.prepare_binary ~lib_dir bin
  ) binaries;
  traceln "[Prepare] Shared libraries are prepared and ready for void jail."

let parse_ipv4 str =
  match String.split_on_char '.' str with
  | [a; b; c; d] ->
    let bytes = Bytes.create 4 in
    Bytes.set_uint8 bytes 0 (int_of_string a);
    Bytes.set_uint8 bytes 1 (int_of_string b);
    Bytes.set_uint8 bytes 2 (int_of_string c);
    Bytes.set_uint8 bytes 3 (int_of_string d);
    Eio.Net.Ipaddr.of_raw (Bytes.to_string bytes)
  | _ -> failwith ("Invalid IPv4 format: " ^ str)

let extract_target_ip (subnet : string) =
  let cidr = List.hd (String.split_on_char '/' subnet) in
  let parts = String.split_on_char '.' cidr in
  match parts with
  | [a; b; c; _] -> Printf.sprintf "%s.%s.%s.2" a b c
  | _ -> failwith ("Invalid subnet format: " ^ subnet)

let kill_all_subprocesses tunnels =
  List.iter (fun (t : Voidnet.Config.tunnel_spec) ->
    let netns = "ns-" ^ t.id in
    ignore (Sys.command (Printf.sprintf "pkill -9 -f '%s' 2>/dev/null || true" netns));
    ignore (Sys.command (Printf.sprintf "pkill -9 -f 'voidnet-tor-%s' 2>/dev/null || true" netns))
  ) tunnels;
  ignore (Sys.command "pkill -9 -f 'socat.*TCP:' 2>/dev/null || true")

let run_engine config_path =
  Eio_main.run @@ fun env ->
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let net = Eio.Stdenv.net env in
  traceln "[Engine] Loading specification from %s..." config_path;
  let cfg = Voidnet.Config.load_file config_path in
  traceln "[Engine] Loaded %d tunnels, %d listeners."
    (List.length cfg.Voidnet.Config.tunnels)
    (List.length cfg.Voidnet.Config.listeners);

  (* 1. 各名前空間・veth の初期化 *)
  List.iter Voidnet.Netns.setup cfg.Voidnet.Config.tunnels;

  let stop_promise, stop_resolver = Promise.create () in
  let shutting_down = ref false in
  let handle_signal _ =
    if not !shutting_down then begin
      shutting_down := true;
      traceln "\n[Engine] Signal received. Commencing immediate graceful teardown...";
      kill_all_subprocesses cfg.Voidnet.Config.tunnels;
      Promise.resolve stop_resolver ()
    end else begin
      traceln "\n[Engine] Second signal received. Force terminating...";
      exit 130
    end
  in
  Sys.set_signal Sys.sigint (Sys.Signal_handle handle_signal);
  Sys.set_signal Sys.sigterm (Sys.Signal_handle handle_signal);

  try
    Switch.run @@ fun sw ->
    let default_lib_dir = "./jail_libs" in

    (* 2. 各トンネルプロセスの起動 *)
    List.iter (fun (tunnel : Voidnet.Config.tunnel_spec) ->
      let netns = "ns-" ^ tunnel.id in
      let lib_dir =
        match tunnel.jail with
        | Some j -> j.lib_path
        | None -> default_lib_dir
      in
      match tunnel.tunnel_type with
      | "wireguard" ->
        (match tunnel.config with
         | Some conf_file ->
           Voidnet.Jail.setup_wireguard ~netns ~lib_dir ~config_file:conf_file
         | None ->
           traceln "[Engine][WARN] WireGuard tunnel '%s' missing config" tunnel.id)
      | "tor" ->
        let socks_port = Option.value ~default:9050 tunnel.socks_port in
        Voidnet.Jail.spawn_tor ~sw ~proc_mgr ~netns ~lib_dir ~socks_port ()
      | "openvpn" ->
        (match tunnel.config with
         | Some conf_file ->
           Voidnet.Jail.spawn_openvpn ~sw ~proc_mgr ~netns ~lib_dir
             ~config_file:conf_file ~auth_file:tunnel.auth_file ()
         | None ->
           traceln "[Engine][WARN] OpenVPN tunnel '%s' missing config" tunnel.id)
      | other ->
        traceln "[Engine][WARN] Unsupported tunnel type: %s" other
    ) cfg.Voidnet.Config.tunnels;

    (* 3. リスナーとバランサーの起動 *)
    List.iter (fun (listener : Voidnet.Config.listener_spec) ->
      let pool_tunnels =
        List.filter (fun (t : Voidnet.Config.tunnel_spec) ->
          List.mem t.id listener.pool
        ) cfg.Voidnet.Config.tunnels
      in
      let targets =
        List.map (fun (t : Voidnet.Config.tunnel_spec) ->
          let ip = extract_target_ip t.subnet in
          let port = Option.value ~default:9050 t.socks_port in
          { Voidnet.Balancer.ip; port }
        ) pool_tunnels
      in

      List.iteri (fun i tgt ->
        traceln "[Engine][Balancer Target %d] IP=%s Port=%d"
          i tgt.Voidnet.Balancer.ip tgt.Voidnet.Balancer.port
      ) targets;

      let balancer = Voidnet.Balancer.create targets in
      let bind_parts = String.split_on_char ':' listener.bind in
      let bind_host, bind_port =
        match bind_parts with
        | [h; p] -> (h, int_of_string p)
        | [p] -> ("127.0.0.1", int_of_string p)
        | _ -> ("127.0.0.1", 1080)
      in
      let ip = parse_ipv4 bind_host in
      let listen_addr = `Tcp (ip, bind_port) in
      let socket = Eio.Net.listen ~sw ~reuse_addr:true ~backlog:128 net listen_addr in
      traceln "[Engine][Listener] SOCKS5 entrypoint listening on %s:%d (Pool: %d nodes)"
        bind_host bind_port (List.length targets);

      Fiber.fork ~sw (fun () ->
        while not !shutting_down do
          try
            Eio.Net.accept_fork socket ~sw ~on_error:(fun exn ->
              match exn with
              | Eio.Cancel.Cancelled _ -> ()
              | _ -> traceln "[Engine][Accept][WARN] %s" (Printexc.to_string exn)
            ) (fun client_flow _client_addr ->
              let target = Voidnet.Balancer.next balancer in
              log_debug "[Engine][Proxy] >>> Dispatching request to %s:%d"
                target.Voidnet.Balancer.ip target.Voidnet.Balancer.port;

              let matching_tunnel =
                List.find_opt (fun (t : Voidnet.Config.tunnel_spec) ->
                  extract_target_ip t.subnet = target.Voidnet.Balancer.ip
                ) cfg.Voidnet.Config.tunnels
              in

              match matching_tunnel with
              | Some t when t.tunnel_type = "openvpn" || t.tunnel_type = "wireguard" ->
                let netns = "ns-" ^ t.id in
                (try
                   Switch.run @@ fun conn_sw ->
                   let socks_target = Voidnet.Socks5.handshake client_flow in
                   Voidnet.Socks5.forward_socat ~sw:conn_sw ~proc_mgr ~netns ~target:socks_target client_flow
                 with exn ->
                   Voidnet.Socks5.reply_failure client_flow;
                   log_debug "[Engine][Proxy][WARN] %s socat proxy error: %s" t.tunnel_type (Printexc.to_string exn));
                log_debug "[Engine][Proxy] <<< Connection closed for %s" netns
              | _ ->
                Voidnet.Socks5.forward_raw ~net ~target client_flow;
                log_debug "[Engine][Proxy] <<< Connection closed for %s:%d"
                  target.Voidnet.Balancer.ip target.Voidnet.Balancer.port
            )
          with
          | Eio.Cancel.Cancelled _ -> ()
          | exn ->
            if not !shutting_down then
              traceln "[Engine][Listener][WARN] Accept error: %s" (Printexc.to_string exn)
        done
      )
    ) cfg.Voidnet.Config.listeners;

    traceln "[Engine] All network namespaces, jails & listeners ready.";
    traceln "[Engine] Press Ctrl+C to terminate.";

    Promise.await stop_promise;
    traceln "[Engine] Cancelling all running fibers and releasing jail resources...";
    Switch.fail sw Exit
  with
  | Exit ->
    traceln "[Engine] Teardown complete. All jail resources and processes cleaned."

let () =
  let raw_args = Array.to_list Sys.argv |> List.tl in
  let has_debug = List.mem "--debug" raw_args || List.mem "-v" raw_args in
  if has_debug then debug_enabled := true;

  let args = List.filter (fun a -> a <> "--debug" && a <> "-v") raw_args in
  match args with
  | "prepare" :: rest ->
    let conf = match rest with path :: _ -> path | [] -> "config.yaml" in
    run_prepare conf
  | "run" :: rest ->
    let conf = match rest with path :: _ -> path | [] -> "config.yaml" in
    run_engine conf
  | [path] when Filename.extension path = ".yaml" || Filename.extension path = ".yml" ->
    run_engine path
  | [] ->
    run_engine "config.yaml"
  | _ ->
    Printf.eprintf "Usage:\n  voidnet prepare [config.yaml]\n  voidnet run [config.yaml] [--debug | -v]\n";
    exit 1
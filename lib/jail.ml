open Eio.Std

let find_binary name =
  let path = Sys.getenv_opt "PATH" |> Option.value ~default:"/usr/bin:/bin:/usr/sbin:/sbin" in
  let dirs = String.split_on_char ':' path in
  List.find_map (fun dir ->
    let candidate = Filename.concat dir name in
    if Sys.file_exists candidate then Some candidate else None
  ) dirs

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      (try Unix.rmdir path with _ -> ())
    end else
      (try Sys.remove path with _ -> ())

let prepare_binary ~lib_dir bin_name =
  match find_binary bin_name with
  | None -> failwith (Printf.sprintf "Binary '%s' not found in PATH" bin_name)
  | Some bin_path ->
    traceln "[Prepare] Extracting dependencies for %s (%s) into %s..." bin_name bin_path lib_dir;
    let cmd = Printf.sprintf "void jail --lib %s --extract %s"
      (Filename.quote lib_dir) (Filename.quote bin_path) in
    let ret = Sys.command cmd in
    if ret <> 0 then
      failwith (Printf.sprintf "Failed to extract libraries for '%s' (code %d)" bin_name ret)
    else
      traceln "[Prepare] Extracted dependencies for %s successfully." bin_name

let build_jail_cmd_args ~netns ~lib_dir ~binds ~exec_path args =
  let bind_args =
    match binds with
    | [] -> []
    | bs -> [ Printf.sprintf "--bind=%s" (String.concat "," bs) ]
  in
  [ "ip"; "netns"; "exec"; netns;
    "void"; "jail";
    "--lib"; lib_dir ]
  @ bind_args
  @ [ exec_path ] @ args

let setup_wireguard ~netns ~lib_dir ~config_file =
  match find_binary "wg" with
  | None -> failwith "'wg' binary not found"
  | Some wg_bin ->
    let abs_conf =
      if Filename.is_relative config_file then
        Filename.concat (Sys.getcwd ()) config_file
      else
        config_file
    in
    let cmd = Printf.sprintf
      "ip netns exec %s void jail --lib %s --bind=%s:/etc/wireguard/wg.conf:ro %s setconf veth0 /etc/wireguard/wg.conf"
      (Filename.quote netns)
      (Filename.quote lib_dir)
      (Filename.quote abs_conf)
      (Filename.quote wg_bin)
    in
    traceln "[Jail][WG] Applying config via void jail: %s" cmd;
    let ret = Sys.command cmd in
    if ret <> 0 then
      traceln "[Jail][WG][WARN] Command exited with code %d" ret

let spawn_tor ~sw ~proc_mgr ~netns ~lib_dir ~socks_port () =
  match find_binary "tor" with
  | None -> failwith "'tor' binary not found"
  | Some tor_bin ->
    let temp_base = Printf.sprintf "/tmp/voidnet-tor-%s-%06x" netns (Random.int 0xFFFFFF) in
    (try
       Unix.mkdir temp_base 0o777;
       Unix.chmod temp_base 0o777
     with _ -> ());

    (* Switch 終了時に確実に痕跡を消滅させる *)
    Switch.on_release sw (fun () ->
      traceln "[Jail][Tor] Cleaning up ephemeral resources for %s..." netns;
      rm_rf temp_base;
      ignore (Sys.command (Printf.sprintf "rm -rf %s 2>/dev/null || true" (Filename.quote temp_base)));
      ignore (Sys.command (Printf.sprintf "pkill -9 -f 'tor.*%s' 2>/dev/null || true" netns))
    );

    let bind_data = Printf.sprintf "%s:/var/lib/tor:rw" temp_base in
    let args = build_jail_cmd_args ~netns ~lib_dir ~binds:[bind_data] ~exec_path:tor_bin
      [
        "--SocksPort"; Printf.sprintf "0.0.0.0:%d" socks_port;
        "--DataDirectory"; "/var/lib/tor";
        "--AvoidDiskWrites"; "1";
      ]
    in

    traceln "[Jail][Tor] Spawning Tor inside %s on port %d..." netns socks_port;
    Fiber.fork ~sw (fun () ->
      try
        Eio.Process.run proc_mgr args
      with
      | Eio.Cancel.Cancelled _ ->
        traceln "[Jail][Tor] Tor inside %s stopped." netns
      | exn ->
        traceln "[Jail][Tor][WARN] Tor exited: %s" (Printexc.to_string exn)
    )

let spawn_openvpn ~sw ~proc_mgr:_ ~netns ~lib_dir:_ ~config_file ~auth_file () =
  match find_binary "openvpn" with
  | None -> failwith "'openvpn' binary not found"
  | Some ovpn_bin ->
    let log_file = Printf.sprintf "/tmp/ovpn-%s.log" netns in
    let pid_file = Printf.sprintf "/run/ovpn-%s.pid" netns in

    let abs_config_file =
      if Filename.is_relative config_file then
        Filename.concat (Sys.getcwd ()) config_file
      else
        config_file
    in
    let conf_dir = Filename.dirname abs_config_file in
    let conf_basename = Filename.basename abs_config_file in
    let auth_path = Option.value auth_file ~default:"/etc/openvpn/client/proton-auth.txt" in

    let args = [
      "ip"; "netns"; "exec"; netns;
      ovpn_bin;
      "--cd"; conf_dir;
      "--config"; conf_basename;
      "--auth-user-pass"; auth_path;
      "--writepid"; pid_file;
      "--disable-dco";
      "--script-security"; "2";
      "--log"; log_file;
      "--daemon"; Printf.sprintf "ovpn-%s" netns;
    ] in

    traceln "[Jail][OpenVPN] Spawning OpenVPN in %s (config: %s)..." netns conf_basename;
    let cmd = String.concat " " (List.map Filename.quote args) in
    let ret = Sys.command cmd in
    if ret <> 0 then
      failwith (Printf.sprintf "Failed to start OpenVPN in %s (code %d)" netns ret);

    (* リソース破棄フック *)
    Switch.on_release sw (fun () ->
      traceln "[Jail][OpenVPN] Cleaning up OpenVPN resources for %s..." netns;
      (if Sys.file_exists pid_file then
         let pid_str =
           try In_channel.with_open_text pid_file In_channel.input_all |> String.trim
           with _ -> ""
         in
         if pid_str <> "" then
           ignore (Sys.command (Printf.sprintf "kill -9 %s 2>/dev/null || true" pid_str));
         try Sys.remove pid_file with _ -> ());
      (if Sys.file_exists log_file then
         try Sys.remove log_file with _ -> ());
      ignore (Sys.command (Printf.sprintf "pkill -9 -f 'openvpn.*%s' 2>/dev/null || true" netns))
    );

    let rec wait_connected count =
      if count <= 0 then
        failwith (Printf.sprintf "OpenVPN connection timeout in %s (check %s)" netns log_file);
      Eio_unix.sleep 1.0;
      if Sys.file_exists log_file then
        let content =
          try In_channel.with_open_text log_file In_channel.input_all
          with _ -> ""
        in
        if String.length content > 0 &&
           (try ignore (Str.search_forward (Str.regexp_string "Initialization Sequence Completed") content 0); true
            with Not_found -> false) then
          traceln "[Jail][OpenVPN] Initialization Sequence Completed for %s." netns
        else
          wait_connected (count - 1)
      else
        wait_connected (count - 1)
    in
    wait_connected 30
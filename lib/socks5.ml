(* lib/socks5.ml *)
open Eio.Std

type socks_target =
  | IPv4 of string * int
  | Domain of string * int

(* SOCKS5 ハンドシェイク・CONNECT リクエストの解析 *)
let handshake client_flow =
  let r = Eio.Buf_read.of_flow ~max_size:4096 client_flow in
  let ver = Eio.Buf_read.uint8 r in
  if ver <> 5 then failwith (Printf.sprintf "Unsupported SOCKS version: %d" ver);

  let nmethods = Eio.Buf_read.uint8 r in
  let _methods = Eio.Buf_read.take nmethods r in

  (* 認証なし (0x05 0x00) を応答 *)
  Eio.Flow.write client_flow [ Cstruct.of_string "\x05\x00" ];

  (* CONNECT リクエストの読み取り *)
  let ver = Eio.Buf_read.uint8 r in
  let cmd = Eio.Buf_read.uint8 r in
  let _rsv = Eio.Buf_read.uint8 r in
  let atyp = Eio.Buf_read.uint8 r in

  if ver <> 5 || cmd <> 1 then
    failwith (Printf.sprintf "Unsupported command or version: ver=%d, cmd=%d" ver cmd);

  let target =
    match atyp with
    | 1 -> (* IPv4 *)
      let ip_bytes = Eio.Buf_read.take 4 r in
      let ip_str = Printf.sprintf "%d.%d.%d.%d"
        (Char.code ip_bytes.[0]) (Char.code ip_bytes.[1])
        (Char.code ip_bytes.[2]) (Char.code ip_bytes.[3]) in
      let port = Eio.Buf_read.BE.uint16 r in
      IPv4 (ip_str, port)
    | 3 -> (* ドメイン名 *)
      let len = Eio.Buf_read.uint8 r in
      let domain = Eio.Buf_read.take len r in
      let port = Eio.Buf_read.BE.uint16 r in
      Domain (domain, port)
    | 4 -> failwith "IPv6 not supported"
    | _ -> failwith (Printf.sprintf "Unknown atyp: %d" atyp)
  in
  target

let reply_success client_flow =
  let resp = "\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00" in
  Eio.Flow.write client_flow [ Cstruct.of_string resp ]

let reply_failure client_flow =
  let resp = "\x05\x01\x00\x01\x00\x00\x00\x00\x00\x00" in
  try Eio.Flow.write client_flow [ Cstruct.of_string resp ] with _ -> ()

(* socat を netns 内で起動し、Eio の Flow と接続 *)
let forward_socat ~sw ~proc_mgr ~netns ~target client_flow =
  let host_str, port =
    match target with
    | IPv4 (ip, p) -> (ip, p)
    | Domain (d, p) -> (d, p)
  in
  let socat_target = Printf.sprintf "TCP:%s:%d" host_str port in
  let args = [
    "ip"; "netns"; "exec"; netns;
    "socat"; "-"; socat_target
  ] in

  let from_client_r, from_client_w = Eio.Process.pipe proc_mgr ~sw in
  let to_client_r, to_client_w = Eio.Process.pipe proc_mgr ~sw in

  let proc =
    Eio.Process.spawn proc_mgr ~sw
      ~stdin:from_client_r
      ~stdout:to_client_w
      args
  in

  (* コネクション用の Switch が解放される際、socat が生きていれば確実に終了させる *)
  Switch.on_release sw (fun () ->
    (try Eio.Process.signal proc Sys.sigkill with _ -> ());
    (try Eio.Flow.close from_client_w with _ -> ());
    (try Eio.Flow.close to_client_r with _ -> ())
  );

  (* クライアントへ接続成功を返信 *)
  reply_success client_flow;

  (* 双方向のストリームコピー *)
  Fiber.both
    (fun () ->
      (try Eio.Flow.copy client_flow from_client_w with _ -> ());
      (try Eio.Flow.close from_client_w with _ -> ()))
    (fun () ->
      (try Eio.Flow.copy to_client_r client_flow with _ -> ());
      (try Eio.Flow.close to_client_r with _ -> ());
      (try Eio.Flow.close client_flow with _ -> ()));

  (* プロセスの終了ステータス回収 *)
  ignore (Eio.Process.await proc)
(* Tor 向けの raw パススルーフォワーダ *)
let forward_raw ~net ~target client_flow =
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
  in
  let ip = parse_ipv4 target.Balancer.ip in
  let addr = `Tcp (ip, target.Balancer.port) in
  try
    Switch.run @@ fun conn_sw ->
    let target_flow = Eio.Net.connect ~sw:conn_sw net addr in
    Fiber.both
      (fun () ->
        (try Eio.Flow.copy client_flow target_flow with _ -> ());
        Switch.fail conn_sw Exit)
      (fun () ->
        (try Eio.Flow.copy target_flow client_flow with _ -> ());
        Switch.fail conn_sw Exit)
  with
  | Exit -> ()
  | exn ->
    traceln "[Socks5][WARN] Backend error (%s:%d): %s"
      target.Balancer.ip target.Balancer.port (Printexc.to_string exn)

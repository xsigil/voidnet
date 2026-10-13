type jail_spec = {
  lib_path : string;
} [@@deriving yaml]

type service_spec = {
  name : string;
  service_type : string; [@key "type"]
  target_port : int;
  virtual_port : int;
  key_dir : string option; [@default None]
} [@@deriving yaml]

(* lib/config.ml *)
type tunnel_spec = {
  id : string;
  tunnel_type : string; [@key "type"]
  config : string option; [@default None]
  auth_file : string option; [@default None]
  subnet : string;
  dns : string option; [@default None]
  client_ip : string option; [@default None]
  socks_port : int option; [@default None]
  services : service_spec list; [@default []]
  jail : jail_spec option; [@default None]
} [@@deriving yaml]

type listener_spec = {
  bind : string;
  strategy : string;
  pool : string list;
} [@@deriving yaml]

type t = {
  version : string;
  tunnels : tunnel_spec list;
  listeners : listener_spec list;
} [@@deriving yaml]

let load_file path =
  let content = In_channel.with_open_text path In_channel.input_all in
  match Yaml.of_string content with
  | Error (`Msg err) -> failwith ("YAML parse error: " ^ err)
  | Ok yaml_value ->
    match of_yaml yaml_value with
    | Error (`Msg err) -> failwith ("Config decode error: " ^ err)
    | Ok conf -> conf

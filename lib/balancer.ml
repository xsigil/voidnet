type target = {
  ip : string;
  port : int;
}

type t = {
  targets : target array;
  counter : int ref;
}

let create targets =
  if List.length targets = 0 then failwith "Balancer pool cannot be empty";
  {
    targets = Array.of_list targets;
    counter = ref 0;
  }

let next t =
  let idx = !(t.counter) mod Array.length t.targets in
  t.counter := !(t.counter) + 1;
  t.targets.(idx)
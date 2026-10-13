(lang dune 3.14)
(name voidnet)
(version 0.1.0)
(generate_opam_files true)

(package
 (name voidnet)
 (synopsis "Declarative multi-tunnel network orchestrator")
 (depends
  (ocaml (>= 5.0.0))
  dune
  eio
  eio_main
  yaml
  ppx_deriving_yaml))

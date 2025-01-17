open Base
open Sexplib.Std

type value =
	| Const of int
	| Ref of int
[@@deriving compare, sexp]

type instruction =
	| Return of value
	| Add of int * value * value
[@@deriving compare, sexp]

module Rust = struct
	external parse: string -> (instruction list, string) Result.t = "rust_parse"
	external parse_file: string -> (instruction list, string) Result.t = "rust_parse_file"
	external parse_file_and_emit: string -> (instruction list, string) Result.t = "rust_parse_file_and_emit"
end

open Constrexpr

let raw_ref s = CRef (Libnames.qualid_of_string s, None)
let mkRef s = CAst.make (raw_ref s)
let num n = (CAst.make (CPrim (Number (NumTok.Signed.of_string (Int.to_string n)))), None)
let mkNum s n = CApp (mkRef s, [num n])

let coq_of_value (v: value): constr_expr_r CAst.t = CAst.make (match v with
	| Const n -> mkNum "Const" n
	| Ref r -> mkNum "Ref" r
)

let coq_of_instruction (i: instruction): constr_expr_r CAst.t = CAst.make (match i with
	| Return v -> CApp (mkRef "Return", [coq_of_value v, None])
	| Add (r, op1, op2) -> CApp (mkRef "Add", [num r; coq_of_value op1, None; coq_of_value op2, None])
)

let rec coq_of_instructions (is: instruction list): constr_expr_r CAst.t = CAst.make (match is with
	| x :: xs -> CApp (mkRef "cons", [coq_of_instruction x, None; coq_of_instructions xs, None])
	| [] -> raw_ref "nil"
)

let declare_definition ~poly name env sigma expr =
	let (sigma, body) = Constrintern.interp_constr_evars env sigma expr in
	let udecl = UState.default_univ_decl in
	let scope = Locality.Global Locality.ImportDefaultBehavior in
	let kind = Decls.(IsDefinition Definition) in
	let cinfo = Declare.CInfo.make ~name ~typ:None () in
	let info = Declare.Info.make ~scope ~kind  ~udecl ~poly () in
	Declare.declare_definition ~info ~cinfo ~opaque:false ~body sigma

open Pp

let declare_magmide ~poly fn filename name =
	let expr = coq_of_instructions (Result.ok_or_failwith (fn filename)) in
	let env = Global.env () in
	let sigma = Evd.from_env env in
	let r = declare_definition ~poly name env sigma expr in
	Feedback.msg_notice (strbrk "Magmide defined " ++ Printer.pr_global r ++ strbrk ".")

let%test_unit "parse noop" =
	[%test_eq: (instruction list, string) Result.t ] (Rust.parse "") (Ok [])
let%test_unit "parse return" =
	[%test_eq: (instruction list, string) Result.t ] (Rust.parse "return 4") (Ok [Return (Const 4)])
let%test_unit "parse return ref" =
	[%test_eq: (instruction list, string) Result.t ] (Rust.parse "return %4") (Ok [Return (Ref 4)])
let%test_unit "parse add" =
	[%test_eq: (instruction list, string) Result.t ] (Rust.parse "%0 = 1 + 1") (Ok [Add (0, Const(1), Const(1))])
let%test_unit "parse prog" =
	[%test_eq: (instruction list, string) Result.t ]
		(Rust.parse "%0 = 1 + 1\n%1 = %0 + %0\nreturn %1")
		(Ok [Add (0, (Const 1), (Const 1)); Add (1, Ref(0), Ref(0)); Return (Ref 1)])

open Stdppx
open Ppx_ast.V4_07

(** Generates functions akin to `View.tuple{2,3,4}` for arbitrary order *)
let inline_tuple_function ~loc n =
  let view idx = Printf.sprintf "view%d" idx in
  let value idx = Printf.sprintf "value%d" idx in
  let component idx =
    let view_idx = Builder.lident_loc ~loc (view idx) in
    let value_idx = Builder.Exp.lident ~loc (value idx) in
    Builder.Exp.apply_lident ~loc (view_idx) [value_idx]
  in
  let rec body idx =
    if idx >= n then
      component idx
    else
      let chain = Builder.view_lib_ident ~loc ">>+" in
      Builder.Exp.apply_lident ~loc chain [component idx; body (idx + 1)]
  in
  let rec values acc idx =
    if idx <= 0 then
      acc
    else
      values (Builder.Pat.var ~loc (value idx)::acc) (idx - 1)
  in
  let values_tuple =
    Builder.pattern ~loc (Pattern_desc.ppat_tuple (values [] n))
  in
  let res =
    Builder.expression ~loc
      (Expression_desc.pexp_fun Arg_label.nolabel None values_tuple (body 1))
  in
  let rec fun_ idx =
    if idx > n then
      res
    else
      Builder.expression ~loc
        (Expression_desc.pexp_fun
           Arg_label.nolabel
           None
           (Builder.Pat.var ~loc (view idx))
           (fun_ (idx + 1)))
  in
  fun_ 1

let predefined_ident ~loc = function
  | "Some" -> Some (Builder.view_lib_ident ~loc "some")
  | "None" -> Some (Builder.view_lib_ident ~loc "none")
  | "::" -> Some (Builder.view_lib_ident ~loc "cons")
  | "[]" -> Some (Builder.view_lib_ident ~loc "nil")
  | "()" -> Some (Builder.view_lib_ident ~loc "unit")
  | "true" -> Some (Builder.view_lib_ident ~loc "true_")
  | "false" -> Some (Builder.view_lib_ident ~loc "false_")
  | "Not" -> Some (Builder.view_lib_ident ~loc "not")
  | _ -> None

let translate_ctor_ident ~loc (ident : Longident.concrete) =
  match ident with
  | Lident s ->
    (match predefined_ident ~loc s with
     | Some ident -> ident
     | None -> Builder.lident_loc ~loc (String.uncapitalize_ascii s))
  | Ldot (li, s) ->
    Builder.longident_loc ~loc (Longident.ldot li (String.uncapitalize_ascii s))
  | (Lapply _) as li ->
    Builder.longident_loc ~loc (Longident.of_concrete li)

let translate_constant ~loc constant =
  let make name =
    let f = Builder.view_lib_ident ~loc name in
    Builder.Exp.apply_lident ~loc f
      [Builder.expression ~loc (Expression_desc.pexp_constant constant)]
  in
  match Constant.to_concrete constant with
  | None -> Error.conversion_failed ~loc "constant"
  | Some (Pconst_integer (_, None)) -> make "int"
  | Some (Pconst_integer (_, Some 'l')) -> make "int32"
  | Some (Pconst_integer (_, Some 'L')) -> make "nativeint"
  | Some (Pconst_char _) -> make "char"
  | Some (Pconst_string _) -> make "string"
  | Some (Pconst_float (_, None)) -> make "float"
  | Some (Pconst_integer (_, Some suffix)) ->
    Error.unsupported_num_const ~loc ~kind:"int" ~suffix
  | Some (Pconst_float (_, Some suffix)) ->
    Error.unsupported_num_const ~loc ~kind:"float" ~suffix

let same_variables ~err_loc vl vl' =
  List.for_all2 vl vl'
    ~f:(fun v v' ->
      let (_, desc) = Deconstructor.pattern ~loc:err_loc v in
      let (_, desc') = Deconstructor.pattern ~loc:err_loc v' in
      match desc, desc' with
      | Ppat_var loc_name, Ppat_var loc_name' ->
        let name = Astlib.Loc.txt loc_name in
        let name' = Astlib.Loc.txt loc_name' in
        name = name'
      | _ -> false)

let apply_attr_field_fun field expr =
  let {View_attr.label; label_loc; var_loc; _} = field in
  let f = Builder.lident_loc ~loc:label_loc (label ^ "'field") in
  let capture_arg = Builder.Exp.view_lib_capture ~loc:var_loc in
  Builder.Exp.apply_lident ~loc:label_loc f [capture_arg; expr]

let add_attr_field_var field vars =
  let {View_attr.var; var_loc; _} = field in
  let var_pat = Builder.Pat.var ~loc:var_loc var in
  var_pat::vars

let rec translate_pattern ~err_loc pattern =
  match Pattern.to_concrete pattern with
  | None -> Error.conversion_failed ~loc:err_loc "pattern"
  | Some {ppat_desc; ppat_loc; ppat_attributes} ->
    let loc = ppat_loc in
    let fields = View_attr.extract_fields ~err_loc ppat_attributes in
    match fields with
    | None -> translate_pattern_desc ~loc ppat_desc
    | Some fields ->
      let expr, vars = translate_pattern_desc ~loc ppat_desc in
      List.fold_right fields
        ~init:(expr, vars)
        ~f:(fun field (acc_expr, acc_vars) ->
          let acc_expr = apply_attr_field_fun field acc_expr in
          let acc_vars = add_attr_field_var field acc_vars in
          (acc_expr, acc_vars))

and translate_pattern_desc ~loc desc =
  match Pattern_desc.to_concrete desc with
  | None ->
    Error.conversion_failed ~loc "pattern_desc"
  | Some Ppat_any ->
    ( Builder.Exp.view_lib_drop ~loc
    , [] )
  | Some (Ppat_var _) ->
    ( Builder.Exp.view_lib_capture ~loc
    , [Builder.pattern ~loc desc] )
  | Some (Ppat_alias (patt, alias)) ->
    let expr, vars = translate_pattern ~err_loc:loc patt in
    let alias_var = Builder.pattern ~loc (Pattern_desc.ppat_var alias) in
    ( Builder.Exp.view_lib_sequence ~loc
        [Builder.Exp.view_lib_capture ~loc; expr]
    , alias_var :: vars )
  | Some (Ppat_constant c) ->
    ( translate_constant ~loc c
    , [] )
  | Some (Ppat_interval (lower, upper)) ->
    let f = Builder.view_lib_interval ~loc in
    let args = [translate_constant ~loc lower; translate_constant ~loc upper] in
    ( Builder.Exp.apply_lident ~loc f args
    , [] )
  | Some (Ppat_tuple patts) ->
    translate_tuple ~loc patts
  | Some (Ppat_construct (ctor_ident, None)) ->
    let ctor_loc, ctor_ident = Deconstructor.longident_loc ~loc ctor_ident in
    let f = translate_ctor_ident ~loc:ctor_loc ctor_ident in
    ( Builder.expression ~loc (Expression_desc.pexp_ident f)
    , [] )
  | Some (Ppat_construct (ctor_ident, Some patt)) ->
    let ctor_loc, ctor_ident = Deconstructor.longident_loc ~loc ctor_ident in
    let f = translate_ctor_ident ~loc:ctor_loc ctor_ident in
    let apply args = Builder.Exp.apply_lident ~loc f args in
    (match Deconstructor.pattern ~loc patt with
     | (ploc, Ppat_tuple [hd; tl]) when ctor_ident = Lident "::" ->
       let expr_hd, vars_hd = translate_pattern ~err_loc:ploc hd in
       let expr_tl, vars_tl = translate_pattern ~err_loc:ploc tl in
       ( apply [expr_hd; expr_tl]
       , vars_hd @ vars_tl )
     | (ploc, Ppat_tuple patts) ->
       (* why is this needed? *)
       let expr, vars = translate_tuple ~loc:ploc patts in
       ( apply [expr]
       , vars )
     | _ ->
       let expr, vars = translate_pattern ~err_loc:loc patt in
       ( apply [expr]
       , vars ))
  | Some (Ppat_or (first, second)) ->
    let expr_first, vars_first = translate_pattern ~err_loc:loc first in
    let expr_second, vars_second = translate_pattern ~err_loc:loc second in
    if same_variables ~err_loc:loc vars_first vars_second then
      let f = Builder.view_lib_choice ~loc in
      ( Builder.Exp.apply_lident ~loc f [expr_first; expr_second]
      , vars_first )
    else
      Error.or_pattern_variables_differ ~loc
  | Some (Ppat_record (fields, _closed)) ->
    let exprs_vars = List.map ~f:(translate_record_field ~loc) fields in
    let exprs, vars = List.split exprs_vars in
    ( Builder.Exp.view_lib_sequence ~loc exprs
    , List.flatten vars )
  | Some (Ppat_array patts) ->
    translate_array ~loc patts
  | Some (Ppat_constraint (patt, ctyp)) ->
    let expr, vars = translate_pattern ~err_loc:loc patt in
    ( Builder.expression ~loc (Expression_desc.pexp_constraint expr ctyp)
    , vars )
  | Some (Ppat_open (lid, patt)) ->
    let expr, vars = translate_pattern ~err_loc:loc patt in
    ( Builder.expression ~loc
        (Expression_desc.pexp_open Override_flag.override lid expr)
    , vars )
  | Some (Ppat_variant _) ->
    Error.unsupported_pattern ~loc "polymorphic variants"
  | Some (Ppat_type _) ->
    Error.unsupported_pattern ~loc "sub types"
  | Some (Ppat_lazy _) ->
    Error.unsupported_pattern ~loc "lazy values"
  | Some (Ppat_unpack _) ->
    Error.unsupported_pattern ~loc "first class modules"
  | Some (Ppat_exception _) ->
    Error.unsupported_pattern ~loc "exceptions"
  | Some (Ppat_extension _) ->
    Error.unsupported_pattern ~loc "extension points"

and translate_patterns ~err_loc patts =
  let exprs, vars =
    List.split (List.map ~f:(translate_pattern ~err_loc) patts)
  in
  (exprs, List.flatten vars)

and translate_tuple ~loc patts =
  let exprs, vars = translate_patterns ~err_loc:loc patts in
  match List.length exprs with
  | (2 | 3 | 4) as len ->
    let f =  Builder.view_lib_ident ~loc (Printf.sprintf "tuple%d" len) in
    ( Builder.Exp.apply_lident ~loc f exprs
    , vars )
  | len ->
    assert (len > 4);
    let f = inline_tuple_function ~loc len in
    ( Builder.Exp.apply ~loc f exprs
    , vars )

and translate_record_field ~loc (label, patt) =
  let (label_loc, label) = Deconstructor.longident_loc ~loc label in
  match label with
  | Lident label ->
    let expr, vars = translate_pattern ~err_loc:label_loc patt in
    let f = Builder.lident_loc ~loc:label_loc (label ^ "'match") in
    ( Builder.Exp.apply_lident ~loc:label_loc f [expr]
    , vars )
  | _ ->
    Error.invalid_record_field ~loc:label_loc

and translate_array ~loc patts =
  match patts with
  | [] ->
    ( Builder.Exp.view_lib_larray_nil ~loc
    , [] )
  | hd :: tl ->
    let expr_hd, vars_hd = translate_pattern ~err_loc:loc hd in
    let expr_tl, vars_tl = translate_array ~loc tl in
    let f = Builder.view_lib_larray_cons ~loc in
    ( Builder.Exp.apply_lident ~loc f [expr_hd; expr_tl]
    , vars_hd @ vars_tl )

let translate_case_body ~loc ~vars ~pc_guard ~pc_rhs =
  let vars_cons_pattern =
    List.fold_left vars
      ~init:(Builder.Pat.view_lib_var_nil ~loc)
      ~f:(Builder.Pat.view_lib_var_snoc ~loc)
  in
  match pc_guard with
  | Some _ ->
    let guarded_case =
      Case.create ~pc_lhs:vars_cons_pattern ~pc_guard ~pc_rhs
    in
    let guard_failed_case =
      let pc_lhs = Builder.pattern ~loc Pattern_desc.ppat_any in
      let pc_rhs =
        let f = Builder.view_lib_ident ~loc "guard_failed" in
        Builder.Exp.(apply_lident ~loc f [unit ~loc])
      in
      Case.create ~pc_lhs ~pc_guard:None ~pc_rhs
    in
    Builder.expression ~loc
      (Expression_desc.pexp_function [guarded_case; guard_failed_case])
  | None ->
    Builder.expression ~loc
      (Expression_desc.pexp_fun Arg_label.nolabel None vars_cons_pattern pc_rhs)

let translate_case ~loc ~err_loc match_case =
  match Case.to_concrete match_case with
  | None -> Error.conversion_failed ~loc:err_loc "case"
  | Some {pc_lhs; pc_guard; pc_rhs} ->
    let pattern, vars = translate_pattern ~err_loc pc_lhs in
    let body = translate_case_body ~loc ~vars ~pc_guard ~pc_rhs in
    let f = Builder.view_lib_ident ~loc "case" in
    Builder.Exp.apply_lident ~loc f [pattern; body]

let pos_argument loc =
  let start = Astlib.Location.start loc in
  let bol = Astlib.Position.bol start in
  let lnum = Astlib.Position.lnum start in
  let cnum = Astlib.Position.cnum start in
  let fname = Astlib.Position.fname start in
  let string x =
    Builder.expression ~loc
      (Expression_desc.pexp_constant (Constant.pconst_string x None))
  in
  let int x =
    Builder.expression ~loc
      (Expression_desc.pexp_constant (Constant.pconst_integer (string_of_int x) None))
  in
  Builder.expression ~loc
    (Expression_desc.pexp_tuple [string fname; int lnum; int (cnum - bol)])

let translate_match ~loc ~err_loc ?match_expr match_cases =
  let pos = pos_argument loc in
  let cases = List.map match_cases ~f:(translate_case ~err_loc ~loc) in
  let cases_arg = Builder.Exp.list_lit ~loc cases in
  let args =
    match match_expr with
    | Some expr -> [pos; cases_arg; expr]
    | None -> [pos; cases_arg]
  in
  let f_ident = Builder.view_lib_ident ~loc "match_" in
  Builder.Exp.apply_lident ~loc f_ident args

let payload ~loc payload_expr =
  let pexp_loc, pexp_desc = Deconstructor.expression ~loc payload_expr in
  match pexp_desc with
  | Pexp_match (match_expr, match_cases) ->
    translate_match ~loc ~err_loc:pexp_loc ~match_expr match_cases
  | Pexp_function match_cases ->
    translate_match ~loc ~err_loc:pexp_loc match_cases
  | _ ->
    Error.invalid_payload ~loc:pexp_loc

let parsetree_payload ~loc payload_expr =
  let loc = Astlib.Location.of_location loc in
  let astlib_payload_expr = Ppx_ast.Conversion.ast_of_expression payload_expr in
  let expanded = payload ~loc astlib_payload_expr in
  Ppx_ast.Conversion.ast_to_expression expanded

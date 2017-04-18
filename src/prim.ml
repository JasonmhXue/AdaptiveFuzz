(* file name: prim.ml
   created by: Daniel Winograd-Cort
   Last modified: 12/20/2015
   
   Description:
   This file contains code for interpreting SFuzz primitives.
*)

open Types
open Syntax
open Interpreter.InterpMonad
open Support.FileInfo
open Print

(* We create a few helper functions for simplifying the creation of 
   primitive functions.  The main components are the functions fun_of_1arg,
   fun_of_2args, etc. which make creating k-argument primitives easy.  
   There are also versions of these appended with _i or _type (or both)
   that allow the result to be in the interpreter monad or that allow
   the output type to be given as an argument respectively.  
   These functions require function arguments for extracting values from 
   terms as well as constructing terms from values.  Thus, we also provide 
   a few common extractors and makers in the forms of ex**** and mk**** 
   respectively.  That is, for example, exBool is a function for extracting 
   a boolean value from a term and mkInt is for turning an integer value 
   into a term.  For polymorphic functions that can work on terms directly 
   (e.g. equality, etc.), we provide exAny and mkAny, which are basically 
   identity functions.
   
   There are also some special purpose functions for dealing with the more 
   interesting primitives (the real fuzzy stuff).
   
   Finally, the main (only) export of this module is the list of primitives 
   itself.
*)

let rzFileName = ref "redZoneTemp"
let pinterpLimit = ref 50
let useCompiler = ref true


let di = dummyinfo

module Creation = struct
  
  type ('a,'b) either = | Left  of 'a
                        | Right of 'b
  
  (* The expectation functions take a term and return an ocaml value *)
  let exBool name tb = match tb with 
    | TmPrim (_i, PrimTBool b) -> return b
    | _ -> fail_pp "** Primitive ** %s expected a bool but found %a" name pp_term tb
  let exToken name tt = match tt with 
    | TmPrim (_i, PrimTToken(n,ty)) -> return (n,ty)
    | _ -> fail_pp "** Primitive ** %s expected a token but found %a" name pp_term tt
  let exNum name tn = match tn with 
    | TmPrim (_i, PrimTNum n) -> return n
    | TmPrim (_i, PrimTInt n) -> return (float_of_int n)
    | TmPrim (_i, PrimTClipped n) -> return n
    | _ -> fail_pp "** Primitive ** %s expected a num but found %a" name pp_term tn
  let exInt name tn = match tn with 
    | TmPrim (_i, PrimTInt n) -> return n
    | _ -> fail_pp "** Primitive ** %s expected an int but found %a" name pp_term tn
  let exString name ts = match ts with 
    | TmPrim (_i, PrimTString s) -> return s
    | _ -> fail_pp "** Primitive ** %s expected a string but found %a" name pp_term ts
  let exBag name tb = match tb with 
    | TmBag(_i, _ty, tlst) -> return tlst
    | _ -> fail_pp "** Primitive ** %s expected a bag but found %a" name pp_term tb
  let exVector name tb = match tb with 
    | TmVector(_i, _ty, tlst) -> return tlst
    | _ -> fail_pp "** Primitive ** %s expected a vector but found %a" name pp_term tb
  let exPair ex1 ex2 name tp = match tp with 
    | TmPair(_i, t1, t2) -> ex1 name t1 >>= fun v1 ->
                            ex2 name t2 >>= fun v2 ->
                            return (v1, v2)
    | _ -> fail_pp "** Primitive ** %s expected a pair but found %a" name pp_term tp
  let exAmp ex1 ex2 name tp = match tp with 
    | TmAmpersand(i, t1, t2) -> ex1 name t1 >>= fun v1 ->
                                ex2 name t2 >>= fun v2 ->
                                return (v1, v2)
    | _ -> fail_pp "** Primitive ** %s expected a &-pair but found %a" name pp_term tp
  let rec exList exA name tl = match tl with
    | TmFold(_i, _, TmLeft(_,tm,_)) -> return []
    | TmFold(_i, _, TmRight(_,TmPair(_, tx, txs),_)) ->
        exA name tx >>= fun vx ->
        exList exA name txs >>= fun vxs ->
        return (vx :: vxs)
    | _ -> fail_pp "** Primitive ** %s expected a list but found %a" name pp_term tl
  let exFun _name t = return t (* Theoretically, we could check that it's actually a function, but we don't need to *)
  let exAny _name t = return t
  
  (* The make functions turn an ocaml value into a term *)
  let mkBool i b   = TmPrim (i, PrimTBool b)
  let mkNum i n    = TmPrim (i, PrimTNum n)
  let mkClipped i c = TmPrim (i, PrimTClipped (if c > 1.0 then 1.0 else if c < 0.0 then 0.0 else c))
  let mkInt i n    = TmPrim (i, PrimTInt n)
  let mkString i s = TmPrim (i, PrimTString s)
  let mkBag i (ty, l) = TmBag (i, ty, l)
  let mkVector i (ty, l) = TmVector (i, ty, l)
  let mkToken i (n,ty)  = TmPrim (i, PrimTToken (n,ty))
  let mkPair mk1 mk2 i (t1, t2) = TmPair (i, mk1 i t1, mk2 i t2)
  let mkSum mkl mkr i (tyl, tyr, x) = match x with
    | Left l  -> TmLeft (i, mkl i l, tyr)
    | Right r -> TmRight(i, mkr i r, tyl)
  let mkPVal mk i t  = TmPVal (i, mk i t)
  let mkAny _i t   = t
  let mkUnit i _   = TmPrim (i, PrimTUnit)

  let rec mkList mkA i (ty, lst) = 
    let lsttype = TyMu({b_name = "XX"; b_type = BiTyVar; b_size = -1; b_prim = false;}, TyUnion
            (TyPrim PrimUnit, TyTensor(ty, TyVar
                ({v_index = 0; v_name = "XX"; v_size = -1; v_type = BiTyVar;})))) in
    match lst with
    | [] -> TmFold(i, lsttype, TmLeft(i, TmPrim(i, PrimTUnit), TyTensor(ty, lsttype)))
    | x::xs -> TmFold(i, lsttype, TmRight(i, TmPair(i, mkA i x, mkList mkA i (ty, xs)), TyPrim PrimUnit))
  
  (* thunkify is a special function whose purpose is to wrap around a primitive function and prevent
     it from being evaluated too soon.  Essentially, it helps enforce that probabilistic values, which
     should only be evaluated when absolutely necessary, are properly lazy.  In practice, it works by
     immediately returning a PVal, which is a lazy thunk, and sending all of the argument data to a new
     primitive function given by the argument. *)
  let thunkify
    (name : string)
    (newprimName : string)
    (newprimFun : primfun)
    : primfun = 
    PrimFun (fun t -> match t with
    | TmPrimFun(i, _, _, ty, ttslst) -> return (mkPVal mkAny di (TmPrimFun(i, newprimName, newprimFun, ty, ttslst)))
    | _ -> fail_pp "** Primitive Internal ** %s expected a TmPrimFun but was given: %a" name pp_term t)
  
  (* The extractArgs function extracts the term list and output type from the given TmPrimFun argument.  This
     is used repeatedly in the fun_of_*args functions below. *)
  let extractArgs
    (name : string)
    (t : term)
    : (ty * term list) interpreter =
    match t with
    | TmPrimFun(i, s, _, ty, ttslst) -> return (ty, List.map (fun (tm,_,_) -> tm) ttslst)
    | _ -> fail_pp "** Primitive Internal ** %s expected a TmPrimFun but was given: %a" name pp_term t
  
  (* The fun_of_*_arg* functions are short hands for making the primitives easily. *)
  (* -- "_with_type" indicates it accepts information about the output type. *)
  (* -- "_i" indicates that the operator's output is in the interpreter monad. *)
  let fun_of_no_args_with_type_i
    (name : string)                           (* The name of the function - for debug purposes *)
    (mk : info -> 'a -> term)                 (* A maker for the result *)
    (op : ty -> 'a interpreter)               (* The operation to perform *)
    : primfun = 
    PrimFun (fun t -> extractArgs name t >>= fun (ty, tlst) -> match tlst with
      | [] -> op ty >>= fun res -> return (mk di res)
      | _  -> fail_pp "** Primitive ** %s expected no arguments but found %a" name (pp_list pp_term) tlst)
  
  let fun_of_1arg_with_type_i
    (name : string)                           (* The name of the function - for debug purposes *)
    (earg : string -> term -> 'a interpreter) (* An extractor for the argument *)
    (mk : info -> 'b -> term)                 (* A maker for the result *)
    (op : ty -> 'a -> 'b interpreter)         (* The operation to perform *)
    : primfun = 
    PrimFun (fun t -> extractArgs name t >>= fun (ty, tlst) -> match tlst with
      | ta :: []
          -> earg name ta >>= fun a ->
             op ty a >>= fun res -> return (mk di res)
      | _ -> fail_pp "** Primitive ** %s expected 1 argument but found %a" name (pp_list pp_term) tlst)
  
  let fun_of_1arg_i
    (name : string)                           (* The name of the function - for debug purposes *)
    (earg : string -> term -> 'a interpreter) (* An extractor for the argument *)
    (mk : info -> 'b -> term)                 (* A maker for the result *)
    (op : 'a -> 'b interpreter)               (* The operation to perform *)
    : primfun = fun_of_1arg_with_type_i name earg mk (fun _ty x -> op x)
  
  let fun_of_1arg
    (name : string)                           (* The name of the function - for debug purposes *)
    (earg : string -> term -> 'a interpreter) (* An extractor for the argument *)
    (mk : info -> 'b -> term)               (* A maker for the result *)
    (op : 'a -> 'b)                           (* The operation to perform *)
    : primfun = fun_of_1arg_with_type_i name earg mk (fun _ty x -> return (op x))
  
  let fun_of_2args_with_type_i_self
    (name : string)                           (* The name of the function - for debug purposes *)
    (efst : string -> term -> 'a interpreter) (* An extractor for the first argument *)
    (esnd : string -> term -> 'b interpreter) (* An extractor for the second argument *)
    (mk : info -> 'c -> term)                 (* A maker for the result *)
    (op : term -> ty -> 'a -> 'b -> 'c interpreter)   (* The operation to perform *)
    : primfun = 
    PrimFun (fun t -> extractArgs name t >>= fun (ty, tlst) -> match tlst with
      | ta :: tb :: []
          -> efst name ta >>= fun a ->
             esnd name tb >>= fun b ->
             op t ty a b >>= fun res -> return (mk di res)
      | _ -> fail_pp "** Primitive ** %s expected 2 arguments but found %a" name (pp_list pp_term) tlst)
  
  let fun_of_2args_with_type_i
    (name : string)                           (* The name of the function - for debug purposes *)
    (efst : string -> term -> 'a interpreter) (* An extractor for the first argument *)
    (esnd : string -> term -> 'b interpreter) (* An extractor for the second argument *)
    (mk : info -> 'c -> term)                 (* A maker for the result *)
    (op : ty -> 'a -> 'b -> 'c interpreter)   (* The operation to perform *)
    : primfun = fun_of_2args_with_type_i_self name efst esnd mk (fun _tm ty x y -> op ty x y)
  
  let fun_of_2args_i
    (name : string)                           (* The name of the function - for debug purposes *)
    (efst : string -> term -> 'a interpreter) (* An extractor for the first argument *)
    (esnd : string -> term -> 'b interpreter) (* An extractor for the second argument *)
    (mk : info -> 'c -> term)                 (* A maker for the result *)
    (op : 'a -> 'b -> 'c interpreter)         (* The operation to perform *)
    : primfun = fun_of_2args_with_type_i name efst esnd mk (fun _ty x y -> op x y)
  
  let fun_of_2args 
    (name : string)                           (* The name of the function - for debug purposes *)
    (efst : string -> term -> 'a interpreter) (* An extractor for the first argument *)
    (esnd : string -> term -> 'b interpreter) (* An extractor for the second argument *)
    (mk : info -> 'c -> term)                 (* A maker for the result *)
    (op : 'a -> 'b -> 'c)                     (* The operation to perform *)
    : primfun = fun_of_2args_with_type_i name efst esnd mk (fun _ty x y -> return (op x y))
  
  let fun_of_3args_with_type_i
    (name : string)                           (* The name of the function - for debug purposes *)
    (efst : string -> term -> 'a interpreter) (* An extractor for the first argument *)
    (esnd : string -> term -> 'b interpreter) (* An extractor for the second argument *)
    (ethd : string -> term -> 'c interpreter) (* An extractor for the third argument *)
    (mk : info -> 'd -> term)                 (* A maker for the result *)
    (op : ty -> 'a -> 'b -> 'c -> 'd interpreter) (* The operation to perform *)
    : primfun = 
    PrimFun (fun t -> extractArgs name t >>= fun (ty, tlst) -> match tlst with
      | ta :: tb :: tc :: []
          -> efst name ta >>= fun a ->
             esnd name tb >>= fun b ->
             ethd name tc >>= fun c ->
             op ty a b c >>= fun res -> return (mk di res)
      | _ -> fail_pp "** Primitive ** %s expected 3 arguments but found %a" name (pp_list pp_term) tlst)
  
  let fun_of_3args_i
    (name : string)                           (* The name of the function - for debug purposes *)
    (efst : string -> term -> 'a interpreter) (* An extractor for the first argument *)
    (esnd : string -> term -> 'b interpreter) (* An extractor for the second argument *)
    (ethd : string -> term -> 'c interpreter) (* An extractor for the third argument *)
    (mk : info -> 'd -> term)                 (* A maker for the result *)
    (op : 'a -> 'b -> 'c -> 'd interpreter)   (* The operation to perform *)
    : primfun = fun_of_3args_with_type_i name efst esnd ethd mk (fun _ty x y z -> op x y z)
  
  let fun_of_3args
    (name : string)                           (* The name of the function - for debug purposes *)
    (efst : string -> term -> 'a interpreter) (* An extractor for the first argument *)
    (esnd : string -> term -> 'b interpreter) (* An extractor for the second argument *)
    (ethd : string -> term -> 'c interpreter) (* An extractor for the third argument *)
    (mk : info -> 'd -> term)                 (* A maker for the result *)
    (op : 'a -> 'b -> 'c -> 'd)               (* The operation to perform *)
    : primfun = fun_of_3args_with_type_i name efst esnd ethd mk (fun _ty x y z -> return (op x y z))
  
  
  let fun_of_4args_with_type_i_self
    (name : string)                           (* The name of the function - for debug purposes *)
    (efst : string -> term -> 'a interpreter) (* An extractor for the first argument *)
    (esnd : string -> term -> 'b interpreter) (* An extractor for the second argument *)
    (ethd : string -> term -> 'c interpreter) (* An extractor for the third argument *)
    (efth : string -> term -> 'd interpreter) (* An extractor for the fourth argument *)
    (mk : info -> 'e -> term)                 (* A maker for the result *)
    (op : term -> ty -> 'a -> 'b -> 'c -> 'd -> 'e interpreter)   (* The operation to perform *)
    : primfun = 
    PrimFun (fun t -> extractArgs name t >>= fun (ty, tlst) -> match tlst with
      | ta :: tb :: tc :: td :: []
          -> efst name ta >>= fun a ->
             esnd name tb >>= fun b ->
             ethd name tc >>= fun c ->
             efth name td >>= fun d ->
             op t ty a b c d >>= fun res -> return (mk di res)
      | _ -> fail_pp "** Primitive ** %s expected 4 arguments but found %a" name (pp_list pp_term) tlst)
  
  let fun_of_4args_with_type_i
    (name : string)                           (* The name of the function - for debug purposes *)
    (efst : string -> term -> 'a interpreter) (* An extractor for the first argument *)
    (esnd : string -> term -> 'b interpreter) (* An extractor for the second argument *)
    (ethd : string -> term -> 'c interpreter) (* An extractor for the third argument *)
    (efth : string -> term -> 'd interpreter) (* An extractor for the fourth argument *)
    (mk : info -> 'e -> term)                 (* A maker for the result *)
    (op : ty -> 'a -> 'b -> 'c -> 'd -> 'e interpreter)   (* The operation to perform *)
    : primfun = fun_of_4args_with_type_i_self name efst esnd ethd efth mk (fun _tm ty a b c d -> op ty a b c d)
  
  let fun_of_4args_i
    (name : string)                           (* The name of the function - for debug purposes *)
    (efst : string -> term -> 'a interpreter) (* An extractor for the first argument *)
    (esnd : string -> term -> 'b interpreter) (* An extractor for the second argument *)
    (ethd : string -> term -> 'c interpreter) (* An extractor for the third argument *)
    (efth : string -> term -> 'd interpreter) (* An extractor for the fourth argument *)
    (mk : info -> 'e -> term)                 (* A maker for the result *)
    (op : 'a -> 'b -> 'c -> 'd -> 'e interpreter) (* The operation to perform *)
    : primfun = fun_of_4args_with_type_i name efst esnd ethd efth mk (fun _ty a b c d -> op a b c d)

  let fun_of_5args_with_type_i
    (name : string)                           (* The name of the function - for debug purposes *)
    (efst : string -> term -> 'a interpreter) (* An extractor for the first argument *)
    (esnd : string -> term -> 'b interpreter) (* An extractor for the second argument *)
    (ethd : string -> term -> 'c interpreter) (* An extractor for the third argument *)
    (efth : string -> term -> 'd interpreter) (* An extractor for the fourth argument *)
    (efft : string -> term -> 'e interpreter) (* An extractor for the fifth argument *)
    (mk : info -> 'f -> term)                 (* A maker for the result *)
    (op : ty -> 'a -> 'b -> 'c -> 'd -> 'e -> 'f interpreter)   (* The operation to perform *)
    : primfun = 
    PrimFun (fun t -> extractArgs name t >>= fun (ty, tlst) -> match tlst with
      | ta :: tb :: tc :: td :: te :: []
          -> efst name ta >>= fun a ->
             esnd name tb >>= fun b ->
             ethd name tc >>= fun c ->
             efth name td >>= fun d ->
             efft name te >>= fun e ->
             op ty a b c d e >>= fun res -> return (mk di res)
      | _ -> fail_pp "** Primitive ** %s expected 5 arguments but found %a" name (pp_list pp_term) tlst)
  
  let fun_of_5args_i
    (name : string)                           (* The name of the function - for debug purposes *)
    (efst : string -> term -> 'a interpreter) (* An extractor for the first argument *)
    (esnd : string -> term -> 'b interpreter) (* An extractor for the second argument *)
    (ethd : string -> term -> 'c interpreter) (* An extractor for the third argument *)
    (efth : string -> term -> 'd interpreter) (* An extractor for the second argument *)
    (efft : string -> term -> 'e interpreter) (* An extractor for the fifth argument *)
    (mk : info -> 'f -> term)                 (* A maker for the result *)
    (op : 'a -> 'b -> 'c -> 'd -> 'e -> 'f interpreter) (* The operation to perform *)
    : primfun = fun_of_5args_with_type_i name efst esnd ethd efth efft mk (fun _ty -> op)

  let fun_of_7args_with_type_i
    (name : string)                           (* The name of the function - for debug purposes *)
    (efst : string -> term -> 'a interpreter) (* An extractor for the first argument *)
    (esnd : string -> term -> 'b interpreter) (* An extractor for the second argument *)
    (ethd : string -> term -> 'c interpreter) (* An extractor for the third argument *)
    (efth : string -> term -> 'd interpreter) (* An extractor for the fourth argument *)
    (efft : string -> term -> 'e interpreter) (* An extractor for the fifth argument *)
    (esxh : string -> term -> 'f interpreter) (* An extractor for the sixth argument *)
    (esvh : string -> term -> 'g interpreter) (* An extractor for the seventh argument *)
    (mk : info -> 'h -> term)                 (* A maker for the result *)
    (op : ty -> 'a -> 'b -> 'c -> 'd -> 'e -> 'f -> 'g -> 'h interpreter)   (* The operation to perform *)
    : primfun = 
    PrimFun (fun t -> extractArgs name t >>= fun (ty, tlst) -> match tlst with
      | ta :: tb :: tc :: td :: te :: tf :: tg :: []
          -> efst name ta >>= fun a ->
             esnd name tb >>= fun b ->
             ethd name tc >>= fun c ->
             efth name td >>= fun d ->
             efft name te >>= fun e ->
             esxh name tf >>= fun f ->
             esvh name tg >>= fun g ->
             op ty a b c d e f g >>= fun res -> return (mk di res)
      | _ -> fail_pp "** Primitive ** %s expected 7 arguments but found %a" name (pp_list pp_term) tlst)
  
  let fun_of_7args_i
    (name : string)                           (* The name of the function - for debug purposes *)
    (efst : string -> term -> 'a interpreter) (* An extractor for the first argument *)
    (esnd : string -> term -> 'b interpreter) (* An extractor for the second argument *)
    (ethd : string -> term -> 'c interpreter) (* An extractor for the third argument *)
    (efth : string -> term -> 'd interpreter) (* An extractor for the second argument *)
    (efft : string -> term -> 'e interpreter) (* An extractor for the fifth argument *)
    (esxh : string -> term -> 'f interpreter) (* An extractor for the sixth argument *)
    (esvh : string -> term -> 'g interpreter) (* An extractor for the seventh argument *)
    (mk : info -> 'h -> term)                 (* A maker for the result *)
    (op : 'a -> 'b -> 'c -> 'd -> 'e -> 'f -> 'g -> 'h interpreter)   (* The operation to perform *)
    : primfun = fun_of_7args_with_type_i name efst esnd ethd efth efft esxh esvh mk (fun _ty -> op)

end

open Creation

let message n = Support.Error.message n Support.Options.Interpreter di
let assertionMsg i = Support.Error.message (-1) Support.Options.Assertion i
let printMsg i = Support.Error.message (-1) Support.Options.General i


(*****************************************************************************)
(* Here we have modifying functions *)

(* Makes sure that the given function only evaluates when we are in full 
   evaluation mode (as opposed to partial. *)
let onlyInFullEval (name : string) : unit interpreter = 
  isInPartial >>= fun b ->
  if b then fail (name^" not to be evaluated during partial evaluation") else (return ())


(*****************************************************************************)
(* Here is the primitive for case on integers. *)

let rec intToPeanoFun
  (ty : ty)
  (n : int)
  : term interpreter = 
    if (n <= 0) then
      return @@ TmFold(di, ty, TmLeft(di, mkUnit di (), ty))
    else
      intToPeanoFun ty (n - 1) >>= fun n' ->
      return @@ TmFold(di, ty, TmRight(di, n', TyPrim PrimUnit))


(*****************************************************************************)
(* Here are some helpers for file and string parsing. *)
let fileLines (maxLines : int) (filename : string) = 
  let lines = ref [] in
  let chan = open_in filename in
  try
    for i=1 to maxLines; do
      lines := input_line chan :: !lines
    done;
    close_in chan;
    List.rev !lines
  with End_of_file ->
    close_in chan;
    List.rev !lines

let stringToFloat (s : string) : float = 
  try
    float_of_string s
  with Failure _ ->
    message 0 "prim.ml: float_of_string failed to parse: %s.  Providing 0 instead.\n" s;
    0.

let stringToInt (s : string) : int = 
  try
    int_of_string s
  with Failure _ ->
    message 0 "prim.ml: int_of_string failed to parse: %s.  Providing 0 instead.\n" s;
    0

let stringToBool (s : string) : bool = 
  try
    bool_of_string s
  with Failure _ ->
    message 0 "prim.ml: bool_of_string failed to parse: %s.  Providing false instead.\n" s;
    false

let rec typeToMaker (i : info) (ty : ty) : (string -> term) option = match ty with
  | TyPrim PrimNum  -> Some (fun s -> mkNum i (stringToFloat s))
  | TyPrim PrimInt  -> Some (fun s -> mkInt i (stringToInt s))
  | TyPrim PrimUnit -> Some (mkUnit i)
  | TyPrim PrimBool -> Some (fun s -> mkBool i (stringToBool s))
  | TyPrim PrimString   -> Some (mkString i)
  | TyPrim PrimClipped  -> Some (fun s -> mkClipped i (stringToFloat s))
  | TyPrim1 (Prim1Token, t) -> Some (fun s -> mkToken i (stringToInt s, t))
  | TyPrim1 (Prim1Bag, t) -> Option.map
        (fun mker -> (fun s -> mkBag    i (ty, List.map mker (Str.split (Str.regexp "[ \t]+") s))))
        (typeToMaker i t)
  | TyPrim1 (Prim1Vector, t) -> Option.map 
        (fun mker -> (fun s -> mkVector i (ty, List.map mker (Str.split (Str.regexp "[ \t]+") s))))
        (typeToMaker i t) 
  | _ -> None

let marshalFromString (s : string) : 'a option = 
  try
    Some (Marshal.from_string s 0)
  with Invalid_argument _ -> None


let rec unMarshalTerm (i : info) (ty : ty) (obj : 'a) : term option = match ty with
  | TyPrim PrimNum  -> Some (mkNum i (Obj.magic obj))
  | TyPrim PrimInt  -> Some (mkInt i (Obj.magic obj))
  | TyPrim PrimUnit -> Some (mkUnit i ())
  | TyPrim PrimBool -> Some (mkBool i (Obj.magic obj))
  | TyPrim PrimString   -> Some (mkString i (Obj.magic obj))
  | TyPrim PrimClipped  -> Some (mkClipped i (Obj.magic obj))
  | TyPrim1 (Prim1Token, t) -> Some (mkToken i (Obj.magic obj, t))
  | TyPrim1 (Prim1Bag, t) -> let v = Option.opt_bind_list (List.map (unMarshalTerm i t) (Obj.magic obj)) in
        Option.map (fun lst -> mkBag i (ty,lst)) v
  | TyPrim1 (Prim1Vector, t) -> let v = Option.opt_bind_list (List.map (unMarshalTerm i t) (Array.to_list (Obj.magic obj))) in
        Option.map (fun lst -> mkVector i (ty,lst)) v
  | TyTensor(t1,t2) -> let (v1,v2) = Obj.magic obj in
                       Option.obind (unMarshalTerm i t1 v1) (fun tm1 ->
                       Option.obind (unMarshalTerm i t2 v2) (fun tm2 ->
                       Some (TmPair(i,tm1,tm2))))
  | TyAmpersand(t1,t2) -> let (v1,v2) = Obj.magic obj in
                       Option.obind (unMarshalTerm i t1 v1) (fun tm1 ->
                       Option.obind (unMarshalTerm i t2 v2) (fun tm2 ->
                       Some (TmAmpersand(i,tm1,tm2))))
  | TyUnion(t1,t2) -> begin match Obj.magic obj with
                      | Left a  -> Option.map (fun tm -> TmLeft (i,tm,t2)) (unMarshalTerm i t1 a)
                      | Right b -> Option.map (fun tm -> TmRight(i,tm,t1)) (unMarshalTerm i t2 b)
                      end
  | _ -> None

(*****************************************************************************)
(*****************************************************************************)
(* Here we have specific helper functions for specific primitives. *)
(*****************************************************************************)
(*****************************************************************************)

(*****************************************************************************)
(* We begin with assertions. *)

let assertFun
  (s : string)
  (b : bool)
  : unit = 
    ignore (assertionMsg di "%s: %s" s (if b then "PASS" else "FAIL"))

let assertEqFun
  (s : string)
  (t1 : term)
  (t2 : term)
  : unit = 
    let res = if Syntax.tmEq t1 t2 
              then "PASS"
              else pp_to_string "FAIL (%a != %a)" pp_term t1 pp_term t2
    in ignore (assertionMsg di "%s: %s" s res)


(*****************************************************************************)
(* The following functions invoke the Fuzz sensitivity type checker. *)

let tyCheckFuzzFun
  (sens : float)
  (f : term)
  : term interpreter =
    onlyInFullEval "tyCheckFuzz" >>
    let genFailResult s = return (TmLeft(di, TmPrim(di, PrimTString s), TyPrim PrimUnit)) in
    match Tycheck.type_of f (Ctx.empty_context, 0, true, Some (!pinterpLimit, Interpreter.genPinterp)) with
      | Ok (TyLollipop(_, SiConst n, _), _) when n <= sens -> return (TmRight(di, mkUnit di (), TyPrim PrimString))
      | Ok (TyLollipop(_, SiConst n, _), _) -> genFailResult @@
            pp_to_string "tyCheckFuzz expected a %F-sensitive function but found a %F-sensitive function" sens n
      | Ok (TyLollipop(_, SiInfty, _), _)   -> genFailResult @@
            pp_to_string "tyCheckFuzz expected a %F-sensitive function but found an infinitely sensitive function" sens
      | Ok (TyLollipop(_, si, _), _) -> fail_pp "**Primitive** tyCheckFuzz found an unexpected sensitivity: %a" pp_si si
      | Ok (tyf, _) -> fail_pp "**Primitive** tyCheckFuzz's function argument has non-lollipop type: %a" pp_type tyf
      | Error (d,e) -> genFailResult @@ pp_to_string "TYPE FAIL: %a %a" pp_fileinfo e.i (pp_tyerr d) e.v

let runRedZone
  (ty : ty)
  (sens : float)
  (f : term)
  : term interpreter =
    onlyInFullEval "runRedZone" >>
    (match ty with
      | TyUnion(_, aty) -> return aty
      | _ -> fail_pp "**Primitive** runRedZone found an unexpected return type: %a" pp_type ty
    ) >>= fun outty ->
    let genFailResult s = return (TmLeft(di, TmPrim(di, PrimTString s), outty)) in
    match Tycheck.type_of f (Ctx.empty_context, 0, true, Some (!pinterpLimit, Interpreter.genPinterp)) with
      | Ok (TyLollipop(_, SiConst n, _), _) when n <= sens -> begin
          attemptRedZone n >>= fun succ ->
          match succ, !useCompiler with
            | false, _ -> genFailResult "Database is all used up"
            | true, true -> begin
                getDB >>= fun db ->
                let query = TmApp(di, TmApp(di, f, TmApp(di, db, mkUnit di ())), mkUnit di ()) in
                match Codegen.runCompiled (!rzFileName) query with
                  | Error s -> genFailResult s
                  | Ok res  -> begin match Option.obind (marshalFromString res) (unMarshalTerm di outty) with
                    | Some r -> return (TmRight(di, r, TyPrim PrimString))
                    | None -> fail @@ "**Primitive** RunRedZone: Failed to unmarshal term: "^res
                    end
                end
            | true, false ->
                getDB >>= fun db ->
                Interpreter.interp (TmUnPVal (di, (TmApp(di, f, TmApp(di, db, TmPrim(di, PrimTUnit)))))) >>= fun a -> return (TmRight(di, a, TyPrim PrimString))
          end
      | Ok (TyLollipop(_, SiConst n, _), _) -> genFailResult @@
            pp_to_string "runRedZone expected a %F-sensitive function but found a %F-sensitive function" sens n
      | Ok (TyLollipop(_, SiInfty, _), _)   -> genFailResult @@
            pp_to_string "runRedZone expected a %F-sensitive function but found an infinitely sensitive function" sens
      | Ok (TyLollipop(_, si, _), _) -> fail_pp "**Primitive** runRedZone found an unexpected sensitivity: %a" pp_si si
      | Ok (tyf, _) -> fail_pp "**Primitive** runRedZone's function argument has non-lollipop type: %a" pp_type tyf
      | Error (d,e) -> genFailResult @@ pp_to_string "TYPE FAIL: %a %a" pp_fileinfo e.i (pp_tyerr d) e.v


(*****************************************************************************)
(* Here are ones specifically for bag stuff. *)

let showBagFun
  (f : term)
  (b : term list)
  : string interpreter =
    mapM (fun t -> Interpreter.interp (TmApp(di, f, t)) >>= exString "showBag") b >>= fun strList ->
    return @@ String.concat "," strList

let rec bagfoldlFun
  (f : term)
  (a : term)
  (bbag : term list)
  : term interpreter = 
    match bbag with
    | [] -> return a
    | b::bs -> Interpreter.interp (TmApp(di, TmApp(di, f, a), b)) >>= fun x ->
               bagfoldlFun f x bs

let bagmapFun 
  (ty : ty)
  (f : term)
  (b : term list)
  : (ty * term list) interpreter = 
    mapM (fun t -> Interpreter.interp (TmApp(di, f, t))) b >>= fun tmlst ->
    return (ty, tmlst)
    (*return (ty, List.map (fun tm -> TmApp(di, f, tm)) b)*)

let bagsplitFun
  (oty : ty)
  (f : term)
  (b : term list)
  : ((ty * term list) * (ty * term list)) interpreter = 
    (match oty with
      | TyTensor(ty,_)  -> return ty
      | _               -> fail_pp "** Primitive ** bagsplit expected a tensor output but found %a" pp_type oty
    ) >>= fun bty ->
    mapM (fun tm -> Interpreter.interp (TmApp(di, f, tm)) >>= exBool "bagsplit" >>= fun res -> return (tm, res)) b >>= fun lst ->
    let (lst1, lst2) = List.partition snd lst in
    return ((bty, List.map fst lst1), (bty, List.map fst lst2))

let bagsumLFun
  (n : int)
  (b : term list)
  : (ty * float list) interpreter =
    let rec sumUp xs ys = match xs,ys with
            | x::xs,y::ys -> (x +. y)::sumUp xs ys
            | xs,[] -> xs
            | [],ys -> ys
    in 
    mapM (fun t -> Interpreter.interp t >>= exList exNum "bagsumL") b >>= fun numlstlst ->
    return @@ (TyPrim PrimNum, List.fold_left sumUp [] numlstlst)

let bagsumVFun
  (oty : ty)
  (n : int)
  (b : term list)
  : (ty * term list) interpreter =
    let rec sumUp xs ys = match xs,ys with
            | x::xs,y::ys -> (x +. y)::sumUp xs ys
            | xs,[] -> xs
            | [],ys -> ys
    in 
    mapM (fun t -> Interpreter.interp t >>= exVector "bagsumV" >>= mapM 
            (fun t' -> Interpreter.interp t' >>= exNum "bagsumV")) b >>= fun numlstlst ->
    return (oty, List.map (mkNum di) (List.fold_left sumUp [] numlstlst))



(*****************************************************************************)
(* Here are ones specifically for differentially private noise. *)
let addNoiseFun
  (eps : float)
  (n : float)
  : float interpreter = 
    onlyInFullEval "addNoise" >>
    return (n +. Math.lap (1.0 /. eps))


(* reportNoisyMax : num[s] -> num[k] -> (R -> DB -o[k] num) -> R bag -> DB -o[s] fuzzy R *)
let reportNoisyMaxFun
  (eps : float)
  (k : float)
  (quality : term)
  (rbag : term list)
  (db : term)
  : term interpreter = 
    onlyInFullEval "reportNoisyMax" >>
    mapM (fun r -> Interpreter.interp (TmApp(di, TmApp(di, quality, r), db)) 
            >>= exNum "reportNoisyMax"
            >>= fun q -> return (r, q +. Math.lap (k /. eps))) rbag >>= fun problist ->
(*    Support.Error.message 0 Support.Options.Interpreter Support.FileInfo.dummyinfo 
      "--- reportNoisyMax: Probabilities are: %s" (String.concat "," (List.map (fun x -> string_of_float (snd x)) problist));*)
    let (res, _i) = List.fold_left 
            (fun best r -> if abs_float (snd r) > abs_float (snd best) then r else best)
            (mkUnit di (), 0.0) problist in
    return res


(* expMech : num[s] -> num[k] -> (R -> DB -o[k] num) -> R bag -> DB -o[s] fuzzy R *)
let expMechFun
  (eps : float)
  (k : float)
  (quality : term)
  (rbag : term list)
  (db : term)
  : term interpreter = 
    onlyInFullEval "expMech" >>
    mapM (fun r -> Interpreter.interp (TmApp(di, TmApp(di, quality, r), db)) 
            >>= exNum "expMech"
            >>= fun q -> return (r, exp (eps *. q /. (2.0 *. k)))) rbag >>= fun reslist ->
    let total = List.fold_left (+.) 0.0 (List.map snd reslist) in
    let rec sampleLst (p : float) (lst : ('a * float) list) : 'a interpreter =
      match lst with
      | [] -> fail_pp "**Primitive** expMechFun was given an empty list."
      | (a,x)::xs -> if p < x then return a else sampleLst (p -. x) xs
    in sampleLst (Math.randFloat total) (List.sort (fun a b -> truncate (snd b -. snd a)) reslist)


(* aboveThreshold : num[s] -> num[k] -> num -> DB -o[k*s] fuzzy token *)
let aboveThresholdFun
  (thisTerm : term)
  (ty : ty)
  (eps : float)
  (k : float)
  (t : float)
  (db : term)
  : (int * ty) interpreter = 
    onlyInFullEval "aboveThreshold" >>
    (match ty with
      | TyPrim1 (Prim1Fuzzy, TyPrim1 (Prim1Token, TyLollipop(argtype, _, outtype))) -> return (TyLollipop(argtype, SiConst k, outtype))
      | _ -> fail_pp "**Primitive** aboveThreshold found an unexpected return type: %a" pp_type ty
    ) >>= fun ftype ->
    match !useCompiler with
    | true -> begin match Codegen.runCompiled (!rzFileName) thisTerm with
                  | Error s -> fail @@ "**Primitive** aboveThreshold failed with message: "^s
                  | Ok res  -> begin match marshalFromString res with
                    | Some r -> return (r, ftype)
                    | None -> fail @@ "**Primitive** Failed to unmarshal term: "^res
                    end
              end
    | false ->
        let index = List.length (!curatormem) in
        curatormem := List.append !curatormem [Some (t +. Math.lap (2.0 /. (eps *. k)), eps, db)];
        return (index, ftype)

let rec updateNth (lst : 'a list) (index : int) (f : 'a -> 'a) : 'a list =
  match lst, index with
  | [],_ -> []
  | x::xs, 0 -> f x :: xs
  | x::xs, n -> x :: updateNth xs (n-1) f

let queryATFun
  (thisTerm : term)
  (_ty : ty)
  (tok : (int * ty))
  (q : term)
  : (ty * ty * (unit, bool) either) interpreter =
    onlyInFullEval "aboveThreshold query" >>
    (match tok with
    | (index, TyLollipop(_, SiConst k, TyPrim PrimNum)) -> begin
        match Tycheck.type_of q (Ctx.empty_context, 0, true, Some (!pinterpLimit, Interpreter.genPinterp)) with
          | Ok (TyLollipop(_, SiConst n, _), _) when n <= k -> begin
            match !useCompiler with
            | true -> begin match Codegen.runCompiled (!rzFileName) thisTerm with
                | Error s -> fail @@ "**Primitive** aboveThresholdQuery failed with message: "^s
                | Ok res  -> begin match marshalFromString res with
                    | Some r -> return (Option.map_default (fun v -> Right v) (Left ()) r)
                    | None -> fail @@ "**Primitive** Failed to unmarshal term: "^res
                    end
                end
            | false -> begin match List.nth (!curatormem) index with
                | None -> return (Left ())
                | Some (t,eps,db) ->
                    Interpreter.interp (TmApp(di, q, db)) >>= exNum "aboveThreshold" >>= fun res ->
                    if res +. Math.lap (4.0 /. eps) >= t then
                      (curatormem := updateNth !curatormem index (fun _ -> None); return (Right true))
                    else return (Right false)
                end
            end
          | Ok (TyLollipop(_, SiConst n, _), _) -> fail_pp "**Primitive** aboveThreshold expected a %F-sensitive function but found a %F-sensitive function" k n
          | Ok (TyLollipop(_, SiInfty, _), _)   -> fail_pp "**Primitive** aboveThreshold expected a %F-sensitive function but found an infinitely sensitive function" k
          | Ok (TyLollipop(_, si, _), _) -> fail_pp "**Primitive** aboveThreshold found an unexpected sensitivity: %a" pp_si si
          | Ok (tyf, _) -> fail_pp "**Primitive** aboveThreshold's function argument has non-lollipop type: %a" pp_type tyf
          | Error (d,e) -> fail_pp "TYPE FAIL: %a %a" pp_fileinfo e.i (pp_tyerr d) e.v
        end
    | _ -> fail_pp "**Primitive** aboveThreshold received an inappropriate or malformed token."
    ) >>= (fun res -> return (TyPrim PrimUnit, TyPrim PrimBool, res))
    

let selectFun
  (ty : ty)
  (beta : float)
  (bag : term list)
  : (ty * term list) interpreter =
    onlyInFullEval "select" >>
    return (ty, Math.sampleList beta bag)


(*****************************************************************************)
(* Here are the *fromFile primitives. *)
let bagFromFileFun
  (oty : ty)
  (maxsize : int)
  (fn : string)
  : (ty * term list) interpreter = 
    let lines = fileLines maxsize fn in
    match oty with
      | TyPrim1 (Prim1Bag, subty) -> begin match typeToMaker di subty with
          | Some lineFun -> return (oty, List.map lineFun lines)
          | None -> fail_pp "**Primitive** bagFromFile used with an unsupported output type %a." pp_type oty
          end
      | _ -> fail_pp "**Primitive** bagFromFile found a weird type %a." pp_type oty

let rec listFromFileFun
  (oty : ty)
  (maxsize : int)
  (fn : string)
  : term interpreter = 
    let lines = fileLines maxsize fn in
    match oty with
      | TyMu (_, TyUnion (TyPrim PrimUnit, TyTensor (subty, TyVar _))) -> begin
        match typeToMaker di subty with
          | Some lineFun -> return (List.fold_right (fun v fzlst -> TmFold (di, oty, TmRight (di, TmPair (di, v, fzlst), TyPrim PrimUnit)))
                                                    (List.map lineFun lines) 
                                                    (TmFold (di, oty, TmLeft (di, TmPrim (di, PrimTUnit), TyTensor(subty, oty)))))
          | None -> fail_pp "**Primitive** listFromFile used with an unsupported output type %a." pp_type oty
        end
      | _   -> fail_pp "**Primitive** listFromFile found a weird type %a." pp_type oty

let listbagFromFileFun
  (oty : ty)
  (maxsize : int)
  (fn : string)
  (rexp : string)
  : (ty * term list) interpreter = 
    let lines = fileLines maxsize fn in
    match oty with
      | TyPrim1 (Prim1Bag, TyMu (_, TyUnion (TyPrim PrimUnit, TyTensor (subty, TyVar _)))) -> begin
        match typeToMaker di subty with
          | Some wordFun -> let lineFun line = List.fold_right (fun v fzlst -> TmFold (di, oty, TmRight (di, TmPair (di, v, fzlst), TyPrim PrimUnit)))
                                (List.map wordFun (Str.split (Str.regexp rexp) line))  (*"[ \t]+"*)
                                (TmFold (di, oty, TmLeft (di, TmPrim (di, PrimTUnit), subty)))
                            in return (oty, List.map lineFun lines)
          | None -> fail_pp "**Primitive** listbagFromFile used with an unsupported output type %a." pp_type oty
          end
      | _   -> fail_pp "**Primitive** listbagFromFile found a weird type %a." pp_type oty


let vectorbagFromFileFun
  (oty : ty)
  (maxsize : int)
  (fn : string)
  (rexp : string)
  : (ty * term list) interpreter = 
    let lines = fileLines maxsize fn in
    match oty with
      | TyPrim1 (Prim1Bag, TyPrim1 (Prim1Vector, subty)) -> begin match typeToMaker di subty with
          | Some wordFun -> let lineFun line = mkVector di (TyPrim1 (Prim1Vector, subty), List.map wordFun (Str.split (Str.regexp rexp) line))
                            in return (oty, List.map lineFun lines)
          | None -> fail_pp "**Primitive** vectorbagFromFile used with an unsupported output type %a." pp_type oty
          end
      | _   -> fail_pp "**Primitive** vectorbagFromFile found a weird type %a." pp_type oty


(*****************************************************************************)
(* Here are the vector primitives. *)

let showVecFun
  (f : term)
  (v : term list)
  : string interpreter =
    mapM (fun t -> Interpreter.interp (TmApp(di, f, t)) >>= exString "showVec") v >>= fun strList ->
    return @@ String.concat "," strList

let vconsFun
  (oty : ty)
  (x : term)
  (xs : term list)
  : (ty * term list) interpreter = return (oty, x::xs)

let vunconsFun
  (oty : ty)
  (v : term list)
  : (ty * ty * (unit, term * (ty * term list)) either) interpreter = 
    (match oty with
      | TyUnion (tyl, TyTensor (tyx, tyxvec)) -> return (tyl, TyTensor (tyx, tyxvec), tyxvec)
      | _   -> fail_pp "**Primitive** vuncons found a weird type %a." pp_type oty
    ) >>= fun (tyl, tyr, tyxvec) -> 
    match v with
    | [] -> return (tyl, tyr, Left ())
    | x::xs -> return (tyl, tyr, Right (x, (tyxvec, xs)))

let listToVectorFun
  (oty : ty)
  (lst : term list)
  : (ty * term list) interpreter = return (oty, lst)

let vectorToListFun
  (oty : ty)
  (lst : term list)
  : (ty * term list) interpreter = 
    (match oty with
      | TyMu (_, TyUnion (TyPrim PrimUnit, TyTensor (subty, TyVar _))) -> return subty
      | _   -> fail_pp "**Primitive** vectorToList found a weird type %a." pp_type oty
    ) >>= fun subty -> return (subty, lst)

let vindexFun
  (def : term)
  (i : int)
  (v : term list)
  : term = 
    let rec nth i lst = match lst with
            | [] -> def
            | x::xs -> if i <= 0 then x else nth (i-1) xs
    in nth i v

let vperformAtFun
  (oty : ty)
  (i : int)
  (f : term)
  (v : term list)
  : (ty * term list) interpreter =
    if i >= List.length v || i < 0 then
      fail_pp "**Primitive** vperformAt had an out-of-bounds list index %a." pp_type oty
    else
      let rec inner i l = match i,l with
        | _,[] -> return []
        | 0,x::xs -> Interpreter.interp (TmApp(di, f, x)) >>= fun x' -> return (x'::xs)
        | _,x::xs -> inner (i-1) xs >>= fun xs' -> return (x::xs')
      in inner i v >>= fun res -> return (oty, res)

let vzipwithFun
  (oty : ty)
  (f : term)
  (lst1 : term list)
  (lst2 : term list)
  : (ty * term list) interpreter = 
  let rec zip l1 l2 = match l1, l2 with
                      | x::xs, y::ys -> (x, y)::(zip xs ys)
                      | _,_ -> []
  in mapM (fun (t1, t2) -> Interpreter.interp (TmApp(di, TmApp(di, f, t1), t2)) >>= exAny "vzipwith") (zip lst1 lst2) >>= fun lst' -> 
     return (oty, lst')

let rec vfilterFun 
  (ty : ty)
  (test : term)
  (f : term)
  (lst : term list)
  : (ty * term list) interpreter = 
    match lst with
    | x::xs -> Interpreter.interp (TmApp(di, test, x)) >>= exBool "vfilter" >>= fun b ->
               if b then begin
                 Interpreter.interp (TmApp(di, f, x)) >>= fun t ->
                 vfilterFun ty test f xs >>= fun (ty,ts) ->
                 return (ty, t::ts)
               end else
                 vfilterFun ty test f xs
    | _ -> return (ty,[])


(*****************************************************************************)
(*****************************************************************************)
(* Core primitive definitions for the runtime *)
(*****************************************************************************)
(*****************************************************************************)
let prim_list : (string * primfun) list = [

(* &-pair destruction *)
("_fst", fun_of_1arg "_fst" (exAmp exAny exAny) mkAny fst);
("_snd", fun_of_1arg "_snd" (exAmp exAny exAny) mkAny snd);

(* Logical Operators *)
("_lor",  fun_of_2args "_lor"  exBool exBool mkBool ( || ));
("_land", fun_of_2args "_land" exBool exBool mkBool ( && ));
("_eq",   fun_of_2args "_eq"   exAny  exAny  mkBool Syntax.tmEq);

(* Numerical Comparison Operators *)
("_lt",  fun_of_2args "_lt"  exNum exNum mkBool ( < ));
("_gt",  fun_of_2args "_gt"  exNum exNum mkBool ( > ));
("_lte", fun_of_2args "_lte" exNum exNum mkBool ( <= ));
("_gte", fun_of_2args "_gte" exNum exNum mkBool ( >= ));

(* Numerical Computation Operators *)
("_add", fun_of_2args "_add" exNum exNum mkNum ( +. ));
("_sub", fun_of_2args "_sub" exNum exNum mkNum ( -. ));
("_mul", fun_of_2args "_mul" exNum exNum mkNum ( *. ));
("_div", fun_of_2args "_div" exNum exNum mkNum ( /. ));

("_exp", fun_of_1arg "_exp" exNum mkNum ( exp ));
("_log", fun_of_1arg "_log" exNum mkNum ( log ));
("_abs", fun_of_1arg "_abs" exNum mkNum ( abs_float ));
("cswp", fun_of_1arg "cswp" (exPair exNum exNum) (mkPair mkNum mkNum)
    (fun (x,y) -> if x < y then (x,y) else (y,x)));

(* Integer primitives *)
("_iadd", fun_of_2args "_iadd" exInt exInt mkInt ( + ));
("_isub", fun_of_2args "_isub" exInt exInt mkInt ( - ));
("_imul", fun_of_2args "_imul" exInt exInt mkInt ( * ));
("_idiv", fun_of_2args "_idiv" exInt exInt mkInt ( / ));
("intToPeano", fun_of_1arg_with_type_i "intToPeano" exInt mkAny intToPeanoFun);

(* clip creation *)
("clip", fun_of_1arg "clip" exNum mkClipped (fun x -> x));
("fromClip", fun_of_1arg "fromClip" exNum mkNum (fun x -> x));

(* String operations *)
("string_cc", fun_of_2args "string_cc" exString exString mkString ( ^ ));

(* Show functions *)
("showNum", fun_of_1arg "showNum" exNum mkString 
    ( fun n -> if n = floor n then string_of_int (truncate n) else string_of_float n ));
("showInt", fun_of_1arg "showInt" exInt mkString ( string_of_int ));
("showBag", fun_of_2args_i "showBag" exFun exBag mkString showBagFun);
("showVec", fun_of_2args_i "showVec" exFun exVector mkString showVecFun);

(* Testing Utilities *)
("_assert",  fun_of_2args "_assert"  exString exBool mkUnit assertFun);
("assertEq", fun_of_3args "assertEq" exString exAny exAny mkUnit assertEqFun);
("print",    fun_of_1arg "print"     exString mkUnit (fun s -> ignore (printMsg di "%s" s)));

(* Probability monad operations *)
("_return", fun_of_1arg_i "_return" exAny (mkPVal mkAny) (fun x -> onlyInFullEval "return" >> return x));

("loadDB", fun_of_2args_i "loadDB" exFun (exPair exNum exNum) mkUnit storeDB);

(* Red zone activation primitives *)
("tyCheckFuzz", fun_of_2args_i "tyCheckFuzz" exNum exAny mkAny tyCheckFuzzFun);
("runRedZone", fun_of_2args_with_type_i "runRedZone" exNum exFun mkAny runRedZone);

("getDelta",   fun_of_1arg_i "getDelta"   exAny mkNum (fun _ -> onlyInFullEval "getDelta"   >> getDelta));
("getEpsilon", fun_of_1arg_i "getEpsilon" exAny mkNum (fun _ -> onlyInFullEval "getEpsilon" >> getEpsilon));

(* Bag primitives *)
("emptybag", fun_of_no_args_with_type_i "emptybag" mkBag (fun ty -> return (ty,[])));
("addtobag", fun_of_2args_with_type_i "addtobag" exAny exBag mkBag
  (fun ty x xs -> return (ty, x::xs)));
("bagjoin", fun_of_2args_with_type_i "bagjoin" exBag exBag mkBag
  (fun ty b1 b2 -> return (ty, List.append b1 b2)));
("bagsize", fun_of_1arg "bagsize" exBag mkInt ( List.length ));
("bagsum", fun_of_1arg_i "bagsum" exBag mkNum 
  (fun l -> mapM (fun t -> Interpreter.interp t >>= exNum "bagsum") l >>= fun l' -> return (List.fold_left (+.) 0.0 l')));
("bagfoldl", fun_of_3args_i "bagfoldl" exAny exAny exBag mkAny bagfoldlFun);
("bagmap", fun_of_2args_with_type_i "bagmap" exFun exBag mkBag bagmapFun);
("bagsplit", fun_of_2args_with_type_i "bagsplit" exFun exBag (mkPair mkBag mkBag) bagsplitFun);
("bagsumL", fun_of_2args_i "bagsumL" exInt exBag (mkList mkNum) bagsumLFun);
("bagsumV", fun_of_2args_with_type_i "bagsumV" exInt exBag mkVector bagsumVFun);


(* Differential Privacy mechanisms *)
("addNoise", thunkify "addNoise" "addNoiseP"
  (fun_of_2args_i "addNoiseP" exNum exNum mkNum addNoiseFun));
("reportNoisyMax", thunkify "reportNoisyMax" "reportNoisyMaxP"
  (fun_of_5args_i "reportNoisyMaxP" exNum exNum exFun exBag exAny mkAny reportNoisyMaxFun));
("expMech", thunkify "expMech" "expMechP"
  (fun_of_5args_i "expMechP" exNum exNum exFun exBag exAny mkAny expMechFun));
("select", thunkify "select" "selectP"
  (fun_of_2args_with_type_i "select" exNum exBag mkBag selectFun));
("aboveThreshold", thunkify "aboveThreshold" "aboveThresholdP"
  (fun_of_4args_with_type_i_self "aboveThresholdP" exNum exNum exNum exAny mkToken aboveThresholdFun));
("queryAT", fun_of_2args_with_type_i_self "queryAT" exToken exFun (mkSum mkUnit mkBool) queryATFun);

(* Load data from external file *)
("bagFromFile",  fun_of_2args_with_type_i "bagFromFile"  exInt exString mkBag bagFromFileFun);
("listFromFile", fun_of_2args_with_type_i "listFromFile" exInt exString mkAny listFromFileFun);
("listbagFromFile", fun_of_3args_with_type_i "listbagFromFile" exInt exString exString mkBag listbagFromFileFun);
("vectorbagFromFile", fun_of_3args_with_type_i "vectorbagFromFile" exInt exString exString mkBag vectorbagFromFileFun);

(* Vector operations *)
("vcons", fun_of_2args_with_type_i "vcons" exAny exVector mkVector vconsFun);
("vuncons", fun_of_1arg_with_type_i "vuncons" exVector (mkSum mkUnit (mkPair mkAny mkVector)) vunconsFun);
("listToVector", fun_of_1arg_with_type_i "listToVector" (exList exAny) mkVector listToVectorFun);
("vectorToList", fun_of_1arg_with_type_i "vectorToList" exVector (mkList mkAny) vectorToListFun);
("vindex",  fun_of_3args "vindex"  exAny exInt exVector mkAny vindexFun);
("vperformAt", fun_of_3args_with_type_i "vperformAt" exInt exFun exVector mkVector vperformAtFun);
("vmap", fun_of_2args_with_type_i "vmap" exFun exVector mkVector bagmapFun);
("vfilter", fun_of_3args_with_type_i "vfilter" exFun exFun exVector mkVector vfilterFun);
("vzipwith", fun_of_3args_with_type_i "vzipwith" exFun exVector exVector mkVector vzipwithFun);
("vsize", fun_of_1arg "vsize" exVector mkInt ( List.length ));
("vsum", fun_of_1arg_i "vsum" exVector mkNum 
  (fun l -> mapM (fun t -> Interpreter.interp t >>= exNum "vsum") l >>= fun l' -> return (List.fold_left (+.) 0.0 l')));

]

(* Look for a primfun in the primitive list *)
let lookup_prim (id : string) : primfun option =
  let rec lookup l = match l with
    | []            -> None
    | (s, t) :: l'  -> if s = id then Some t else lookup l'
  in lookup prim_list



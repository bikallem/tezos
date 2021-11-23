(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2021 Nomadic Labs. <contact@nomadic-labs.com>               *)
(*                                                                           *)
(* Permission is hereby granted, free of charge, to any person obtaining a   *)
(* copy of this software and associated documentation files (the "Software"),*)
(* to deal in the Software without restriction, including without limitation *)
(* the rights to use, copy, modify, merge, publish, distribute, sublicense,  *)
(* and/or sell copies of the Software, and to permit persons to whom the     *)
(* Software is furnished to do so, subject to the following conditions:      *)
(*                                                                           *)
(* The above copyright notice and this permission notice shall be included   *)
(* in all copies or substantial portions of the Software.                    *)
(*                                                                           *)
(* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR*)
(* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,  *)
(* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL   *)
(* THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER*)
(* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING   *)
(* FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER       *)
(* DEALINGS IN THE SOFTWARE.                                                 *)
(*                                                                           *)
(*****************************************************************************)

(** Testing
    -------
    Component:    Shell (Prevalidator classification)
    Invocation:   dune exec src/lib_shell/test/test_prevalidator_classification.exe
    Subject:      Unit tests the Prevalidator classification APIs
*)

open Lib_test.Qcheck_helpers
module Generators = Prevalidator_generators
module Classification = Prevalidator_classification

module Operation_map = struct
  let pp_with_trace ppf map =
    Format.fprintf
      ppf
      "[%a]"
      (Format.pp_print_list (fun ppf (oph, (op, _tztrace)) ->
           Format.fprintf
             ppf
             "(%a: (%a, <tztrace>))"
             Operation_hash.pp
             oph
             Operation.pp
             op))
      (Operation_hash.Map.bindings map)

  let pp ppf map =
    Format.fprintf
      ppf
      "[%a]"
      (Format.pp_print_list (fun ppf (oph, op) ->
           Format.fprintf ppf "(%a: %a)" Operation_hash.pp oph Operation.pp op))
      (Operation_hash.Map.bindings map)

  (* Uses polymorphic equality on tztraces! *)
  let eq =
    Operation_hash.Map.equal (fun (o1, t1) (o2, t2) ->
        Operation.equal o1 o2 && t1 = t2)
end

type classification_event =
  | Add_if_not_present of
      Classification.classification * Operation_hash.t * Operation.t
  | Remove of Operation_hash.t
  | Flush of bool

let play_event event t =
  let open Classification in
  match event with
  | Add_if_not_present (classification, oph, op) ->
      Generators.add_if_not_present classification oph op t
  | Remove oph -> remove oph t
  | Flush handle_branch_refused ->
      Internal_for_tests.flush ~handle_branch_refused t

module Extra_generators = struct
  open Classification

  (** Generates an [event].
      The operation hash for [Remove] events is generated using
      [with_t_operation_gen] with the given [t].
      The classification, hash and operation for [Add_if_not_present]
      events are generated independently from [t]. *)
  let event_gen t =
    let open QCheck.Gen in
    let add_gen =
      let+ (classification, oph, op) =
        triple
          Generators.classification_gen
          Generators.operation_hash_gen
          Generators.operation_gen
      in
      Add_if_not_present (classification, oph, op)
    in
    let remove_gen =
      let+ (oph, _op) = Generators.with_t_operation_gen t in
      Remove oph
    in
    let flush_gen =
      let+ b = bool in
      Flush b
    in
    (* the weights are chosen so that the total number of classified
       operations may grow before the next flush *)
    frequency [(20, add_gen); (10, remove_gen); (1, flush_gen)]

  (** Generates a record [t_initial] and a sequence of [events].
      The [t] given to each [event_gen] (used to generate the
      operation hash in the case of a [Remove] event) is the [t]
      obtained by having applied all previous events to [t_initial]. *)
  let t_with_event_sequence_gen =
    let open QCheck.Gen in
    Generators.t_gen () >>= fun t ->
    let t_initial = Internal_for_tests.copy t in
    let rec loop acc_gen n =
      if n <= 0 then acc_gen
      else
        let acc =
          let+ event =
            let+ event = event_gen t in
            play_event event t ;
            event
          and+ tl = acc_gen in
          event :: tl
        in
        loop acc (n - 1)
    in
    pair (return t_initial) (loop (return []) 100)
end

let qcheck_eq_true ~actual =
  let _ = qcheck_eq' ~pp:Format.pp_print_bool ~expected:true ~actual () in
  ()

let qcheck_eq_false ~actual =
  let _ = qcheck_eq' ~pp:Format.pp_print_bool ~expected:false ~actual () in
  ()

let qcheck_bounded_map_is_empty bounded_map =
  let actual =
    bounded_map |> Classification.map |> Operation_hash.Map.is_empty
  in
  qcheck_eq_true ~actual

(** Computes the set of operation hashes present in fields [refused; outdated;
    branch_refused; branch_delayed; applied_rev] of [t]. Also checks
    that these fields are disjoint. *)
let disjoint_union_classified_fields ?fail_msg (t : Classification.t) =
  let ( +> ) acc next_set =
    if not (Operation_hash.Set.disjoint acc next_set) then
      QCheck.Test.fail_reportf
        "Invariant 'The fields: [refused; outdated; branch_refused; \
         branch_delayed; applied] are disjoint' broken by t =@.%a@.%s"
        Classification.Internal_for_tests.pp
        t
        (match fail_msg with None -> "" | Some msg -> "\n" ^ msg ^ "@.") ;
    Operation_hash.Set.union acc next_set
  in
  let to_set = Classification.Internal_for_tests.set_of_bounded_map in
  to_set t.refused +> to_set t.outdated +> to_set t.branch_refused
  +> to_set t.branch_delayed
  +> (Operation_hash.Set.of_list @@ List.rev_map fst t.applied_rev)

(** Checks both invariants of type [Prevalidator_classification.t]:
    - The field [in_mempool] is the set of all operation hashes present
      in fields: [refused; outdated; branch_refused; branch_delayed; applied].
    - The fields: [refused; outdated; branch_refused; branch_delayed; applied]
      are disjoint.
    These invariants are enforced by [Prevalidator_classification]
    **as long as the caller does not [add] an operation which is already
    present in [t]**. We use [check_invariants] in tests where we know
    this does not happen.
    Ensuring that the caller behaves correctly would require unit testing
    the [prevalidator] module, which we cannot do at the moment (September
    2021). Instead, we run scenarios which might carry particular risks
    of breaking this using [Tezt]. *)
let check_invariants ?fail_msg (t : Classification.t) =
  let expected_in_mempool = disjoint_union_classified_fields ?fail_msg t in
  if not (Operation_hash.Set.equal expected_in_mempool t.in_mempool) then
    let set_pp ppf set =
      set |> Operation_hash.Set.elements
      |> Format.fprintf ppf "%a" (Format.pp_print_list Operation_hash.pp)
    in
    let set1 = Operation_hash.Set.diff expected_in_mempool t.in_mempool in
    let set2 = Operation_hash.Set.diff t.in_mempool expected_in_mempool in
    let sets_report =
      Format.asprintf
        "In individual fields but not in [in_mempool]:\n\
         %a@.In [in_mempool] but not individual fields:\n\
         %a@."
        set_pp
        set1
        set_pp
        set2
    in
    QCheck.Test.fail_reportf
      "Invariant 'The field [in_mempool] is the set of all operation hashes \
       present in fields: [refused; outdated; branch_refused; branch_delayed; \
       applied]' broken by t =@.%a\n\
       @.%s@.%a@.%s"
      Classification.Internal_for_tests.pp
      t
      sets_report
      Classification.Internal_for_tests.pp_t_sizes
      t
      (match fail_msg with
      | None -> ""
      | Some msg -> Format.sprintf "\n%s@." msg)

let classification_pp pp classification =
  Format.fprintf
    pp
    (match classification with
    | `Applied -> "Applied"
    | `Branch_delayed _ -> "Branch_delayed"
    | `Branch_refused _ -> "Branch_refused"
    | `Refused _ -> "Refused"
    | `Outdated _ -> "Outdated")

let event_pp pp = function
  | Add_if_not_present (classification, oph, _op) ->
      Format.fprintf
        pp
        "Add_if_not_present %a %a"
        classification_pp
        classification
        Operation_hash.pp
        oph
  | Remove oph -> Format.fprintf pp "Remove %a" Operation_hash.pp oph
  | Flush handle_branch_refused ->
      Format.fprintf pp "Flush ~handle_branch_refused:%b" handle_branch_refused

let test_flush_empties_all_except_refused_and_outdated =
  let open QCheck in
  Test.make
    ~name:
      "[flush ~handle_branch_refused:true] empties everything except [refused] \
       and [outdated]"
    (make (Generators.t_gen ()))
  @@ fun t ->
  let refused_before = t.refused |> Classification.map in
  let outdated_before = t.outdated |> Classification.map in
  Classification.Internal_for_tests.flush ~handle_branch_refused:true t ;
  let refused_after = t.refused |> Classification.map in
  let outdated_after = t.outdated |> Classification.map in
  qcheck_bounded_map_is_empty t.branch_refused ;
  qcheck_bounded_map_is_empty t.branch_delayed ;
  qcheck_eq_true ~actual:(t.applied_rev = []) ;
  qcheck_eq'
    ~pp:Operation_map.pp_with_trace
    ~eq:Operation_map.eq
    ~expected:refused_before
    ~actual:refused_after
    ()
  && qcheck_eq'
       ~pp:Operation_map.pp_with_trace
       ~eq:Operation_map.eq
       ~expected:outdated_before
       ~actual:outdated_after
       ()

let test_flush_empties_all_except_refused_and_branch_refused =
  let open QCheck in
  Test.make
    ~name:
      "[flush ~handle_branch_refused:false] empties everything except \
       [refused], [outdated] and [branch_refused]"
    (make (Generators.t_gen ()))
  @@ fun t ->
  let refused_before = t.refused |> Classification.map in
  let outdated_before = t.outdated |> Classification.map in
  let branch_refused_before = t.branch_refused |> Classification.map in
  Classification.Internal_for_tests.flush ~handle_branch_refused:false t ;
  let refused_after = t.refused |> Classification.map in
  let outdated_after = t.outdated |> Classification.map in
  let branch_refused_after = t.branch_refused |> Classification.map in
  let _ =
    qcheck_eq'
      ~pp:Operation_map.pp_with_trace
      ~eq:Operation_map.eq
      ~expected:branch_refused_before
      ~actual:branch_refused_after
      ()
  in
  qcheck_bounded_map_is_empty t.branch_delayed ;
  qcheck_eq_true ~actual:(t.applied_rev = []) ;
  qcheck_eq'
    ~pp:Operation_map.pp_with_trace
    ~eq:Operation_map.eq
    ~expected:refused_before
    ~actual:refused_after
    ()
  && qcheck_eq'
       ~pp:Operation_map.pp_with_trace
       ~eq:Operation_map.eq
       ~expected:outdated_before
       ~actual:outdated_after
       ()

let test_is_in_mempool_remove =
  let open QCheck in
  Test.make
    ~name:"[is_in_mempool] and [remove_*] are well-behaved"
    (make
    @@ Generators.(
         Gen.pair (t_with_operation_gen ()) unrefused_classification_gen))
  @@ fun ((t, (oph, op)), unrefused_classification) ->
  Classification.add unrefused_classification oph op t ;
  qcheck_eq_true ~actual:(Classification.is_in_mempool oph t) ;
  Classification.remove oph t ;
  qcheck_eq_false ~actual:(Classification.is_in_mempool oph t) ;
  true

let test_is_applied =
  let open QCheck in
  Test.make
    ~name:"[is_applied] is well-behaved"
    (make @@ Generators.(Gen.triple (t_gen ()) operation_hash_gen operation_gen))
  @@ fun (t, oph, op) ->
  Classification.add `Applied oph op t ;
  qcheck_eq_true ~actual:(Classification.is_applied oph t) ;
  qcheck_eq_true ~actual:(Classification.is_in_mempool oph t) ;
  Classification.remove oph t ;
  qcheck_eq_false ~actual:(Classification.is_applied oph t) ;
  qcheck_eq_false ~actual:(Classification.is_in_mempool oph t) ;
  true

let test_invariants =
  QCheck.Test.make
    ~name:
      "invariants are preserved through any sequence of events (provided we do \
       not [add] already present operations)"
    (QCheck.make Extra_generators.t_with_event_sequence_gen)
  @@ fun (t, events) ->
  let _ =
    List.fold_left
      (fun (fail_msg, cnt) event ->
        play_event event t ;
        let fail_msg =
          Format.asprintf "%s\n%3d - %a" fail_msg cnt event_pp event
        in
        check_invariants ~fail_msg t ;
        (fail_msg, cnt + 1))
      ("Sequence of events played:", 0)
      events
  in
  true

module Bounded = struct
  type binding = Operation_hash.t * Operation.t

  type custom =
    Classification.t
    * [ `Branch_delayed of tztrace
      | `Branch_refused of tztrace
      | `Refused of tztrace
      | `Outdated of tztrace ]
    * binding list
    * binding list

  let custom_print : custom QCheck.Print.t =
   fun (t, classification, first_bindings, other_bindings) ->
    let classification_string =
      match classification with
      | `Branch_delayed _ -> "Branch_delayed <tztrace>"
      | `Branch_refused _ -> "Branch_refused <tztrace>"
      | `Refused _ -> "Refused <tztrace>"
      | `Outdated _ -> "Outdated <tztrace>"
    in
    let binding_pp ppf bindings =
      bindings
      |> List.map (fun (key, _value) -> key)
      |> Format.pp_print_list Operation_hash.pp ppf
    in
    Format.asprintf
      "Prevalidator_classification.t:@.%a@.Classification:@.%s@.First \
       bindings:@.%a@.Other bindings:@.%a"
      Classification.Internal_for_tests.pp
      t
      classification_string
      binding_pp
      first_bindings
      binding_pp
      other_bindings

  let custom_gen (discarded_operations_rev : Operation_hash.t list ref) :
      custom QCheck.Gen.t =
    let open QCheck.Gen in
    let* map_size_limit = 1 -- 20 in
    let on_discarded_operation oph =
      discarded_operations_rev := oph :: !discarded_operations_rev
    in
    let parameters = Classification.{map_size_limit; on_discarded_operation} in
    let* inputs =
      list_size
        (0 -- map_size_limit)
        Generators.(triple classification_gen operation_hash_gen operation_gen)
    in
    let t = Classification.create parameters in
    List.iter
      (fun (classification, operation_hash, operation) ->
        Classification.add classification operation_hash operation t)
      inputs ;
    let+ error_classification =
      oneofl [`Branch_delayed []; `Branch_refused []; `Refused []; `Outdated []]
    and+ first_bindings =
      list_size (1 -- 10) Generators.(pair operation_hash_gen operation_gen)
    and+ other_bindings =
      list_repeat
        map_size_limit
        Generators.(pair operation_hash_gen operation_gen)
    in
    (t, error_classification, first_bindings, other_bindings)

  let add_bindings bindings classification t =
    List.iter
      (fun (oph, op) -> Classification.add classification oph op t)
      bindings

  let check_discarded_contains_bindings ~discarded_hashes ~bindings =
    let excess_hashes = bindings |> List.map (fun (oph, _op) -> oph) in
    if
      not
        (List.for_all
           (fun excess_hash ->
             List.mem ~equal:Operation_hash.equal excess_hash discarded_hashes)
           excess_hashes)
    then
      let hashes_pp = Format.pp_print_list Operation_hash.pp in
      QCheck.Test.fail_reportf
        "Expected all excess hashes to have been discarded but it was \
         not.@.Excess hashes:@.%a@.Discarded hashes:@.%a"
        hashes_pp
        excess_hashes
        hashes_pp
        discarded_hashes

  let check_map_is_full ~expected_size ~bounded_map =
    if
      Compare.List_length_with.(
        Operation_hash.Map.bindings (Classification.map bounded_map)
        <> expected_size)
    then
      QCheck.Test.fail_reportf
        "Expected bounded_map to be full (size = %i) but its actual size is \
         %i.@.Bounded_map content:@.%a"
        expected_size
        (List.length
           (Operation_hash.Map.bindings (Classification.map bounded_map)))
        Classification.Internal_for_tests.bounded_map_pp
        bounded_map

  let test_bounded =
    let discarded_operations_rev = ref [] in
    QCheck.Test.make
      ~name:
        "When more error operations than the size limit are added, then the \
         first operations are discarded"
      (QCheck.make ~print:custom_print @@ custom_gen discarded_operations_rev)
    @@ fun (t, error_classification, first_bindings, other_bindings) ->
    (* We must not have duplicate operation hashes otherwise we may not go over the bound *)
    let hashes =
      first_bindings @ other_bindings |> List.map (fun (hash, _) -> hash)
    in
    let unique_hashes = Operation_hash.Set.of_list hashes in
    QCheck.assume
      Compare.List_length_with.(
        hashes = Operation_hash.Set.cardinal unique_hashes) ;
    (* Remove all operations for the tested classification *)
    let bounded_map =
      match error_classification with
      | `Branch_delayed _ -> t.branch_delayed
      | `Branch_refused _ -> t.branch_refused
      | `Refused _ -> t.refused
      | `Outdated _ -> t.outdated
    in
    let () =
      Operation_hash.Map.iter
        (fun oph _op -> Classification.remove oph t)
        (Classification.map bounded_map)
    in
    discarded_operations_rev := [] ;
    (* Add the first bindings (the ones that will get discarded once the other bindings are added) *)
    add_bindings
      first_bindings
      (error_classification :> Classification.classification)
      t ;
    (* Now add the other bindings that should cause the first ones to get discarded *)
    add_bindings
      other_bindings
      (error_classification :> Classification.classification)
      t ;
    (* [add] calls [on_discarded_operation] when adding any [Refused] or
       [Outdated] operation, so the recorded discarded operations is a superset
       of the [first_bindings] ones. *)
    check_discarded_contains_bindings
      ~discarded_hashes:(!discarded_operations_rev |> List.rev)
      ~bindings:first_bindings ;
    check_map_is_full ~expected_size:t.parameters.map_size_limit ~bounded_map ;
    true
end

(** Tests of [Prevalidator_classification.to_map] *)
module To_map = struct
  let map_pp fmt x =
    let map_to_list m = Operation_hash.Map.to_seq m |> List.of_seq in
    let pp_pair fmt (oph, op) =
      Format.fprintf fmt "%a:%a" Operation_hash.pp oph Operation.pp op
    in
    Format.fprintf fmt "%a" (Format.pp_print_list pp_pair) (map_to_list x)

  let map_eq = Operation_hash.Map.equal Operation.equal

  (** [remove_all m1 m2] returns the subset of [m1] thas is not within [m2].
      Said differently, [remove_all m1 m2] removes from [m1] all keys
      that are in [m2]. *)
  let remove_all m1 m2 =
    let keys2 =
      Operation_hash.Map.bindings m2
      |> List.map fst |> Operation_hash.Set.of_list
    in
    Operation_hash.Map.filter
      (fun key _val -> not (Operation_hash.Set.mem key keys2))
      m1

  (** [eq_mod_binding m1 (k, v_opt) m2] holds iff:

      - [m1] equals [m2], or
      - [v_opt] is [Some v] and the union of [m1] and [(k,v)] equals [m2], or
      - [v_opt] is [None] and the union of [m1] and [(k,v)] equals [m2],
        for some unknown value [v]. *)
  let eq_mod_binding m1 (k, v_opt) m2 =
    let diff = remove_all m2 m1 in
    match (Operation_hash.Map.bindings diff, v_opt) with
    | ([], _) -> true
    | ([(kdiff, vdiff)], Some v)
      when Operation_hash.equal kdiff k && Operation.equal v vdiff ->
        true
    | ([(kdiff, _)], None) when Operation_hash.equal kdiff k -> true
    | _ -> false

  (** [to_map_all] calls [Classification.to_map] with all named
      arguments set to [true] *)
  let to_map_all =
    Classification.Internal_for_tests.to_map
      ~applied:true
      ~branch_delayed:true
      ~branch_refused:true
      ~refused:true
      ~outdated:true

  (** Tests the relationship between [Classification.create]
      and [Classification.to_map] *)
  let test_create =
    QCheck.Test.make
      ~name:"[to_map_all (create params)] is empty"
      (QCheck.make Generators.parameters_gen)
    @@ fun parameters ->
    let t = Classification.create parameters in
    qcheck_eq'
      ~pp:map_pp
      ~eq:map_eq
      ~expected:Operation_hash.Map.empty
      ~actual:(to_map_all t)
      ()

  (** Tests the relationship between [Classification.add]
      and [Classification.to_map] *)
  let test_add =
    QCheck.Test.make
      ~name:"[add] extends the size of [to_map] by 0 or 1"
      (QCheck.make
         (QCheck.Gen.pair
            (Generators.t_with_operation_gen ())
            Generators.classification_gen))
    @@ fun ((t, (oph, op)), classification) ->
    let initial = to_map_all t in
    Classification.add classification oph op t ;
    (* We need to use [eq_mod_binding] because it covers the two possible cases:
       if [oph] is not in [initial], we have [initial @@ [(oph, op)] = to_map_all t]
       if [oph] is in [initial] already, we have [initial = to_map_all t] *)
    qcheck_eq'
      ~expected:true
      ~actual:(eq_mod_binding initial (oph, Some op) (to_map_all t))
      ()

  (** Tests the relationship between [Classification.remove]
      and [Classification.to_map] *)
  let test_remove =
    QCheck.Test.make
      ~name:"[remove] reduces the size of [to_map] by 0 or 1"
      (QCheck.make (Generators.t_with_operation_gen ()))
    @@ fun (t, (oph, _)) ->
    let initial = to_map_all t in
    Classification.remove oph t ;
    (* We need to use [eq_mod_binding] because it covers the two possible cases:
       if [oph] is not in [initial], we have [initial = to_map_all t]
       if [oph] is in [initial], we have [initial = to_map_all t @@ [(oph, op)] ] *)
    qcheck_eq'
      ~expected:true
      ~actual:(eq_mod_binding (to_map_all t) (oph, None) initial)
      ()

  let test_map_remove_add =
    let to_string ((t, (oph, _op)), _classification) =
      Format.asprintf
        "Starting with:@. %a@.and operation hash %a@. "
        Operation_map.pp
        (to_map_all t)
        Operation_hash.pp
        oph
    in
    (* Property checked:

       - \forall t oph class, C.to_map (C.remove t oph) + oph =
       C.to_map (C.add t oph class)

       where (+)/(-) are add/remove over maps.

       This property is true only if [t] is not full with regard to
       the classification of the operation. *)
    QCheck.Test.make
      ~name:"Check property between map, remove and add (1)"
      ~count:1000
      (QCheck.make
         ~print:to_string
         (QCheck.Gen.pair
            (Generators.t_with_operation_gen ~can_be_full:false ())
            Generators.classification_gen))
    @@ fun ((t, (oph, op)), classification) ->
    let t' = Classification.Internal_for_tests.copy t in
    Classification.remove oph t ;
    let initial = to_map_all t in
    let left = Operation_hash.Map.add oph op initial in
    Classification.add classification oph op t' ;
    let right = to_map_all t' in
    qcheck_eq'
      ~expected:left
      ~actual:right
      ~eq:(Operation_hash.Map.equal Operation.equal)
      ~pp:map_pp
      ()

  let test_map_add_remove =
    (* Property checked:

       - \forall t oph class, C.to_map (C.add t oph class) - oph =
       C.to_map (C.remove t oph)

       where (+)/(-) are add/remove over maps.

       This property is true only if [t] is not full with regard to
       the classification of the operation. *)
    let to_string ((t, (oph, _op)), _classification) =
      Format.asprintf
        "Starting with:@. %a@.and operation hash %a@. "
        Operation_map.pp
        (to_map_all t)
        Operation_hash.pp
        oph
    in
    QCheck.Test.make
      ~name:"Check property between map, remove and add (2)"
      (QCheck.make
         ~print:to_string
         (QCheck.Gen.pair
            (Generators.t_with_operation_gen ~can_be_full:false ())
            Generators.classification_gen))
    @@ fun ((t, (oph, op)), classification) ->
    let t' = Classification.Internal_for_tests.copy t in
    Classification.add classification oph op t ;
    let initial = to_map_all t in
    let left = Operation_hash.Map.remove oph initial in
    Classification.remove oph t' ;
    let right = to_map_all t' in
    qcheck_eq'
      ~expected:left
      ~actual:right
      ~eq:(Operation_hash.Map.equal Operation.equal)
      ~pp:map_pp
      ()

  (** Tests the relationship between [Classification.flush]
      and [Classification.to_map] *)
  let test_flush =
    QCheck.Test.make
      ~name:"[flush] can be emulated by [to_map ~refused:true ..]"
      (QCheck.make (QCheck.Gen.pair (Generators.t_gen ()) QCheck.Gen.bool))
    @@ fun (t, handle_branch_refused) ->
    let initial =
      Classification.Internal_for_tests.to_map
        ~applied:false
        ~branch_delayed:false
        ~branch_refused:(not handle_branch_refused)
        ~refused:true
        ~outdated:true
        t
    in
    Classification.Internal_for_tests.flush ~handle_branch_refused t ;
    let flushed = to_map_all t in
    qcheck_eq' ~pp:map_pp ~eq:map_eq ~expected:initial ~actual:flushed ()

  (** Tests the relationship between [Classification.is_applied]
      and [Classification.to_map] *)
  let test_is_applied =
    QCheck.Test.make
      ~name:"[is_applied] can be emulated by [to_map ~applied:true]"
      (QCheck.make (Generators.t_with_operation_gen ()))
    @@ fun (t, (oph, _)) ->
    let is_applied = Classification.is_applied oph t in
    let map =
      Classification.Internal_for_tests.to_map
        ~applied:true
        ~branch_delayed:false
        ~branch_refused:false
        ~refused:false
        ~outdated:false
        t
      |> Operation_hash.Map.filter (fun oph' _val -> oph' = oph)
    in
    qcheck_eq'
      ~expected:is_applied
      ~actual:(Operation_hash.Map.cardinal map = 1)
      ()

  (** Tests the relationship between [Classification.is_in_mempool]
      and [Classification.to_map] *)
  let test_is_in_mempool =
    QCheck.Test.make
      ~name:"[is_in_mempool] can be emulated by [to_map]"
      (QCheck.make (Generators.t_with_operation_gen ()))
    @@ fun (t, (oph, _)) ->
    let is_in_mempool = Classification.is_in_mempool oph t in
    let map =
      to_map_all t |> Operation_hash.Map.filter (fun oph' _ -> oph' = oph)
    in
    qcheck_eq'
      ~expected:is_in_mempool
      ~actual:(Operation_hash.Map.cardinal map = 1)
      ()

  (** Tests that [Classification.to_map] returns an empty map if all parameters
      are set to [false]  *)
  let test_none =
    QCheck.Test.make
      ~name:"[to_map] returns an empty map if all parameters are set to [false]"
      (QCheck.make (Generators.t_gen ()))
    @@ fun t ->
    qcheck_eq'
      ~pp:map_pp
      ~eq:map_eq
      ~expected:Operation_hash.Map.empty
      ~actual:
        (Classification.Internal_for_tests.to_map
           ~applied:false
           ~branch_delayed:false
           ~branch_refused:false
           ~refused:false
           ~outdated:false
           t)
      ()
end

let () =
  let mk_tests label tests = (label, qcheck_wrap tests) in
  Alcotest.run
    "Prevalidator_classification"
    [
      mk_tests
        "flush"
        [
          test_flush_empties_all_except_refused_and_outdated;
          test_flush_empties_all_except_refused_and_branch_refused;
        ];
      mk_tests "is_in_mempool" [test_is_in_mempool_remove];
      mk_tests "is_applied" [test_is_applied];
      mk_tests "invariants" [test_invariants];
      mk_tests "bounded" [Bounded.test_bounded];
      mk_tests
        "to_map"
        To_map.
          [
            test_create;
            test_add;
            test_remove;
            test_map_remove_add;
            test_map_add_remove;
            test_flush;
            test_is_applied;
            test_is_in_mempool;
            test_none;
          ];
    ]

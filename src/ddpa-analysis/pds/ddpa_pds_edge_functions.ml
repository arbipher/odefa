open Batteries;;
open Jhupllib;;

open Core_ast;;
open Ddpa_abstract_ast;;
open Ddpa_abstract_stores;;
open Ddpa_graph;;
open Ddpa_utils;;

let logger = Logger_utils.make_logger "Ddpa_pds_edge_functions";;
let lazy_logger = Logger_utils.make_lazy_logger "Ddpa_pds_edge_functions";;

module Make
    (Store_ops : Ddpa_abstract_stores.Ops.Sig)
    (Struct : (module type of Ddpa_pds_structure_types.Make(Store_ops))
     with module Store_ops = Store_ops)
    (T : (module type of Ddpa_pds_dynamic_pop_types.Make(Store_ops)(Struct))
     with module Store_ops = Store_ops
      and module Struct = Struct)
    (B : Pds_reachability_basis.Basis)
    (R : Pds_reachability_analysis.Analysis
     with type State.t = Struct.Pds_state.t
      and type Stack_element.t = Struct.Pds_continuation.t
      and type Targeted_dynamic_pop_action.t = T.pds_targeted_dynamic_pop_action)
=
struct
  open Struct;;
  open T;;
  open R.Stack_action.T;;
  open R.Terminus.T;;

  (**
     Creates a PDS edge function for a particular DDPA graph edge.  The
     resulting function produces transitions for PDS states, essentially serving
     as the first step toward implementing each DDPA rule.  The remaining steps
     are addressed by the dynamic pop handler, which performs the closure of the
     dynamic pops generated by this function.
  *)
  let create_edge_function
      (store_registry : Abstract_store_witness_registry.t)
      (edge : ddpa_edge) (state : R.State.t)
    : (R.Stack_action.t list * R.Terminus.t) Enum.t =
    (* Unpack the edge *)
    let Ddpa_edge(acl1, acl0) = edge in
    (* Generate PDS edge functions for this DDPA edge *)
    Logger_utils.lazy_bracket_log (lazy_logger `trace)
      (fun () -> Printf.sprintf "DDPA %s edge function at state %s"
          (show_ddpa_edge edge) (Pds_state.show state))
      (fun edges ->
         let string_of_output (actions,target) =
           String_utils.string_of_tuple
             (String_utils.string_of_list R.Stack_action.show)
             R.Terminus.show
             (actions,target)
         in
         Printf.sprintf "Generates edges: %s"
           (String_utils.string_of_list string_of_output @@
            List.of_enum @@ Enum.clone edges)) @@
    fun () ->
    let zero = Enum.empty in
    let%orzero Program_point_state acl0' = state in
    (* TODO: There should be a way to associate each edge function with
             its corresponding acl0 rather than using this guard. *)
    [%guard (compare_annotated_clause acl0 acl0' == 0) ];
    (* Define functions to produce the action tuples we want. *)
    let zero = Enum.empty in
    let dynpop action state =
      Enum.singleton ([Pop_dynamic_targeted(action)], Static_terminus state)
    in
    let nop state = Enum.singleton ([], Static_terminus state) in
    let static ops state = Enum.singleton (ops,Static_terminus state) in
    let alternatives xs = Enum.concat @@ List.enum xs in
    (* Define the actions for each rule. *)
    Enum.concat @@ List.enum
      [
        (* ********** Store Processing ********** *)
        (* Discovered Store *)
        begin
          dynpop Discovered_store_2_of_2 @@ Program_point_state acl0
        end
        ;
        (* Intermediate Store *)
        begin
          dynpop Intermediate_store @@ Program_point_state acl0
        end
        ;
        (* Store Suffix *)
        begin
          dynpop Store_suffix_1_of_2 @@ Program_point_state acl0
        end
        ;
        (* Store Parallel Join *)
        begin
          dynpop Store_parallel_join_1_of_3 @@ Program_point_state acl0
        end
        ;
        (* Store Serial Join *)
        begin
          dynpop Store_serial_join_1_of_3 @@ Program_point_state acl0
        end
        ;
        (* Store Alias *)
        begin
          dynpop Store_alias_1_of_3 @@ Program_point_state acl0
        end
        ;
        (* ********** Variable Search ********** *)
        (* Value Discovery *)
        begin
          let%orzero
            Unannotated_clause(Abs_clause(x,Abs_value_body v)) = acl1
          in
          let sw =
            Abstract_store_witness_registry.escorted_witness_of
              store_registry (Store_ops.store_singleton x v)
          in
          static
            [ Pop(Lookup_var x)
            ; Push(Continuation_store(sw))
            ]
            (Program_point_state acl1)
        end
        ;
        (* Value Alias *)
        begin
          let%orzero
            Unannotated_clause(Abs_clause(x,Abs_var_body x')) = acl1
          in
          static
            [ Pop(Lookup_var x)
            ; Push(Lookup_var x')
            ]
            (Program_point_state acl1)
        end
        ;
        (* Stateless Clause Skip *)
        begin
          let%orzero Unannotated_clause(Abs_clause(x',_)) = acl1 in
          dynpop (Stateless_clause_skip_1_of_2 x') @@ Program_point_state acl1
        end
        ;
        (* Block Marker Skip *)
        begin
          match acl1 with
          | Start_clause _ | End_clause _ -> nop @@ Program_point_state acl1
          | _ -> zero ()
        end
        ;
        (* ********** Navigation ********** *)
        (* Jump *)
        (* [[ this rule is handled by untargeted dynamic pops ]] *)
        (* Capture *)
        begin
          dynpop Capture_1_of_3 (Program_point_state acl0)
        end
        ;
        (* Rewind *)
        (* [[ this rule is handled by untargeted dynamic pops ]] *)
        (* ********** Function Wiring ********** *)
        (* Function Top: Parameter Variable *)
        begin
          let%orzero Enter_clause(x,x',c) = acl1 in
          let%orzero Abs_clause(_,Abs_appl_body(x2'',x0')) = c in
          [%guard equal_abstract_var x' x0'];
          static
            [ Pop(Lookup_var x)
            ; Push(Alias(x))
            ; Push(Trace_concat(Trace_enter c))
            ; Push Parallel_join
            ; Push(Lookup_var x')
            ; Push (Jump acl1)
            ; Push (Capture(Struct.Bounded_capture_size.of_int 3))
            ; Push(Lookup_var x2'')
            ; Push (Jump acl1)
            ; Push (Capture(Struct.Bounded_capture_size.of_int 8))
            ; Push(Lookup_var x')
            ]
            (Program_point_state acl1)
        end
        ;
        (* Function Bottom: Flow Check *)
        begin
          let%orzero Exit_clause(x,_,c) = acl1 in
          let%orzero Abs_clause(x0,Abs_appl_body(x2'',x3'')) = c in
          [%guard equal_abstract_var x x0];
          static
            [ Pop (Lookup_var x)
            ; Push (Lookup_var x)
            ; Push Real_flow_huh
            ; Push (Jump acl0)
            ; Push (Capture(Struct.Bounded_capture_size.of_int 2))
            ; Push Parallel_join
            ; Push (Lookup_var x2'')
            ; Push (Jump (Unannotated_clause c))
            ; Push (Capture(Struct.Bounded_capture_size.of_int 3))
            ; Push (Lookup_var x3'')
            ]
            (Program_point_state(Unannotated_clause c))
        end
        ;
        (* Function Bottom: Return Variable *)
        begin
          let%orzero Exit_clause(x,x',c) = acl1 in
          let%orzero Abs_clause(x0,Abs_appl_body(_,_)) = c in
          [%guard equal_abstract_var x x0];
          static
            [ Pop Real_flow_huh
            ; Pop_dynamic_targeted (Function_bottom_return_variable(x,x',c))
            ]
            (Program_point_state acl1)
        end
        ;
        (* Function Top: Non-Local Variable *)
        begin
          let%orzero Enter_clause(x'',x',c) = acl1 in
          let%orzero Abs_clause(_,Abs_appl_body(_,x3'')) = c in
          [%guard equal_abstract_var x' x3''];
          dynpop
            (Function_top_nonlocal_variable(x'',c,acl1))
            (Program_point_state acl1)
        end
        ;
        (* ********** Conditional Wiring ********** *)
        (* Conditional Top: Subject Positive *)
        begin
          let%orzero Enter_clause(x',x1,c) = acl1 in
          let%orzero Abs_clause(_,Abs_conditional_body(x1_,p,f1,_)) = c in
          [%guard equal_abstract_var x1 x1_];
          let Abs_function_value(xf,_) = f1 in
          [%guard equal_abstract_var x' xf];
          alternatives
            [ static
                [ Pop (Lookup_var x')
                ; Push (Continuation_matches p)
                ; Push (Lookup_var x1)
                ]
                (Program_point_state acl1)
            ; static
                [ Pop (Lookup_var x1)
                ; Push (Continuation_matches p)
                ; Push (Lookup_var x1)
                ]
                (Program_point_state acl1)
            ]
        end
        ;
        (* Conditional Top: Subject Negative *)
        begin
          let%orzero Enter_clause(x',x1,c) = acl1 in
          let%orzero Abs_clause(_,Abs_conditional_body(x1_,p,_,f2)) = c in
          [%guard equal_abstract_var x1 x1_];
          let Abs_function_value(xf,_) = f2 in
          [%guard equal_abstract_var x' xf];
          alternatives
            [ static
                [ Pop (Lookup_var x')
                ; Push (Continuation_antimatches p)
                ; Push (Lookup_var x1)
                ]
                (Program_point_state acl1)
            ; static
                [ Pop (Lookup_var x1)
                ; Push (Continuation_antimatches p)
                ; Push (Lookup_var x1)
                ]
                (Program_point_state acl1)
            ]
        end
        ;
        (* Conditional Top: Non-Subject Variable Positive *)
        begin
          let%orzero Enter_clause(x',x1,c) = acl1 in
          let%orzero Abs_clause(_,Abs_conditional_body(x1_,p,f1,_)) = c in
          [%guard equal_abstract_var x1 x1_];
          let Abs_function_value(xf,_) = f1 in
          [%guard equal_abstract_var x' xf];
          dynpop
            (Conditional_top_nonsubject_variable_positive(x',x1,acl1,p))
            (Program_point_state (Unannotated_clause c))
        end
        ;
        (* Conditional Top: Non-Subject Variable Negative *)
        begin
          let%orzero Enter_clause(x',x1,c) = acl1 in
          let%orzero Abs_clause(_,Abs_conditional_body(x1_,p,_,f2)) = c in
          [%guard equal_abstract_var x1 x1_];
          let Abs_function_value(xf,_) = f2 in
          [%guard equal_abstract_var x' xf];
          dynpop
            (Conditional_top_nonsubject_variable_negative(x',x1,acl1,p))
            (Program_point_state (Unannotated_clause c))
        end
        ;
        (* Conditional Bottom: Return Positive *)
        begin
          let%orzero Exit_clause(x,x',c) = acl1 in
          let%orzero Abs_clause(x_,Abs_conditional_body(x1,p,f1,_)) = c in
          [%guard equal_abstract_var x x_];
          let Abs_function_value(_,Abs_expr(cls)) = f1 in
          let x'_ = rv cls in
          [%guard equal_abstract_var x' x'_];
          static
            [ Pop (Lookup_var x)
            ; Push Parallel_join
            ; Push (Lookup_var x')
            ; Push (Jump acl1)
            ; Push (Capture (Struct.Bounded_capture_size.of_int 3))
            ; Push (Continuation_matches p)
            ; Push (Lookup_var x1)
            ]
            (Program_point_state(Unannotated_clause c))
        end
        ;
        (* Conditional Bottom: Return Negative *)
        begin
          let%orzero Exit_clause(x,x',c) = acl1 in
          let%orzero Abs_clause(x_,Abs_conditional_body(x1,p,_,f2)) = c in
          [%guard equal_abstract_var x x_];
          let Abs_function_value(_,Abs_expr(cls)) = f2 in
          let x'_ = rv cls in
          [%guard equal_abstract_var x' x'_];
          static
            [ Pop (Lookup_var x)
            ; Push Parallel_join
            ; Push (Lookup_var x')
            ; Push (Jump acl1)
            ; Push (Capture (Struct.Bounded_capture_size.of_int 3))
            ; Push (Continuation_antimatches p)
            ; Push (Lookup_var x1)
            ]
            (Program_point_state(Unannotated_clause c))
        end
        ;
        (* ********** Record Construction/Destruction ********** *)
        (* Record Projection Start *)
        begin
          let%orzero
            Unannotated_clause(Abs_clause(x,Abs_projection_body(x',l))) = acl1
          in
          static
            [ Pop (Lookup_var x)
            ; Push (Project l)
            ; Push (Lookup_var x')
            ]
            (Program_point_state acl1)
        end
        ;
        (* Record Projection Stop *)
        begin
          dynpop Record_projection_stop_1_of_2 @@ Program_point_state acl0
        end
        ;
        (* Filter Immediate Positive
           Filter Immediate Negative
           Filter Empty Record Positive
           Filter Empty Record Negative *)
        begin
          dynpop Filter_immediate_1_of_2 @@ Program_point_state acl0
        end
        ;
        (* Filter Nonempty Record Positive *)
        begin
          dynpop
            (Filter_nonempty_record_positive_1_of_2 acl0)
            (Program_point_state acl0)
        end
        ;
        (* Filter Nonempty Record Negative: Missing Label
           Filter Nonempty Record Negative: Refutable Label *)
        begin
          dynpop
            (Filter_nonempty_record_negative_1_of_2 acl0)
            (Program_point_state acl0)
        end
        ;
        (* ********** State ********** *)
        (* Update Is Empty Record *)
        begin
          let%orzero
            Unannotated_clause(Abs_clause(x, Abs_update_body _)) = acl1
          in
          let empty_record =
            Abs_value_record(Abs_record_value(Ident_map.empty))
          in
          let sw =
            Abstract_store_witness_registry.escorted_witness_of
              store_registry (Store_ops.store_singleton x empty_record)
          in
          static
            [ Pop (Lookup_var x)
            ; Push (Continuation_store sw)
            ]
            (Program_point_state acl1)
        end
        ;
        (* Dereference Start *)
        begin
          let%orzero
            Unannotated_clause(Abs_clause(x, Abs_deref_body x')) = acl1
          in
          static
            [ Pop (Lookup_var x)
            ; Push Deref
            ; Push (Lookup_var x')
            ]
            (Program_point_state acl1)
        end
        ;
        (* Dereference Stop *)
        begin
          dynpop Dereference_stop @@ Program_point_state acl0
        end
        ;
        (* ********** Alias Analysis (State) ********** *)
        (* Alias Analysis Start *)
        begin
          let%orzero
            Unannotated_clause (Abs_clause(_, Abs_update_body _)) = acl1
          in
          dynpop
            (Alias_analysis_start(acl1,acl0))
            (Program_point_state acl1)
        end
        ;
        (* May Not Alias *)
        begin
          let%orzero
            Unannotated_clause (Abs_clause(_, Abs_update_body _)) = acl1
          in
          static
            [ Pop Alias_huh
            ; Pop_dynamic_targeted May_not_alias_1_of_3
            ]
            (Program_point_state acl1)
        end
        ;
        (* May Alias *)
        begin
          let%orzero
            Unannotated_clause (Abs_clause(_, Abs_update_body(_,x2'))) = acl1
          in
          static
            [ Pop Alias_huh
            ; Pop_dynamic_targeted (May_alias_1_of_3 x2')
            ]
            (Program_point_state acl1)
        end
        ;
        (* ********** Side Effect Search (State) ********** *)
        (* Stateful Immediate Clause Skip *)
        begin
          let%orzero Unannotated_clause(Abs_clause(x'', _)) = acl1 in
          [%guard is_immediate acl1 && not (is_stateful_update acl1)];
          dynpop
            (Stateful_immediate_clause_skip x'')
            (Program_point_state acl1)
        end
        ;
        (* Side Effect Search Start: Function Flow Check *)
        begin
          let%orzero Exit_clause(_,_,c) = acl1 in
          let%orzero Abs_clause(_,Abs_appl_body _) = c in
          dynpop
            (Side_effect_search_start_function_flow_check(acl1,acl0))
            (Program_point_state (Unannotated_clause c))
        end
        ;
        (* Side Effect Search Start: Function Flow Validated *)
        begin
          let%orzero Exit_clause(_,_,c) = acl1 in
          let%orzero Abs_clause(_,Abs_appl_body _) = c in
          static
            [ Pop Real_flow_huh
            ; Pop_dynamic_targeted
                (Side_effect_search_start_function_flow_validated_1_of_2(
                    acl1,acl0))
            ]
            (Program_point_state acl1)
        end
        ;
        (* Side Effect Search Start: Conditional Positive *)
        begin
          let%orzero Exit_clause(_,x',c) = acl1 in
          let%orzero Abs_clause(_,Abs_conditional_body(_,_,f1,_)) = c in
          let Abs_function_value(_,Abs_expr(cls)) = f1 in
          [%guard equal_abstract_var x' @@ rv cls];
          dynpop
            (Side_effect_search_start_conditional_positive(acl1,acl0))
            (Program_point_state (Unannotated_clause c))
        end
        ;
        (* Side Effect Search Start: Conditional Negative *)
        begin
          let%orzero Exit_clause(_,x',c) = acl1 in
          let%orzero Abs_clause(_,Abs_conditional_body(_,_,_,f2)) = c in
          let Abs_function_value(_,Abs_expr(cls)) = f2 in
          [%guard equal_abstract_var x' @@ rv cls];
          dynpop
            (Side_effect_search_start_conditional_negative(acl1,acl0))
            (Program_point_state (Unannotated_clause c))
        end
        ;
        (* Side Effect Search Immediate Clause Skip *)
        begin
          [%guard is_immediate acl1 && not (is_stateful_update acl1)];
          dynpop
            Side_effect_search_immediate_clause_skip
            (Program_point_state acl1)
        end
        ;
        (* Side Effect Search: Function Bottom: Flow Check *)
        begin
          let%orzero Exit_clause(_,_,c) = acl1 in
          let%orzero Abs_clause(_,Abs_appl_body _) = c in
          dynpop
            (Side_effect_search_function_bottom_flow_check(acl0,c))
            (Program_point_state(Unannotated_clause c))
        end
        ;
        (* Side Effect Search: Function Bottom: Return Variable *)
        begin
          let%orzero Exit_clause(_,_,c) = acl1 in
          let%orzero Abs_clause(_,Abs_appl_body _) = c in
          static
            [ Pop Real_flow_huh
            ; Pop_dynamic_targeted(
                Side_effect_search_function_bottom_return_variable_1_of_2(acl1))
            ]
            (Program_point_state acl1)
        end
        ;
        (* Side Effect Search: Function Top *)
        begin
          let%orzero Enter_clause(_,_,c) = acl1 in
          let%orzero Abs_clause(_,Abs_appl_body _) = c in
          dynpop
            (Side_effect_search_function_top c)
            (Program_point_state acl1)
        end
        ;
        (* Side Effect Search: Conditional Positive *)
        begin
          let%orzero Exit_clause(_,x',c) = acl1 in
          let%orzero Abs_clause(_,Abs_conditional_body(_,_,f1,_)) = c in
          let Abs_function_value(_,Abs_expr cls) = f1 in
          [%guard equal_abstract_var x' @@ rv cls];
          dynpop
            (Side_effect_search_conditional_positive acl1)
            (Program_point_state acl1)
        end
        ;
        (* Side Effect Search: Conditional Negative *)
        begin
          let%orzero Exit_clause(_,x',c) = acl1 in
          let%orzero Abs_clause(_,Abs_conditional_body(_,_,f1,_)) = c in
          let Abs_function_value(_,Abs_expr cls) = f1 in
          [%guard equal_abstract_var x' @@ rv cls];
          dynpop
            (Side_effect_search_conditional_negative acl1)
            (Program_point_state acl1)
        end
        ;
        (* Side Effect Search: Conditional Top *)
        begin
          let%orzero Enter_clause(_,_,c) = acl1 in
          let%orzero Abs_clause(_,Abs_conditional_body _) = c in
          dynpop Side_effect_search_conditional_top (Program_point_state acl1)
        end
        ;
        (* Side Effect Search: Function Wiring Join Defer *)
        begin
          let%orzero Enter_clause _ = acl1 in
          dynpop
            Side_effect_search_function_wiring_join_defer_1_of_3
            (Program_point_state acl0)
        end
        ;
        (* Side Effect Search: Conditional Wiring Join Defer *)
        begin
          let%orzero Enter_clause _ = acl1 in
          dynpop
            Side_effect_search_conditional_wiring_join_defer_1_of_2
            (Program_point_state acl0)
        end
        ;
        (* Side Effect Search: Join Compression *)
        begin
          let%orzero Enter_clause _ = acl1 in
          dynpop
            Side_effect_search_join_compression_1_of_3
            (Program_point_state acl0)
        end
        ;
        (* Side Effect Search: Alias Analysis Start *)
        begin
          let%orzero
            Unannotated_clause(Abs_clause(_,Abs_update_body _)) = acl1
          in
          dynpop
            (Side_effect_search_alias_analysis_start(acl1,acl0))
            (Program_point_state acl1)
        end
        ;
        (* Side Effect Search: May Not Alias *)
        begin
          let%orzero
            Unannotated_clause (Abs_clause(_, Abs_update_body _)) = acl1
          in
          static
            [ Pop Alias_huh
            ; Pop_dynamic_targeted Side_effect_search_may_not_alias_1_of_3
            ]
            (Program_point_state acl1)
        end
        ;
        (* Side Effect Search: May Alias *)
        begin
          let%orzero
            Unannotated_clause (Abs_clause(_, Abs_update_body(_,x2'))) = acl1
          in
          static
            [ Pop Alias_huh
            ; Pop_dynamic_targeted (Side_effect_search_may_alias_1_of_3 x2')
            ]
            (Program_point_state acl1)
        end
        ;
        (* Side Effect Search Escape: Frame *)
        begin
          dynpop Side_effect_search_escape_frame (Program_point_state acl0)
        end
        ;
        (* Side Effect Search Escape: Variable Concatenation *)
        begin
          dynpop
            Side_effect_search_escape_variable_concatenation_1_of_2
            (Program_point_state acl0)
        end
        ;
        (* Side Effect Search Escape: Store Join *)
        begin
          dynpop
            Side_effect_search_escape_store_join_1_of_2
            (Program_point_state acl0)
        end
        ;
        (* Side Effect Search Escape: Complete *)
        begin
          (* NOTE: There's a bit of a stunt going on here.  The reachability
             analysis doesn't actually support an untargeted pop on the end of
             a targeted pop chain, so we're just going to use the jump operation
             to get around this.  The program point specified below is therefore
             meaningless. *)
          dynpop
            Side_effect_search_escape_complete_1_of_3
            (Program_point_state acl0)
        end
        ;
        (* Side Effect Search: Not Found (Shallow) *)
        begin
          dynpop
            Side_effect_search_not_found_shallow_1_of_2
            (Program_point_state acl0)
        end
        ;
        (* Side Effect Search: Not Found (Deep) *)
        begin
          dynpop
            Side_effect_search_not_found_deep_1_of_4
            (Program_point_state acl0)
        end
        ;
        (* ********** Operations ********** *)
        (* Binary Operation Start *)
        begin
          let%orzero
            Unannotated_clause(
              Abs_clause(x1,Abs_binary_operation_body(x2,_,x3))) = acl1
          in
          static
            [ Pop (Lookup_var x1)
            ; Push Binary_operation
            ; Push (Jump acl0)
            ; Push (Capture (Struct.Bounded_capture_size.of_int 2))
            ; Push (Lookup_var x3)
            ; Push (Jump acl1)
            ; Push (Capture (Struct.Bounded_capture_size.of_int 5))
            ; Push (Lookup_var x2 )
            ]
            (Program_point_state acl1)
        end
        ;
        (* Binary Operation Stop *)
        begin
          let%orzero
            Unannotated_clause(
              Abs_clause(x1,Abs_binary_operation_body(_,op,_))) = acl1
          in
          static
            [ Pop Binary_operation
            ; Pop_dynamic_targeted (Binary_operation_stop_1_of_2(x1,op))
            ]
            (Program_point_state acl1)
        end
        ;
        (* Unary Operation Start *)
        begin
          let%orzero
            Unannotated_clause(
              Abs_clause(x1,Abs_unary_operation_body(_,x2))) = acl1
          in
          static
            [ Pop (Lookup_var x1)
            ; Push Unary_operation
            ; Push (Jump acl0)
            ; Push (Capture (Struct.Bounded_capture_size.of_int 2))
            ; Push (Lookup_var x2)
            ]
            (Program_point_state acl1)
        end
        ;
        (* Unary Operation Stop *)
        begin
          let%orzero
            Unannotated_clause(
              Abs_clause(x1,Abs_unary_operation_body(op,_))) = acl1
          in
          static
            [ Pop Unary_operation
            ; Pop_dynamic_targeted (Unary_operation_stop(x1,op))
            ]
            (Program_point_state acl1)
        end
      ]
  ;;

  let create_untargeted_dynamic_pop_action_function
      (eobm : End_of_block_map.t) (edge : ddpa_edge) (state : R.State.t) =
    let Ddpa_edge(_, acl0) = edge in
    let zero = Enum.empty in
    let%orzero Program_point_state acl0' = state in
    (* TODO: There should be a way to associate each action function with
             its corresponding acl0 rather than using this guard. *)
    [%guard (compare_annotated_clause acl0 acl0' == 0)];
    let open Option.Monad in
    let untargeted_dynamic_pops = Enum.filter_map identity @@ List.enum
        [
          (* Store Processing: Discovered Store *)
          begin
            return @@ Discovered_store_1_of_2
          end
          ;
          (* Navigation: Jump. *)
          begin
            return @@ Do_jump
          end
          ;
          (* Nagivation: Rewind *)
          (*
            To rewind, we need to know the "end-of-block" for the node we are
            considering.  We have a dictionary mapping all of the *abstract*
            clauses in the program to their end-of-block clauses, but we don't
            have such mappings for e.g. wiring nodes or block start/end nodes.
            This code runs for *every* edge, so we need to skip those cases
            for which our mappings don't exist.  It's safe to skip all
            non-abstract-clause nodes, since we only rewind after looking up
            a function to access its closure and the only nodes that can
            complete a lookup are abstract clause nodes.
          *)
          match acl0 with
          | Unannotated_clause cl0 ->
            begin
              match Annotated_clause_map.Exceptionless.find acl0 eobm with
              | Some end_of_block ->
                return @@ Do_rewind end_of_block
              | None ->
                raise @@ Utils.Invariant_failure(
                  Printf.sprintf
                    "Abstract clause lacks end-of-block mapping: %s"
                    (show_abstract_clause cl0))
            end
          | Start_clause _ | End_clause _ | Enter_clause _ | Exit_clause _ ->
            (*
              These clauses can be safely ignored because they never complete
              a lookup and so won't ever be the subject of a rewind.
            *)
            None
        ]
    in
    untargeted_dynamic_pops
  ;;

end;;

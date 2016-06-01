(* This module contains utilities for pretty-printing using the Formatter
   module. *)
open Batteries;;
open Format;;

type 'a pretty_printer = (formatter -> 'a -> unit);;

(** A function to pretty-print an enumeration of items.  This enumeration is
    boxed and the delimiter is interleaved between each item.  The arguments
    are:
    - The separator string.
    - The pretty-printing function for the items.
    - The formatter to use.
    - The item enumeration.
*)
val pp_concat_sep :
  string -> 'a pretty_printer -> formatter -> 'a Enum.t -> unit

(** A function to pretty-print an enumeration of items bracketed by specific
    start and stop symbols.  The arguments are:
    - The start symbol.
    - The end symbol.
    - The separator string.
    - The pretty-printing function for the items.
    - The formatter to use.
    - The item enumeration.
*)
val pp_concat_sep_delim :
  string -> string ->
  string -> 'a pretty_printer -> formatter -> 'a Enum.t -> unit

(** Pretty-prints a tuple.  The arguments are:
    - A pretty-printing function for the first element.
    - A pretty-printing function for the second element.
    - The formatter.
    - The tuple.
*)
val pp_tuple :
  'a pretty_printer -> 'b pretty_printer -> formatter -> 'a * 'b -> unit

(** Pretty-prints a triple.  The arguments are:
    - A pretty-printing function for the first element.
    - A pretty-printing function for the second element.
    - A pretty-printing function for the third element.
    - The formatter.
    - The triple.
*)
val pp_triple :
  'a pretty_printer -> 'b pretty_printer -> 'c pretty_printer -> formatter ->
  'a * 'b * 'c -> unit

(** Pretty-prints a quadruple.  The arguments are:
    - A pretty-printing function for the first element.
    - A pretty-printing function for the second element.
    - A pretty-printing function for the third element.
    - A pretty-printing function for the fourth element.
    - The formatter.
    - The quadruple.
*)
val pp_quadruple :
  'a pretty_printer -> 'b pretty_printer -> 'c pretty_printer ->
  'd pretty_printer -> formatter -> 'a * 'b * 'c * 'd -> unit

(** Pretty-prints a quintuple.  The arguments are:
    - A pretty-printing function for the first element.
    - A pretty-printing function for the second element.
    - A pretty-printing function for the third element.
    - A pretty-printing function for the fourth element.
    - The formatter.
    - The quintuple.
*)
val pp_quintuple :
  'a pretty_printer -> 'b pretty_printer -> 'c pretty_printer ->
  'd pretty_printer -> 'e pretty_printer -> formatter ->
  'a * 'b * 'c * 'd * 'e -> unit

(** Pretty-prints a list.  The arguments are:
    - The pretty-printing function for the list.
    - The formatter to use.
    - The list.
*)
val pp_list : 'a pretty_printer -> formatter -> 'a list -> unit

(** Given a pretty printer and an object, generates a string for them. *)
val pp_to_string : 'a pretty_printer -> 'a -> string

(** Suffixes a pretty printer with a fixed string. *)
val pp_suffix : 'a pretty_printer -> string -> 'a pretty_printer
(* File: csv.ml

   Copyright (C) 2005-2009

     Richard Jones
     email: rjones@redhat.com

     Christophe Troestler
     email: Christophe.Troestler@umh.ac.be
     WWW: http://math.umh.ac.be/an/software/

   This library is free software; you can redistribute it and/or modify
   it under the terms of the GNU General Public License version 2.1 or
   later as published by the Free Software Foundation, with the special
   exception on linking described in the file LICENSE.

   This library is distributed in the hope that it will be useful, but
   WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
   LICENSE for more details. *)

(* MOTIVATION.  There are already several solutions to parse CSV files
   in OCaml.  They did not suit my needs however because:

   - The files I need to deal with have a header which does not always
   reflect the data structure (say the first row are the names of
   neurones but there are two columns per name).  In other words I
   want to be able to deal with heterogeneous files.

   - I do not want to read the the whole file at once (I may but I
   just want to be able to choose).  Higher order functions like fold
   are fine provided the read stops at the line an exception is raised
   (so it can be reread again).

   - For similarly encoded line, being able to specify once a decoder
   and then use a type safe version would be nice.

   - Speed is not neglected (we would like to be able to parse a
   ~2.5Mb file under 0.1 sec on my machine (2GHz Core Duo)).

   We follow the CVS format documentation available at
   http://www.creativyst.com/Doc/Articles/CSV/CSV01.htm
*)

type t = string list list


class type in_obj_channel =
object
  method input : string -> int -> int -> int
  method close_in : unit -> unit
end

class type out_obj_channel =
object
  method output : string -> int -> int -> int
  method close_out : unit -> unit
end

(* Specialize [min] to integers for performance reasons (> 150% faster). *)
let min x y = if (x:int) <= y then x else y

(*
 * Input
 *)

exception Failure of int * int * string

let buffer_len = 0x1FFF

(* We buffer the input as this allows the be efficient while using
   very basic input channels.  The drawback is that if we want to use
   another tool, there will be data hold in the buffer.  That is why
   we allow to convert a CSV handle to an object sharing the same
   buffer.  Because if this, we actually decided to implement the CSV
   handle as an object that is coercible to a input-object.

   FIXME: This is not made for non-blocking channels.  Can we fix it? *)
type in_channel = {
  in_chan : in_obj_channel;
  in_buf : string;
  (* The data in the in_buf is at indexes i s.t. in0 <= i < in1.
     Invariant: 0 <= in0 ; in1 <= buffer_len in1 < 0 indicates a
     closed channel. *)
  mutable in0 : int;
  mutable in1 : int;
  mutable end_of_file : bool;
  (* If we encounter an End_of_file exception, we set this flag to
     avoid reading again because we do not know how the channel will
     react past an end of file.  That allows us to assume that
     reading past an end of file will keep raising End_of_file. *)
  current_field : Buffer.t; (* buffer reused to scan fields *)
  mutable record : string list; (* The current record *)
  mutable record_n : int; (* For error messages *)
  separator : char;
  excel_tricks : bool;
}

let of_in_obj ?(separator=',') ?(excel_tricks=false) in_chan = {
  in_chan = in_chan;
  in_buf = String.create buffer_len;
  in0 = 0;
  in1 = 0;
  end_of_file = false;
  current_field = Buffer.create 0xFF;
  record = [];
  record_n = 0;
  separator = separator;
  excel_tricks = excel_tricks;
}

let of_channel ?separator ? excel_tricks fh =
  of_in_obj ?separator ?excel_tricks
    (object
       val fh = fh
       method input s ofs len =
         try
           let r = Pervasives.input fh s ofs len in
           if r = 0 then raise End_of_file;
           r
         with Sys_blocked_io -> 0
       method close_in() = Pervasives.close_in fh
     end)


(* [fill_in_buf chan] refills in_buf if needed (when empty).  After
   this [in0 < in1] or [in0 = in1 = 0], the latter indicating that
   there is currently no bytes to read (for a non-blocking channel).

   @raise End_of_file if there are no more bytes to read. *)
let fill_in_buf ic =
  if ic.end_of_file then raise End_of_file;
  if ic.in0 >= ic.in1 then begin
    try
      ic.in0 <- 0;
      ic.in1 <- ic.in_chan#input ic.in_buf 0 buffer_len;
    with End_of_file ->
      ic.end_of_file <- true;
      raise End_of_file
  end


let close_in ic =
  if ic.in1 >= 0 then begin
    ic.in0 <- 0;
    ic.in1 <- -1;
    ic.in_chan#close_in(); (* may raise an exception *)
  end


let to_in_obj ic =
object
  val ic = ic

  method input buf ofs len =
    if ofs < 0 || len < 0 || ofs + len > String.length buf
    then invalid_arg "Csv.to_in_obj#input";
    if ic.in1 < 0 then raise(Sys_error "Bad file descriptor");
    fill_in_buf ic;
    let r = min len (ic.in1 - ic.in0) in
    String.blit ic.in_buf ic.in0 buf ofs r;
    ic.in0 <- ic.in0 + r;
    r

  method close_in() = close_in ic
end

(*
 * CSV input format parsing
 *)

let is_space c = c = ' ' || c = '\t' (* See documentation *)

(* Given a buffer, returns its content stripped of *final* whitespace. *)
let strip_contents buf =
  let n = ref(Buffer.length buf - 1) in
  while !n >= 0 && is_space(Buffer.nth buf !n) do decr n done;
  Buffer.sub buf 0 (!n + 1)

(* Return the substring after stripping its final space.  It is
   assumed the substring parameters are valid. *)
let strip_substring buf ofs len =
  let n = ref(ofs + len - 1) in
  while !n >= ofs && is_space(String.unsafe_get buf !n) do decr n done;
  String.sub buf ofs (!n - ofs + 1)


(* Skip the possible '\n' following a '\r'.  Reaching End_of_file is
   not considered an error -- just do nothing. *)
let skip_CR ic =
  try
    fill_in_buf ic;
    if String.unsafe_get ic.in_buf ic.in0 = '\n' then ic.in0 <- ic.in0 + 1
  with End_of_file -> ()


(* Unquoted field.  Read till a delimiter, a newline, or the
   end of the file.  Skip the next delimiter or newline.
   @return [true] if more fields follow, [false] if the record
   is complete. *)
let rec seek_unquoted_separator ic i =
  if i >= ic.in1 then (
    (* End not found, need to look at the next chunk *)
    Buffer.add_substring ic.current_field ic.in_buf ic.in0 (i - ic.in0);
    ic.in0 <- i;
    fill_in_buf ic; (* or raise End_of_file *)
    seek_unquoted_separator ic 0
  )
  else
    let c = String.unsafe_get ic.in_buf i in
    if c = ic.separator || c = '\n' || c = '\r' then (
      if Buffer.length ic.current_field = 0 then
        (* Avoid copying the string to the buffer if unnecessary *)
        ic.record <- strip_substring ic.in_buf ic.in0 (i - ic.in0) :: ic.record
      else (
        Buffer.add_substring ic.current_field ic.in_buf ic.in0 (i - ic.in0);
        ic.record <- strip_contents ic.current_field :: ic.record;
      );
      ic.in0 <- i + 1;
      if c = '\r' then (skip_CR ic; false) else (c = ic.separator)
    )
    else seek_unquoted_separator ic (i+1)

let add_unquoted_field ic =
  try seek_unquoted_separator ic ic.in0
  with End_of_file ->
    ic.record <- strip_contents ic.current_field :: ic.record;
    false

(* Quoted field.  Read till a closing quote, a newline, or the end
   of the file and decode the field.  Skip the next delimiter or
   newline.  @return [true] if more fields follow, [false] if the
   record is complete. *)
let rec seek_quoted_separator ic field_no =
  fill_in_buf ic; (* or raise End_of_file *)
  let c = String.unsafe_get ic.in_buf ic.in0 in
  ic.in0 <- ic.in0 + 1;
  if is_space c then seek_quoted_separator ic field_no (* skip space *)
  else if c = ic.separator || c = '\n' || c = '\r' then (
    ic.record <- Buffer.contents ic.current_field :: ic.record;
    if c = '\r' then (skip_CR ic; false) else (c = ic.separator)
  )
  else raise(Failure(ic.record_n, field_no,
                     "Non-space char after closing the quoted field"))

let rec examine ic field_no after_quote i =
  if i >= ic.in1 then (
    (* End of field not found, need to look at the next chunk *)
    Buffer.add_substring ic.current_field ic.in_buf ic.in0 (i - ic.in0);
    ic.in0 <- i;
    fill_in_buf ic; (* or raise End_of_file *)
    examine ic field_no after_quote 0
  )
  else
    let c = String.unsafe_get ic.in_buf i in
    if !after_quote then (
      if c = '\"' then (
        after_quote := false;
        (* [c] is kept so a quote will be included in the field *)
        examine ic field_no after_quote (i+1)
      )
      else if c = ic.separator || is_space c || c = '\n' || c = '\r' then (
        seek_quoted_separator ic field_no (* field already saved; in0=i;
                                         after_quote=true *)
      )
      else if ic.excel_tricks && c = '0' then (
        (* Supposedly, '"' '0' means ASCII NULL *)
        after_quote := false;
        Buffer.add_char ic.current_field '\000';
        ic.in0 <- i + 1; (* skip the '0' *)
        examine ic field_no after_quote (i+1)
      )
      else raise(Failure(ic.record_n, field_no, "Bad '\"' in quoted field"))
    )
    else if c = '\"' then (
      after_quote := true;
      (* Save the field so far, without the quote *)
      Buffer.add_substring ic.current_field ic.in_buf ic.in0 (i - ic.in0);
      ic.in0 <- i + 1; (* skip the quote *)
      examine ic field_no after_quote ic.in0
    )
    else examine ic field_no after_quote (i+1)

let add_quoted_field ic field_no =
  let after_quote = ref false in (* preserved through exn *)
  try examine ic field_no after_quote ic.in0
  with End_of_file ->
    (* Add the field even if not closed well *)
    ic.record <- Buffer.contents ic.current_field :: ic.record;
    if !after_quote then false
    else raise(Failure(ic.record_n, field_no,
                       "Quoted field closed by end of file"))


let skip_spaces ic =
  (* Skip spaces: after this [in0] is a non-space char. *)
  while ic.in0 < ic.in1 && is_space(String.unsafe_get ic.in_buf ic.in0) do
    ic.in0 <- ic.in0 + 1
  done;
  while ic.in0 >= ic.in1 do
    fill_in_buf ic;
    while ic.in0 < ic.in1 && is_space(String.unsafe_get ic.in_buf ic.in0) do
      ic.in0 <- ic.in0 + 1
    done;
  done

(* We suppose to be at the beginning of a field.  Add the next field
   to [record].  @return [true] if more fields follow, [false] if
   the record is complete.

   Return  Failure (if there is a format error), End_of_line
   (if the row is complete) or End_of_file (if there is not more
   data to read). *)
let add_next_field ic field_no =
  Buffer.clear ic.current_field;
  try
    skip_spaces ic;
    (* Now, in0 < in1 or raise End_of_file was raised *)
    let c = String.unsafe_get ic.in_buf ic.in0 in
    if c = '\"' then (
      ic.in0 <- ic.in0 + 1;
      add_quoted_field ic field_no
    )
    else if ic.excel_tricks && c = '=' then begin
      ic.in0 <- ic.in0 + 1; (* mark '=' as read *)
      try
        fill_in_buf ic;
        if String.unsafe_get ic.in_buf ic.in0 = '\"' then (
          (* Excel trick ="..." to prevent spaces around the field
             to be removed. *)
          ic.in0 <- ic.in0 + 1; (* skip '"' *)
          add_quoted_field ic field_no
        )
        else (
          Buffer.add_char ic.current_field '=';
          add_unquoted_field ic
        )
      with End_of_file ->
        ic.record <-  "=" :: ic.record;
        false
    end
    else add_unquoted_field ic
  with End_of_file ->
    (* If it is the first field, coming from [next()], the field is
       made of spaces.  If after the first, we are sure we read a
       delimiter before (but maybe the field is empty).  Thus add en
       empty field. *)
    ic.record <-  "" :: ic.record;
    false

let next ic =
  if ic.in1 < 0 then raise(Sys_error "Bad file descriptor");
  fill_in_buf ic; (* or End_of_file which means no more records *)
  ic.record <- [];
  ic.record_n <- ic.record_n + 1; (* the current line being read *)
  let more_fields = ref true
  and field_no = ref 0 in
  while !more_fields do
    more_fields := add_next_field ic !field_no;
    incr field_no;
  done;
  ic.record <- List.rev ic.record;
  ic.record


let current_record ic = ic.record


let fold_left f a0 ic =
  let a = ref a0 in
  try
    while true do
      a := f !a (next ic)
    done;
    assert false
  with End_of_file -> !a

let iter ~f ic =
  try  while true do f (next ic) done;
  with End_of_file -> ()

let input_all ic =
  List.rev(fold_left (fun l r -> r :: l) [] ic)

let fold_right f ic a0 =
  (* We to collect all records before applying [f] -- last row first. *)
  let lr = fold_left (fun l r -> r :: l) [] ic in
  List.fold_left (fun a r -> f r a) a0 lr


let load ?separator ?excel_tricks fname =
  let csv = of_channel ?separator ?excel_tricks (open_in fname) in
  let t = input_all csv in
  close_in csv;
  t


(*
 * Output
 *)

(* FIXME: Rework this part *)
type out_channel = {
  out_chan : out_obj_channel;
  out_separator : char;
  out_separator_string : string;
  out_excel_tricks : bool;
}

let to_out_obj ?(separator=',') ?(excel_tricks=false) out_chan = {
  out_chan = out_chan;
  out_separator = separator;
  out_separator_string = String.make 1 separator;
  out_excel_tricks = excel_tricks;
}

let to_channel ?separator ?excel_tricks fh =
  to_out_obj ?separator ?excel_tricks
    (object
       val fh = fh
       method output s ofs len = output fh s ofs len; len
       method close_out () = close_out fh
     end)

let rec really_output oc s ofs len =
  let w = oc.out_chan#output s ofs len in
  if w < len then really_output oc s (ofs+w) (len-w)

(* Determine whether the string s must be quoted and how many chars it
   must be extended to contain the escaped values.  Return -1 if there
   is no need to quote.  It is assumed that the string length [len]
   is > 0. *)
let must_quote separator excel_tricks s len =
  let quote = ref(is_space(String.unsafe_get s 0)
                  || is_space(String.unsafe_get s (len - 1))) in
  let n = ref 0 in
  for i = 0 to len - 1 do
    let c = String.unsafe_get s i in
    if c = separator || c = '\n' || c = '\r' then quote := true
    else if c = '"' || (excel_tricks && c = '\000') then (
      quote := true;
      incr n)
  done;
  if !quote then !n else -1

let need_excel_trick s len =
  let c = String.unsafe_get s 0 in
  is_space c || c = '0' || is_space(String.unsafe_get s (len - 1))

(* Do some work to avoid quoting a field unless it is absolutely
   required. *)
let write_escaped oc field =
  if String.length field > 0 then begin
    let len = String.length field in
    let use_excel_trick = oc.out_excel_tricks && need_excel_trick field len
    and n = must_quote oc.out_separator oc.out_excel_tricks field len in
    if n < 0 && not use_excel_trick then
      really_output oc field 0 len
    else (
      let field =
        if n = 0 then field
        else (* There are some quotes to escape *)
          let s = String.create (len + n) in
          let j = ref 0 in
          for i = 0 to len - 1 do
            let c = String.unsafe_get field i in
            if c = '"' then (
              String.unsafe_set s !j '"'; incr j;
              String.unsafe_set s !j '"'; incr j
            )
            else if oc.out_excel_tricks && c = '\000' then (
              String.unsafe_set s !j '"'; incr j;
              String.unsafe_set s !j '0'; incr j
            )
            else (String.unsafe_set s !j c; incr j)
          done;
          s
      in
      if use_excel_trick then really_output oc "=\"" 0 2
      else really_output oc "\"" 0 1;
      really_output oc field 0 (String.length field);
      really_output oc "\"" 0 1
    )
  end

let output_record oc = function
  | [] ->
      really_output oc "\n" 0 1
  | [f] ->
      write_escaped oc f;
      really_output oc "\n" 0 1
  | f :: tl ->
      write_escaped oc f;
      List.iter (fun f ->
                   really_output oc oc.out_separator_string 0 1;
                   write_escaped oc f;
                ) tl;
      really_output oc "\n" 0 1


let print ?separator ?excel_tricks t =
  let csv = to_channel ?separator ?excel_tricks stdout in
  List.iter (fun r -> output_record csv r) t
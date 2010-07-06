(* Ocsigen
 * http://www.ocsigen.org
 * Module server.ml
 * Copyright (C) 2010
 * Raphaël Proust
 * Laboratoire PPS - CNRS Université Paris Diderot
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, with linking exception;
 * either version 2.1 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 *)

(* Comet extension for Ocsigen server
 * ``Comet'' is a set of <strike>hacks</strike> techniques providing basic
 * server-to-client communication. Using HTTP, it is not possible for the server
 * to send a message to the client, it is only possible to answer a client's
 * request.
 *
 * This implementation is to evolve and will change a lot with HTML5's
 * WebSockets support.
 *)


(*** PREAMBLE ***)

(* Shortening names of modules *)
module OFrame  = Ocsigen_http_frame
module OStream = Ocsigen_stream
module OX      = Ocsigen_extensions
module OLib    = Ocsigen_lib
module OMsg    = Ocsigen_messages
module Pxml    = Simplexmlparser

(* infix monad binders *)
let ( >>= ) = Lwt.( >>= )
let ( >|= ) = Lwt.( >|= ) (* AKA map, AKA lift *)

(* small addition to the standard library *)
let map_rev_accu_split func lst accu1 accu2 =
  let rec aux accu1 accu2 = function
    | [] -> (accu1, accu2)
    | x :: xs -> match func x with
        | OLib.Left y -> aux (y :: accu1) accu2 xs
        | OLib.Right y -> aux accu1 (y :: accu2) xs
  in
    aux accu1 accu2 lst


(*** EXTENSION OPTIONS ***)


(* timeout for comet connections : if no value has been written in the ellapsed
 * time, connection will be closed. Should be equal to client timeout. *)
let timeout_ref = ref 20.
let get_timeout () = !timeout_ref

(* the size initialization for the channel hashtable *)
let tbl_initial_size = 16

let max_virtual_channels_ref = ref None
let get_max_virtual_channels () = !max_virtual_channels_ref

let rec parse_options = function
  | [] -> ()
  | ("max_virtual_channels", "") :: tl ->
        max_virtual_channels_ref := None ; parse_options tl
  | ("max_virtual_channels", s) :: tl ->
        max_virtual_channels_ref := Some (int_of_string s) ; parse_options tl
  | ("timeout", s) :: tl ->
        timeout_ref := float_of_string s ; parse_options tl
  | _ :: _ -> raise (OX.Error_in_config_file "Unexpected data in config file")

(*** CORE ***)

module Channels :
sig

  exception Too_many_virtual_channels
    (* raised when calling [create] while [max_virtual_channels] is [Some x] and
     * creating a new channel would make the virtual channel count greater than
     * [x]. *)

  type chan
    (* the type of channels :
     * channels can be written on or read from using the following functions
     *)
  type chan_id = string

  val create : (string * int option) React.E.t -> chan
    (* creating a fresh virtual channel, a client can request registraton to  *)

  val read : chan -> (string * int option) React.E.t
    (* [read ch] is an event with occurrences for each occurrence of the event
     * used to create the channel. *)

  val outcomes : chan -> (OStream.outcome * int) React.E.t
    (* The result of writes on the channel. [`Failure,s] on a failed [write s]
     * and [`Success,s] on a successful [write s].*)
  val send_outcome : chan -> (OStream.outcome * int) -> unit
    (* triggers the [outcomes] event associated to the channel. *)

  val listeners : chan -> int React.S.t
    (* The up-to-date count of registered clients *)
  val send_listeners : chan -> int -> unit
    (* [send_listeners c i] adds [i] to [listeners c]. [i] may be negative. *)

  val find_channel : chan_id -> chan
    (* may raise Not_found if the channel was collected or never created.
     * Basically ids are meant for clients to tell a server to start listening
     * to it. *)
  val get_id : chan -> chan_id
    (* [find_channel (get_id ch)] returns [ch] if the channel wasn't destroyed
     * that is. *)

end = struct

  exception Too_many_virtual_channels

  type chan_id = string
  type chan =
      {
        ch_id : chan_id ;
        ch_client_event   : (string * int option) React.E.t ;
        ch_tell_outcome   : (OStream.outcome * int) -> unit ;
        ch_outcomes       : (OStream.outcome * int) React.E.t ;
        ch_tell_listeners : int -> unit ;
        ch_listeners      : int React.S.t ;
      }

  let get_id ch = ch.ch_id

  (* In order to being able to retrieve channels by there IDs, let's have a map
   * *)
  module CTbl =
    Weak.Make
      (struct
         type t = chan
         let equal { ch_id = i } { ch_id = j } = i = j
         let hash { ch_id = c } = Hashtbl.hash c
       end)

  (* storage and ID manipulation *)
  let ctbl = CTbl.create tbl_initial_size

  let new_id = Ocsigen_lib.make_cryptographic_safe_string

  (* because Hashtables allow search for elements with a corresponding hash, we
   * have to create a dummy channel in order to retreive the original channel.
   * Is there a KISSer way to do that ? *)
  let (dummy1, _) = React.E.create ()
  let (dummy3, dummy2) = React.E.create ()
  let (dummy5, dummy4) = React.S.create 0
  let dummy_chan i =
    {
      ch_id = i ;
      ch_client_event = dummy1 ;
      ch_tell_outcome = dummy2 ;
      ch_outcomes     = dummy3 ;
      ch_tell_listeners = dummy4 ;
      ch_listeners      = dummy5 ;
    }

  (* May raise Not_found *)
  let find_channel i =
    CTbl.find ctbl (dummy_chan i)

  (* virtual channel count *)
  let (chan_count, incr_chan_count, decr_chan_count) =
    let cc = ref 0 in
    ((fun () -> !cc), (fun () -> incr cc), (fun _ -> decr cc))
  let maxed_out_virtual_channels () = match get_max_virtual_channels () with
    | None -> false
    | Some y -> chan_count () >= y


  (* creation : newly created channel is stored in the map as a side effect *)
  let create client_event =
    if maxed_out_virtual_channels ()
    then (OMsg.warning "Too many virtual channels, associated exception raised";
          raise Too_many_virtual_channels)
    else
      let (listeners_e, tell_listeners) = React.E.create () in
      let listeners = React.S.fold (+) 0 listeners_e in
      let (outcomes, tell_outcome) = React.E.create () in
      let ch =
        {
          ch_id = new_id () ;
          ch_client_event = client_event ;
          ch_outcomes     = outcomes     ;
          ch_tell_outcome = tell_outcome ;
          ch_tell_listeners = tell_listeners ;
          ch_listeners      = listeners ;
        }
      in
        incr_chan_count ();
        CTbl.add ctbl ch;
        Gc.finalise decr_chan_count ch;
        ch

  (* reading a channel : just getting a hang on the reader thread *)
  let read ch = ch.ch_client_event

  (* listeners *)
  let listeners ch = ch.ch_listeners
  let send_listeners ch x = ch.ch_tell_listeners x

  (* outcomes *)
  let outcomes ch = ch.ch_outcomes
  let send_outcome ch x = ch.ch_tell_outcome x

end


module Messages :
  (* All about messages from between clients and server *)
  (* 
   * The client sends a POST request with a "registration" parameter containing
   * a list of channel ids. Separator for the list are semi-colon : ';'.
   *
   * The server sends result to the client in the form of a list of :
   * channel_id ^ ":" ^ value ^ { ";" ^ channel_id ^ " " ^ value }*
   * where channel_id is the id of a channel that the client registered upon and
   * value is the string that was written upon the associated channel.
   * *)
sig

  val decode_upcomming :
    OX.request -> (Channels.chan list * Channels.chan_id list) Lwt.t
    (* decode incomming message : the result is the list of channels to listen
       to (on the left) or to signal non existence (on the right). *)

  val encode_downgoing :
       Channels.chan_id list
    -> (Channels.chan * string * int option) list option
    -> string OStream.t
    (* Encode outgoing messages : the first argument is the list of channels
     * that have already been collected.
     * The results is the stream to send to the client*)

  val encode_ended : Channels.chan_id list -> string

end = struct

  (* constants *)
  let channel_separator = "\n"
  let field_separator = ":"
  let ended_message = "ENDED_CHANNEL"
  let channel_separator_regexp = Netstring_pcre.regexp channel_separator
  let url_encode x = OLib.encode ~plus:false x

  let decode_string s accu1 accu2 =
    map_rev_accu_split
      (fun s ->
         try OLib.Left (Channels.find_channel s)
         with | Not_found -> OLib.Right s
      )
      (Netstring_pcre.split channel_separator_regexp s)
      accu1
      accu2

  let decode_param_list params =
    let rec aux ((tmp_reg, tmp_end) as tmp) = function
      | [] -> (tmp_reg, tmp_end)
      | ("registration", s) :: tl -> aux (decode_string s tmp_reg tmp_end) tl
      | _ :: tl -> aux tmp tl
    in
      aux ([], []) params

  let decode_upcomming r =
    (* RRR This next line makes it fail with Ocsigen_unsupported_media, hence
     * the http_frame low level version *)
    (* r.OX.request_info.OX.ri_post_params r.OX.request_config *)
    Lwt.catch
      (fun () ->
         match r.OX.request_info.OX.ri_http_frame.OFrame.frame_content with
           | None ->
               Lwt.return []
           | Some body ->
               Lwt.return (OStream.get body) >>=
               OStream.string_of_stream >|=
               Ocsigen_lib.fixup_url_string >|=
               Netencoding.Url.dest_url_encoded_parameters
      )
      (function
         | OStream.String_too_large -> Lwt.fail OLib.Input_is_too_large
         | e -> Lwt.fail e
      )
      >|= decode_param_list

  let encode_downgoing_non_opt l =
    String.concat
      channel_separator
      (List.map
         (fun (c, s, _) -> Channels.get_id c ^ field_separator ^ url_encode s)
         l)

  let encode_ended l =
    String.concat
      channel_separator
      (List.map (fun c -> c ^ field_separator ^ ended_message) l)

  let stream_result_notification l outcome =
    (*TODO: find a way to send outcomes simultaneously *)
    List.iter
      (function
         | (c, _, Some x) -> Channels.send_outcome c (outcome, x)
         | (_, _, None) -> ()
      ) l ;
    Lwt.return ()

  let encode_downgoing e = function
    | None -> OStream.of_string (encode_ended e)
    | Some l ->
        let stream =
          OStream.of_string
            (match e with
               | [] -> encode_downgoing_non_opt l
               | e ->   encode_ended e
                      ^ field_separator
                      ^ encode_downgoing_non_opt l)
        in
        OStream.add_finalizer stream (stream_result_notification l) ;
        stream

end

module Main :
  (* using React.merge, a client can wait for all the channels on which it
   * is registered and return with the first result. *)
sig

  val main : OX.request -> unit -> OFrame.result Lwt.t
  (* treat an incoming request from a client. The unit part is for partial
   * application in Ext_found parameter. *)

end = struct

  let react_timeout t v =
    let (e, s) = React.E.create () in
    let _ = Lwt_unix.sleep t >|= fun () -> s v in
    e

  (* Once channel list is obtain, use this function to return a thread that
   * terminates when one of the channel is written upon. *)
  let treat_decoded = function
    | [], [] -> (* error : empty request *)
        OMsg.debug (fun () -> "Incorrect or empty Comet request");
        Lwt.return
          { (OFrame.default_result ()) with
               OFrame.res_stream =
                 (OStream.of_string "Empty or incorrect registration", None) ;
               OFrame.res_code = 400 ;(* BAD REQUEST *)
               OFrame.res_content_type = Some "text/html" ;
          }

    | [], (_::_ as ended) ->
        let end_notice = Messages.encode_ended ended in
        OMsg.debug (fun () -> "Comet request served");
        Lwt.return
          { (OFrame.default_result ()) with
               OFrame.res_stream = (OStream.of_string end_notice, None) ;
               OFrame.res_content_length = None ;
               OFrame.res_content_type = Some "text/html" ;
          }

    | (_::_ as active), ended ->
        let merged =
          React.E.merge
            (fun acc v -> v :: acc)
            []
            (List.map
               (fun c -> React.E.map
                           (fun (v, x) -> (c, v, x))
                           (Channels.read c)
               )
               active
            )
        in
        List.iter (fun c -> Channels.send_listeners c 1) active ;
        Lwt.choose [ (Lwt_event.next merged >|= fun x -> Some x) ;
                     (Lwt_unix.sleep (get_timeout ()) >|= fun () -> None) ;
                   ] >|= fun x ->
        List.iter (fun c -> Channels.send_listeners c (-1)) active ;
        let s = Messages.encode_downgoing (Messages.encode_ended ended) x in
        { (OFrame.default_result ()) with
             OFrame.res_stream = (s, None) ;
             OFrame.res_content_length = None ;
             OFrame.res_content_type = Some "text/html" ;
        }


  (* This is just a mashup of the other functions in the module. *)
  let main r () = Messages.decode_upcomming r >>= treat_decoded

end

let rec has_comet_content_type = function
  | [] -> false
  | ("application", "x-ocsigen-comet") :: _ -> true
  | _ :: tl -> has_comet_content_type tl



(*** MAIN FUNCTION ***)

let main = function

  | OX.Req_found _ -> (* If recognized by some other extension... *)
      Lwt.return OX.Ext_do_nothing (* ...do nothing *)

  | OX.Req_not_found (_, rq) -> (* Else check for content type *)
      match rq.OX.request_info.OX.ri_content_type with
        | Some (hd,tl) ->
            if has_comet_content_type (hd :: tl)
            then Lwt.return (OX.Ext_found (Main.main rq))
            else Lwt.return OX.Ext_do_nothing
        | None -> Lwt.return OX.Ext_do_nothing





(*** EPILOGUE ***)

(* registering extension and the such *)
let parse_config _ _ _ = function
  | Pxml.Element ("comet", attrs, []) ->
      parse_options attrs ;
      main
  | Pxml.Element (t, _, _) -> raise (OX.Bad_config_tag_for_extension t)
  | _ -> raise (OX.Error_in_config_file "Unexpected data in config file")
let site_creator (_ : OX.virtual_hosts) = parse_config
let user_site_creator (_ : OX.userconf_info) = site_creator

(* registering extension *)
let () = OX.register_extension
  ~name:"comet"
  ~fun_site:site_creator
  ~user_fun_site:user_site_creator
  ()

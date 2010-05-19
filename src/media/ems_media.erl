%%% @author     Max Lapshin <max@maxidoors.ru> [http://erlyvideo.org]
%%% @copyright  2009 Max Lapshin
%%% @doc        Erlyvideo media
%%% @reference  See <a href="http://erlyvideo.org/" target="_top">http://erlyvideo.org/</a> for more information
%%% @end
%%%
%%%
%%% The MIT License
%%%
%%% Copyright (c) 2009 Max Lapshin
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in
%%% all copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%%% THE SOFTWARE.
%%%
%%%---------------------------------------------------------------------------------------
-module(ems_media).
-author('Max Lapshin <max@maxidoors.ru>').
-behaviour(gen_server).
-include_lib("erlmedia/include/video_frame.hrl").


%% External API
-export([start_link/2]).
-export([play/2, stop/1, resume/1, pause/1]).
-export([subscribe/2, unsubscribe/1, set_source/2, read_frame/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).



start_link(Module, Options) ->
  gen_server2:start_link(?MODULE, [Module, Options], []).


-record(ems_media, {
  module,
  state,
  type,
  options,
  video_config,
  audio_config,
  metadata,
  active = [],
  starting = [],
  passive = [],
  source,
  source_ref,
  storage,
  format
}).


%%--------------------------------------------------------------------
%% @spec (Channel::integer(), Message::text) -> {ok}
%%
%% @doc Call some function
%% @end
%%----------------------------------------------------------------------

play(Media, StreamId) ->
  {ok, Stream} = subscribe(Media, StreamId),
  gen_server:call(Stream, {start, self()}),
  {ok, Stream}.

stop(Media) ->
  unsubscribe(Media).

subscribe(Media, StreamId) ->
  gen_server:call(Media, {subscribe, self(), StreamId}).

unsubscribe(Media) ->
  gen_server:call(Media, {unsubscribe, self()}).
  
resume(Media) ->
  gen_server:call(Media, {resume, self()}).

pause(Media) ->
  gen_server:call(Media, {pause, self()}).

set_source(Media, Source) ->
  gen_server:call(Media, {set_source, Source}).
  
read_frame(Media, Key) ->
  gen_server2:call(Media, {read_frame, Key}).

seek(Media, BeforeAfter, DTS) ->
  gen_server2:call(Media, {seek, BeforeAfter, DTS}).
  

%%%------------------------------------------------------------------------
%%% Callback functions from gen_server
%%%------------------------------------------------------------------------

%%----------------------------------------------------------------------
%% @spec (Port::integer()) -> {ok, State}           |
%%                            {ok, State, Timeout}  |
%%                            ignore                |
%%                            {stop, Reason}
%%
%% @doc Called by gen_server framework at process startup.
%%      Create listening socket.
%% @end
%%----------------------------------------------------------------------


init([Module, Options]) ->
  case Module:init(Options) of
    {ok, State} ->
      {ok, #ems_media{options = Options, module = Module, state = State}};
    {ok, State, {Format, Storage}} ->
      {ok, #ems_media{options = Options, module = Module, state = State, format = Format, storage = Storage}};
    {stop, Reason} ->
      {stop, Reason}
  end.

%%-------------------------------------------------------------------------
%% @spec (Request, From, State) -> {reply, Reply, State}          |
%%                                 {reply, Reply, State, Timeout} |
%%                                 {noreply, State}               |
%%                                 {noreply, State, Timeout}      |
%%                                 {stop, Reason, Reply, State}   |
%%                                 {stop, Reason, State}
%% @doc Callback for synchronous server calls.  If `{stop, ...}' tuple
%%      is returned, the server is stopped and `terminate/2' is called.
%% @end
%% @private
%%-------------------------------------------------------------------------
handle_call({subscribe, Client, StreamId}, _From, #ems_media{module = M, state = S, passive = Subscribers} = Media) ->
  case M:handle_control({subscribe, Client, StreamId}, S) of
    {ok, Stream} ->
      Ref = erlang:monitor(process,Client),
      {reply, {ok, Stream}, Media#ems_media{passive = [{Client,StreamId,Ref}|Subscribers]}};
    {error, Reason} ->
      {reply, {error, Reason}, Media}
  end;
  
handle_call({unsubscribe,Client}, _From, #ems_media{passive = Passive, starting = Starting, active = Active} = Media) ->
  Passive1 = unsubscribe_client(Passive, Client),
  Active1 = unsubscribe_client(Active, Client),
  Starting1 = unsubscribe_client(Starting, Client),
  {reply, ok, Media#ems_media{passive = Passive1, starting = Starting1, active = Active1}};


handle_call({start, Client}, From, Media) ->
  handle_call({resume, Client}, From, Media);
  
handle_call({resume, Client}, _From, #ems_media{passive = Passive, starting = Starting} = Media) ->
  case lists:keytake(Client,1,Passive) of
    {value,Subscribe,Passive1} ->
      {reply, ok, Media#ems_media{passive = Passive1, starting = [Subscribe|Starting]}};
    false ->
      {reply, {error, no_client}, Media}
  end;      

handle_call({pause, Client}, _From, #ems_media{passive = Passive, active = Active} = Media) ->
  case lists:keytake(Client,1,Active) of
    {value,Subscribe,Active1} ->
      {reply, ok, Media#ems_media{passive = [Subscribe|Passive], active = Active1}};
    false ->
      {reply, {error, no_client}, Media}
  end;      

handle_call({set_source, Source}, _From, #ems_media{source_ref = OldRef} = Media) ->
  case OldRef of
    undefined -> ok;
    _ -> erlang:demonitor(OldRef, [flush])
  end,
  Ref = erlang:monitor(process,Source),
  {reply, ok, Media#ems_media{source = Source, source_ref = Ref}};

handle_call({read_frame, Key}, _From, #ems_media{format = Format, storage = Storage} = Media) ->
  {reply, Format:read_frame(Storage, Key), Media};

handle_call({seek, BeforeAfter, DTS}, _From, #ems_media{format = Format, storage = Storage} = Media) ->
  {reply, Format:seek(Storage, BeforeAfter, DTS), Media};

handle_call(Request, _From, State) ->
  {stop, {unknown_call, Request}, State}.


unsubscribe_client(Clients, Client) ->
  case lists:keytake(Client, 1, Clients) of
    {value, {Client, _, Ref}, NewClients} ->
      erlang:demonitor(Ref),
      NewClients;
    false ->
      Clients
  end.
  

%%-------------------------------------------------------------------------
%% @spec (Msg, State) ->{noreply, State}          |
%%                      {noreply, State, Timeout} |
%%                      {stop, Reason, State}
%% @doc Callback for asyncrous server calls.  If `{stop, ...}' tuple
%%      is returned, the server is stopped and `terminate/2' is called.
%% @end
%% @private
%%-------------------------------------------------------------------------
handle_cast(_Msg, State) ->
  {stop, {unknown_cast, _Msg}, State}.

%%-------------------------------------------------------------------------
%% @spec (Msg, State) ->{noreply, State}          |
%%                      {noreply, State, Timeout} |
%%                      {stop, Reason, State}
%% @doc Callback for messages sent directly to server's mailbox.
%%      If `{stop, ...}' tuple is returned, the server is stopped and
%%      `terminate/2' is called.
%% @end
%% @private
%%-------------------------------------------------------------------------

handle_info({'DOWN', _Ref, process, Source, _Reason}, #ems_media{source = Source} = Media) ->
  % FIXME: should wait for timeout
  {stop, normal, Media};
  
handle_info({'DOWN', _Ref, process, Client, _Reason}, #ems_media{active = Active, passive = Passive} = Media) ->
  Passive1 = unsubscribe_client(Passive, Client),
  Active1 = unsubscribe_client(Active, Client),
  {noreply, Media#ems_media{passive = Passive1, active = Active1}};

handle_info(#video_frame{type = Type} = Frame, #ems_media{module = M, state = S} = Media) ->
  Media1 = start_on_keyframe(Frame, Media),
  #ems_media{active = Active, starting = Starting} = Media1,
  case M:handle_frame(Frame, S) of
    {ok, F, S1} ->
      case Type of
        audio -> send_frame(F, Starting);
        _ -> ok
      end,
      send_frame(F, Active),
      {noreply, Media1#ems_media{state = S1}};
    {noreply, S1} ->
      {noreply, Media1#ems_media{state = S1}};
    {stop, Reason, S1} ->
      {stop, Reason, Media1#ems_media{state = S1}}
  end;    

handle_info(Info, State) ->
  {stop, {unhandled, Info, State}}.


start_on_keyframe(#video_frame{type = video, frame_type = keyframe}, #ems_media{starting = Starting, active = Active} = M) ->
  M#ems_media{starting = [], active = Active ++ Starting};

start_on_keyframe(_, Media) ->
  Media.

send_frame(Frame, List) ->
  [Pid ! Frame#video_frame{stream_id = StreamId} || {Pid,StreamId,_} <- List].

%%-------------------------------------------------------------------------
%% @spec (Reason, State) -> any
%% @doc  Callback executed on server shutdown. It is only invoked if
%%       `process_flag(trap_exit, true)' is set by the server process.
%%       The return value is ignored.
%% @end
%% @private
%%-------------------------------------------------------------------------
terminate(_Reason, _State) ->
  ok.

%%-------------------------------------------------------------------------
%% @spec (OldVsn, State, Extra) -> {ok, NewState}
%% @doc  Convert process state when code is changed.
%% @end
%% @private
%%-------------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.
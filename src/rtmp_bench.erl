-module(rtmp_bench).
-author('Max Lapshin <max@maxidoors.ru>').


-include("../include/rtmp.hrl").

-record(reader, {
  time_start,
  dts_start,
  last_dts,
  socket,
  delta = 0,
  path,
  count = 1
}).


-export([start_spawner/4]).

start_spawner(Server, Port, Path, Count) ->
  start_spawner(Server, Port, Path, Count, 0).

start_spawner(Server, Port, Path, Count, Number) when Number < Count ->
  io:format("Starting client ~p~n", [Number+1]),
  spawn_link(fun() -> init_rtmp_client(Server, Port, Path) end),
  receive
    {'EXIT', _Pid, _Reason} ->
      NewCount = flush_exits(Number),
      start_spawner(Server, Port, Path, Count, NewCount)
  after
    500 ->
      start_spawner(Server, Port, Path, Count, Number + 1)
  end;

start_spawner(Server, Port, Path, Count, Count) ->
  receive
    {'EXIT', _Pid, _Reason} ->
      io:format("Dead client ~p~n", [_Reason]),
      NewCount = flush_exits(Count - 1),
      start_spawner(Server, Port, Path, Count, NewCount);
    Else ->
      io:format("Spawner message: ~p~n", [Else]),
      start_spawner(Server, Port, Path, Count, Count)
  end.

flush_exits(Count) ->
  receive
    {'EXIT', _Pid, _Reason} -> flush_exits(Count - 1)
  after
    0 -> Count
  end.
  
init_rtmp_client(Server, Port, Path) ->
  {ok, Socket} = gen_tcp:connect(Server, Port, [binary, {active, false}, {packet, raw}]),
  % io:format("Socket opened to ~s~n", [Server]),
  {ok, RTMP} = rtmp_socket:connect(Socket),
  rtmp_socket:setopts(RTMP, [{debug,true}]),
  io:format("Connected to ~s~n", [Server]),
  rtmp_client(RTMP, Path).
  
rtmp_client(RTMP, Path) ->
  receive 
    {rtmp, RTMP, connected} ->
      rtmp_socket:setopts(RTMP, [{active, true}]),
      play(RTMP, Path);
    Else ->
      io:format("Client message: ~p (~p)~n", [Else, RTMP]),
      rtmp_client(RTMP, Path)
  after
    10000 ->
      io:format("Client timeout~n"),
      ok
  end.

play(RTMP, Path) ->
  rtmp_lib:connect(RTMP, [{app, <<"live">>}, {tcUrl, <<"rtmp://localhost/live/a">>}]),
  Stream = rtmp_lib:createStream(RTMP),
  rtmp_lib:play(RTMP, Stream, Path),
  io:format("Playing ~s~n", [Path]),
  read_frame(#reader{socket = RTMP, path = Path}).

% read_frame(#reader{count = Count, last_dts = DTS} = Reader) when is_number(DTS) andalso Count rem 10000 == 0->
%   io:format("time: ~p~n", [round(DTS/1000)]),
%   read_frame(Reader#reader{count = Count+1});
% 
read_frame(#reader{count = Count, delta = Delta, last_dts = DTS} = Reader) when Count rem 1000 == 0->
  % {Time, _} = erlang:statistics(wall_clock),
  % io:format("start: ~p/~p, current: ~p/~p, lag: ~p/~p = ~p~n", [Reader#reader.time_start, Reader#reader.dts_start, Time, DTS, 
  %   Time - Reader#reader.time_start, DTS - Reader#reader.dts_start, Delta]),
  case Delta of
    _ when Delta > 0 ->
      io:format("pid ~p, time = ~ps, lag = ~pms~n", [self(), round(DTS/1000), Delta]);
    _ ->
      io:format("pid ~p, time = ~ps~n", [self(), round(DTS/1000)])
  end,
  read_frame(Reader#reader{count = Count+1});
  
read_frame(#reader{socket = RTMP, count = Count} = Reader) ->
  receive
    {rtmp, RTMP, #rtmp_message{type = Type} = Message} when Type == audio orelse Type == video ->
      Reader1 = store_time(Reader, Message),
      warn_delta(Reader1),
      read_frame(Reader1#reader{count = Count+1});
    {rtmp, RTMP, #rtmp_message{} = _Message} ->
      read_frame(Reader#reader{count = Count+1});
    {rtmp, RTMP, disconnect} -> ok;
    Else -> 
      io:format("Unknown message ~p~n", [Else])
  after
    10000 -> io:format("Timeout in reading~n")
  end.
        
store_time(#reader{dts_start = undefined} = Reader, #rtmp_message{timestamp = DTS} = _Message) when DTS > 0 ->
  {Time, _} = erlang:statistics(wall_clock),
  Reader#reader{dts_start = DTS, last_dts = DTS, time_start = Time, delta = 0};
  
store_time(#reader{dts_start = StartDTS, time_start = TimeStart} = Reader, #rtmp_message{timestamp = DTS} = _Message) when DTS > 0 ->
  {Time, _} = erlang:statistics(wall_clock),
  Delta = (Time - TimeStart) - round(DTS - StartDTS),
  Reader#reader{last_dts = DTS, delta = Delta};
  
store_time(Reader, _Message) -> % We ignore decoder config
  Reader.
  
warn_delta(#reader{delta = Delta}) when is_number(Delta) andalso Delta > 1000 ->
  % io:format("Warning, delta: ~p~n", [Delta]),
  ok;
warn_delta(_) ->
  ok.

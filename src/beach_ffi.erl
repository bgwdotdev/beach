-module(beach_ffi).
-export([daemon/2, to_continue/1, to_handle_msg/1, ssh_connection_send/4, to_connection_info/1]).

daemon(Port, Opts) ->
  case ssh:daemon(Port, Opts) of
    {ok, Pid} -> {ok, Pid};
    {error, eaddrinuse} -> {error, address_in_use};
    {error, ssh_not_started} -> {error, ssh_application_not_started};
    {error, "No host key available"} -> {error, host_key_not_found};
    {error, Error} -> {error, {ssh_daemon_fault, unicode:characters_to_binary(Error)}}
  end.


%%
%% HEPLERS
%% 

to_continue(Result) ->
  case Result of
    {error, {stop_reason, Reason}} -> {stop, Reason};
    {error, {stop_state, T = {terminate_state, _, ChannelId, _, _, _}}} -> {stop, ChannelId, T};
    {ok, State} -> {ok, State}
  end.

% can't define 'EXIT' in gleam, need to type cast
to_handle_msg(Msg) ->
  case Msg of
    {'EXIT', Pid, Reason } -> {ssh_exit, Pid, Reason};
    Msg -> Msg
  end.

ssh_connection_send(Pid, Id, Data, Timeout) ->
  case ssh_connection:send(Pid, Id, 0, Data, Timeout) of
    ok -> {ok, nil};
    {error, closed} -> {error, channel_closed};
    {error, timeout} -> {error, send_timeout}
  end.


to_connection_info(ConnectionInfo) ->
  User = proplists:get_value(user, ConnectionInfo),
  {_, {Ip, Port}} = proplists:get_value(peer, ConnectionInfo),
  IpAddress = unicode:characters_to_binary(inet:ntoa(Ip)),
  {connection_info, unicode:characters_to_binary(User), IpAddress, Port}.

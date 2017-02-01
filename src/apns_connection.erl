%%% @doc This gen_server handles the APNs Connection.
%%%
%%% Copyright 2017 Erlang Solutions Ltd.
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%% @end
%%% @copyright Inaka <hello@inaka.net>
%%%
-module(apns_connection).
-author("Felipe Ripoll <felipe@inakanetworks.com>").

-behaviour(gen_server).

%% API
-export([ start_link/2
        , default_connection/1
        , name/1
        , host/1
        , port/1
        , certfile/1
        , keyfile/1
        , gun_connection/1
        , close_connection/1
        , push_notification/4
        , wait_apns_connection_up/1
        ]).

%% gen_server callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3
        ]).

-export_type([ name/0
             , host/0
             , port/0
             , path/0
             , connection/0
             , notification/0
             ]).

-type name()         :: atom().
-type host()         :: string() | inet:ip_address().
-type path()         :: string().
-type notification() :: binary().
-opaque connection() :: #{ name       := name()
                         , apple_host := host()
                         , apple_port := inet:port_number()
                         , certfile   => path()
                         , keyfile    => path()
                         }.

-type state()        :: #{ connection     := connection()
                         , gun_connection := pid()
                         , gun_monitor    := reference()
                         , client         := pid()
                         }.

%%%===================================================================
%%% API
%%%===================================================================

%% @doc starts the gen_server
-spec start_link(connection(), pid()) ->
  {ok, Pid :: pid()} | ignore | {error, Reason :: term()}.
start_link(Connection, Client) ->
  Name = name(Connection),
  gen_server:start_link({local, Name}, ?MODULE, {Connection, Client}, []).

%% @doc Builds a connection() map from the environment variables.
-spec default_connection(name()) -> connection().
default_connection(ConnectionName) ->
  {ok, Host} = application:get_env(apns, apple_host),
  {ok, Port} = application:get_env(apns, apple_port),
  {ok, Certfile} = application:get_env(apns, certfile),
  {ok, Keyfile} = application:get_env(apns, keyfile),

  #{ name       => ConnectionName
   , apple_host => Host
   , apple_port => Port
   , certfile   => Certfile
   , keyfile    => Keyfile
  }.

%% @doc Close the connection with APNs gracefully
-spec close_connection(name()) -> ok.
close_connection(ConnectionName) ->
  gen_server:cast(ConnectionName, stop).

%% @doc Returns the gun's connection PID. This function is only used in tests.
-spec gun_connection(name()) -> pid().
gun_connection(ConnectionName) ->
  gen_server:call(ConnectionName, gun_connection).

%% @doc Pushes notification to APNs connection.
-spec push_notification( name()
                       , apns:device_id()
                       , notification()
                       , apns:headers()) -> apns:response().
push_notification(ConnectionName, DeviceId, Notification, Headers) ->
  gen_server:call(ConnectionName, { push_notification
                                  , DeviceId
                                  , Notification
                                  , Headers
                                  }).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

-spec init({connection(), pid()}) -> {ok, State :: state(), timeout()}.
init({Connection, Client}) ->
  {GunMonitor, GunConnectionPid} = open_gun_connection(Connection),

  {ok, #{ connection     => Connection
        , gun_connection => GunConnectionPid
        , gun_monitor    => GunMonitor
        , client         => Client
        }, 0}.

-spec handle_call( Request :: term(), From :: {pid(), term()}, State) ->
  {reply, ok, State}.
handle_call(gun_connection, _From, #{gun_connection := GunConn} = State) ->
  {reply, GunConn, State};
handle_call( {push_notification, DeviceId, Notification, HeadersMap}
           , _From
           , State) ->
  #{gun_connection := GunConn} = State,
  {ok, Timeout} = application:get_env(apns, timeout),
  Headers = get_headers(HeadersMap),
  Path = get_device_path(DeviceId),
  StreamRef = gun:post(GunConn, Path, Headers, Notification),
  Response = case gun:await(GunConn, StreamRef, Timeout) of
    {response, fin, Status, ResponseHeaders} ->
      {Status, ResponseHeaders, no_body};
    {response, nofin, Status, ResponseHeaders} ->
      {ok, Body} = gun:await_body(GunConn, StreamRef, Timeout),
      DecodedBody = jsx:decode(Body),
      {Status, ResponseHeaders, DecodedBody};
    {error, timeout} -> timeout
  end,
  {reply, Response, State};
handle_call(_Request, _From, State) ->
  {reply, ok, State}.

-spec handle_cast(Request :: term(), State) ->
  {noreply, State}.
handle_cast(stop, State) ->
  {stop, normal, State};
handle_cast(_Request, State) ->
  {noreply, State}.

-spec handle_info(Info :: timeout() | term(), State) ->
  {noreply, State}.
handle_info( {'DOWN', GunMonitor, process, GunConnPid, _}
           , #{ gun_connection := GunConnPid
              , gun_monitor    := GunMonitor
              , connection     := Connection
              } = State) ->
  {GunMonitor2, GunConnPid2} = open_gun_connection(Connection),
  {noreply, State#{gun_connection => GunConnPid2, gun_monitor => GunMonitor2}};
handle_info(timeout, #{gun_connection := GunConn, client := Client} = State) ->
  {ok, Timeout} = application:get_env(apns, timeout),
  case gun:await_up(GunConn, Timeout) of
    {ok, http2} ->
      Client ! {connection_up, self()},
      {noreply, State};
    {error, timeout} ->
      Client ! {timeout, self()},
      {stop, timeout, State}
  end;
handle_info(_Info, State) ->
  {noreply, State}.

-spec terminate( Reason :: (normal | shutdown | {shutdown, term()} | term())
               , State  :: state()
               ) -> ok.
terminate(_Reason, _State) ->
  ok.

-spec code_change(OldVsn :: term() | {down, term()}
                 , State
                 , Extra :: term()
                 ) -> {ok, State}.
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Connection getters/setters Functions
%%%===================================================================

-spec name(connection()) -> name().
name(#{name := ConnectionName}) ->
  ConnectionName.

-spec host(connection()) -> host().
host(#{apple_host := Host}) ->
  Host.

-spec port(connection()) -> inet:port_number().
port(#{apple_port := Port}) ->
  Port.

-spec certfile(connection()) -> path().
certfile(#{certfile := Certfile}) ->
  Certfile.

-spec keyfile(connection()) -> path().
keyfile(#{keyfile := Keyfile}) ->
  Keyfile.

%%%===================================================================
%%% Internal Functions
%%%===================================================================

-spec open_gun_connection(connection()) -> { GunMonitor       :: reference()
                                           , GunConnectionPid :: pid()
                                           }.
open_gun_connection(Connection) ->
  Certfile = certfile(Connection),
  Keyfile = keyfile(Connection),
  Host = host(Connection),
  Port = port(Connection),
  TransportOpts = [{certfile, Certfile}, {keyfile, Keyfile}],
  {ok, GunConnectionPid} = gun:open( Host
                                   , Port
                                   , #{ protocols => [http2]
                                      , transport_opts => TransportOpts
                                      }),
  GunMonitor = monitor(process, GunConnectionPid),
  {GunMonitor, GunConnectionPid}.

-spec get_headers(apns:headers()) -> list().
get_headers(Headers) ->
  List = [ {<<"apns-id">>, apns_id}
         , {<<"apns-expiration">>, apns_expiration}
         , {<<"apns-priority">>, apns_priority}
         , {<<"apns-topic">>, apns_topic}
         , {<<"apns-collapse_id">>, apns_collapse_id}
         ],
  F = fun({ActualHeader, Key}) ->
    case (catch maps:get(Key, Headers)) of
      {'EXIT', {{badkey, Key}, _}} -> [];
      Value -> [{ActualHeader, Value}]
    end
  end,
  lists:flatmap(F, List).

-spec get_device_path(apns:device_id()) -> string().
get_device_path(DeviceId) ->
  "/3/device/" ++ DeviceId.

-spec wait_apns_connection_up(pid()) -> {ok, pid()} | {error, timeout}.
wait_apns_connection_up(Server) ->
  receive
    {connection_up, Server} -> {ok, Server};
    {timeout, Server}       -> {error, timeout}
  end.

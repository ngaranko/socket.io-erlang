-module(socketio_transport_htmlfile).
-include_lib("../include/socketio.hrl").
-behaviour(gen_server).

%% API
-export([start_link/4]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE). 

-record(state, {
          session_id,
          req,
          caller,
          server_module,
          connection_reference,
          heartbeats = 0,
          heartbeat_interval,
          close_timeout,
          event_manager,
          sup
         }).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Sup, SessionId, ServerModule, ConnectionReference) ->
    gen_server:start_link(?MODULE, [Sup, SessionId, ServerModule, ConnectionReference], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([Sup, SessionId, ServerModule, {'htmlfile', {Req, Caller}}]) ->
    apply(ServerModule, ensure_longpolling_request, [Req]),
    process_flag(trap_exit, true),
    HeartbeatInterval = 
    case application:get_env(heartbeat_interval) of
        {ok, Time} ->
            Time;
        _ ->
            infinity
    end,
    CloseTimeout = 
    case application:get_env(close_timeout) of
	{ok, Time0} ->
	    Time0;
	_ ->
	    8000
    end,
    {ok, EventMgr} = gen_event:start_link(),
    gen_server:cast(self(), {initialize, Req}),
    socketio_client:send(self(), #msg{ content = SessionId }),
    gen_server:cast(self(), heartbeat),
    {ok, #state{
       session_id = SessionId,
       server_module = ServerModule,
       connection_reference = {'htmlfile', none},
       req = Req,
       caller = Caller,
       close_timeout = CloseTimeout,
       heartbeat_interval = HeartbeatInterval,
       event_manager = EventMgr,
       sup = Sup
      }}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
%% Incoming data
handle_call({'htmlfile', data, Req}, _From, #state{ heartbeat_interval = Interval, 
                                                    server_module = ServerModule,
                                                    event_manager = EventManager } = State) ->
    Data = apply(ServerModule, parse_post, [Req]),
    Self = self(),
    lists:foreach(fun({"data", M}) ->
        spawn(fun () ->
            F = fun(#heartbeat{}) -> ignore;
                   (M0) -> gen_event:notify(EventManager, {message, Self,  M0})
            end,
            [F(Msg) || Msg <- socketio_data:decode(#msg{content=M})]
        end)
    end, Data),
    apply(ServerModule, respond, [Req, 200, [{"Content-Type","text/plain"}],"ok"]),
    {reply, ok, State, Interval};

%% Event management
handle_call(event_manager, _From, #state{ event_manager = EventMgr } = State) ->
    {reply, EventMgr, State};

%% Sessions
handle_call(session_id, _From, #state{ session_id = SessionId } = State) ->
    {reply, SessionId, State};

%% Initial request
handle_call(req, _From, #state{ req = Req} = State) ->
    {reply, Req, State};

%% Flow control
handle_call(stop, _From, State) ->
    {stop, shutdown, State}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast({initialize, Req}, #state{ heartbeat_interval = Interval, server_module = ServerModule } = State) ->
    apply(ServerModule, headers, [Req, [{"Content-Type", "text/html"},
                                        {"Connection", "Keep-Alive"},
                                        {"Transfer-Encoding", "chunked"}]]),
    H = "<html><body>" ++ lists:duplicate(254,$\s),
    link(apply(ServerModule, socket, [Req])),
    apply(ServerModule, chunk, [Req, H]),
    {noreply, State#state{ connection_reference = {'htmlfile', connected} }, Interval};

handle_cast(heartbeat, #state{ heartbeats = Beats,
                               heartbeat_interval = Interval } = State) ->
    Beats1 = Beats + 1,
    socketio_client:send(self(), #heartbeat{ index = Beats1 }),
    {noreply, State#state { heartbeats = Beats1 }, Interval};

%% Send
handle_cast({send, Message}, #state{ req = Req, 
                                     server_module = ServerModule,
                                     connection_reference = {'htmlfile', connected }, heartbeat_interval = Interval } = State) ->
    send_message(Message, ServerModule, Req),
    {noreply, State, Interval};

handle_cast(_, #state{} = State) ->
    {noreply, State}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({'EXIT',_Port,_Reason}, #state{ close_timeout = ServerTimeout} = State) when is_port(_Port) ->
    {noreply, State#state { connection_reference = {'htmlfile', none}}, ServerTimeout};

handle_info(timeout, #state{ server_module = ServerModule,
                             connection_reference = {'htmlfile', none}, caller = Caller, req = Req } = State) ->
    gen_server:reply(Caller, apply(ServerModule, respond, [Req, 200])),
    {stop, shutdown, State};

handle_info(timeout, State) ->
    gen_server:cast(self(), heartbeat),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
send_message(#msg{} = Message, ServerModule, Req) ->
    send_message(socketio_data:encode(Message), ServerModule,Req);

send_message(#heartbeat{} = Message, ServerModule, Req) ->
    send_message(socketio_data:encode(Message), ServerModule, Req);

send_message(Message, ServerModule, Req) ->
    Message0 =  binary_to_list(jsx:term_to_json(list_to_binary(Message), [{strict, false}])),
    M = "<script>parent.s._(" ++ Message0 ++ ", document);</script>",
    apply(ServerModule, chunk, [Req, M]).

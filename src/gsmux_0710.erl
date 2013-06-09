%%%-------------------------------------------------------------------
%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2013, Tony Rogvall
%%% @doc
%%%  GSM 07.10 multiplexing support
%%% @end
%%% Created : 21 May 2013 by Tony Rogvall <tony@rogvall.se>
%%%-------------------------------------------------------------------
-module(gsmux_0710).

-behaviour(gen_server).

%% API
-export([start_link/1, start/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).
-export([establish/2, release/2, send/2]).
-export([closedown/1, send_test/2]).

-define(SERVER, ?MODULE). 

-record(subscriber,
	{
	  channel = -1 :: integer(),  %% -1,1,2,3..
	  pid          :: pid(),
	  mon          :: reference()
	}).


-record(state, {
	  drv :: pid(),        %% uart driver pid
	  ref :: reference(),  %% uart subscription ref
	  sub = [] :: [#subscriber{}],
	  manuf,
	  model,
	  cmux_opts
	 }).

-include("gsmux_0710.hrl").

-define(is_chan(X), (X band (bnot 16#3f)) =:= 0).

%%%===================================================================
%%% API
%%%===================================================================

establish(Pid, I) ->
    gen_server:call(Pid, {establish,I,self()}).

release(Pid, I) ->
    gen_server:call(Pid, {release,I}).

closedown(Pid) ->
    L = make_length(0),
    send_chan(Pid, 0, <<(?TYPE_CLD + ?COMMAND), L/binary>>).

send_test(Pid, Data) ->
    Data1 = iolist_to_binary(Data),
    L = make_length(byte_size(Data1)),
    send(Pid, <<(?TYPE_TEST + ?COMMAND),L/binary, Data1/binary>>).

%% sender must be established!    
send(Pid,Data) ->
    gen_server:call(Pid, {send,self(),Data}).

send_chan(Pid,Chan,Data) ->
    gen_server:call(Pid, {send_chan,Chan,Data}).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Opts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [Opts], []).

start(Opts) ->
    gen_server:start({local, ?SERVER}, ?MODULE, [Opts], []).

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
init([Opts]) ->
    Device = proplists:get_value(device, Opts),
    Baud   = proplists:get_value(baud, Opts, 115200),
    Reopen = proplists:get_value(reopen_timeout,Opts,5000),
    {Manuf,Model} = proplists:get_value(modem, Opts, {undefined,undefined}),
    {ok,Pid} = gsms_uart:start_link([{device,Device},
				     {baud, Baud},
				     {reopen_timeout,Reopen}]),
    {ok,Ref} = gsms_uart:subscribe(Pid),  %% subscribe to all events
    {ok, #state{ drv = Pid, ref = Ref,
		 manuf = Manuf, model = Model }}.

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

handle_call({send,Pid,Data}, _From, State) -> 
    case lists:keyfind(Pid, #subscriber.pid, State#state.sub) of
	false ->
	    {reply, {error, einval}, State};
	#subscriber { channel = Chan } ->
	    Reply = send_packet(Chan, Data, State),
	    {reply, Reply, State}
    end;
handle_call({send_chan,Chan,Data}, _From, State) ->
    Reply = send_packet(Chan, Data, State),
    {reply, Reply, State};

handle_call({establish,I,Pid}, _From, State) ->
    case lists:keyfind(I, #subscriber.channel, State#state.sub) of
	false ->
	    Reply = send_establish(I, State),
	    Ref = erlang:monitor(process,Pid),
	    S = #subscriber { channel = I, pid = Pid, mon = Ref },
	    Sub = [S | State#state.sub],
	    %% wait for DM | UA
	    {reply, Reply, State#state { sub=Sub }};
	#subscriber{} ->
	    {reply, {error,ealready}, State }
    end;

handle_call({release,I,Pid}, _From, State) ->
    case lists:keytake(I, #subscriber.channel, State#state.sub) of
	false ->
	    {reply, {error, enoent}, State};
	{value,#subscriber { pid=Pid, mon=Ref },Sub} ->
	    erlang:demonitor(Ref, [flush]),
	    Reply = send_release(I, State),
	    {reply, Reply, State#state{sub=Sub}}
    end;

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

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
handle_cast(_Msg, State) ->
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
handle_info({gsms_event,_Ref,
	     {data,<<?BASIC,Address:8,Control:8,Len:7,1:1,
		     Data:Len/binary,FCS:8,?BASIC>>}}, State) ->
    Valid = if Control =:= ?CONTROL_UIH ->
		    gsmux_fcs:is_valid(<<Address,Control,Len:7,1:1>>,FCS);
	       Control =:= ?CONTROL_UI ->
		    gsmux_fcs:is_valid([<<Address,Control,Len:7,1:1>>,Data],FCS);
	       true ->
		    unchecked
	    end,
    State1 = handle_packet(Address,Control,Len,Data,FCS,Valid,State),
    {noreply, State1};
handle_info(_I={gsms_event,_Ref,
		{data,<<?BASIC,Address:8,Control:8,L0:7,0:1,L1:8,
			Rest/binary>>}},
	    State) ->
    Len = (L1 bsl 7) + L0,
    case Rest of
	<<Data:Len,FCS:8,?BASIC>> ->
	    Valid = if Control =:= ?CONTROL_UIH ->
			    gsmux_fcs:is_valid(<<Address,Control,L0:7,0:1,L1>>,
					      FCS);
		       Control =:= ?CONTROL_UI ->
			    gsmux_fcs:is_valid([<<Address,Control,L0:7,0:1,L1>>,
					       Data],FCS);
		       true ->
			    unchecked
		    end,
	    State1 = handle_packet(Address,Control,Len,Data,FCS,Valid,State),
	    {noreply, State1};
	_ ->
	    io:format("Got info: ~p\n", [_I]),
	    {noreply, State}
    end;
handle_info({gsms_uart,Pid,up}, State) ->
    io:format("gms_uart : up\n", []),
    timer:sleep(100),                  %% help?
    ok = gsms_uart:at(Pid,"E0"),       %% disable echo (again)
    timer:sleep(100),                  %% help?
    Manuf = case gsms_uart:at(Pid,"+CGMI") of
		{ok,Manuf0} -> Manuf0;
		_ -> ""
	    end,
    io:format("Manuf : ~s\n", [Manuf]),
    timer:sleep(100),                  %% help?
    Model = case gsms_uart:at(Pid,"+CGMM") of
		{ok,Model0} -> Model0;
		_ -> ""
	    end,
    io:format("Model : ~s\n", [Model]),
    CMuxOpts = gsms_uart:at(Pid,"+CMUX=?"),  %% query CMUX options
    io:format("CmuxOpts = ~p\n", [CMuxOpts]),

    %% FIXME: use Manuf/Model and match with priv/mux.cfg to find
    %% the command(s) to use to enable multiplexing

    case gsms_uart:at(Pid,"#SELINT=2") of
	ok ->
	    io:format("#SELINT=2 result =~p\n", [ok]),
	    ok = gsms_uart:at(Pid,"V1&K3&D2"),
	    ok = gsms_uart:at(Pid,"+IPR=115200"),
	    Cmux = gsms_uart:at(Pid,"+CMUX=?"),
	    io:format("Cmux = ~p\n", [Cmux]),
	    CmuxMode = gsms_uart:at(Pid,"#CMUXMODE=?"),
	    io:format("CmuxMode = ~p\n", [CmuxMode]),
	    gsms_uart:at(Pid,"#CMUXMODE=1");
	Sel ->
	    io:format("#SELINT=2 result =~p\n", [Sel]),
	    ok
    end,
    ok = gsms_uart:at(Pid,"+CMUX=0"),  %% enable CMUX basic mode
    ok = gsms_uart:setopts(Pid, [{packet,basic_0710},
				 {mode,binary},
				 {active,true}]),

    {noreply, State#state { manuf = Manuf,
			    model = Model,
			    cmux_opts = CMuxOpts }};

handle_info({'DOWN',Ref,process,_Pid,Reason}, State) ->
    case lists:keytake(Ref, #subscriber.mon, State#state.sub) of
	false ->
	    {noreply, State};
	{value,S,Sub} ->
	    io:format("channel ~w controller crashed: ~p\n", 
		      [S#subscriber.channel, Reason]),
	    send_release(S#subscriber.channel, State),
	    {noreply, State#state { sub = Sub}}
    end;

handle_info(_Info, State) ->
    io:format("Got info: ~p\n", [_Info]),
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

send_packet(Chan, Data, State) when is_integer(Chan) ->
    Control = (?CONTROL_UIH),
    Address = (Chan bsl 2) + ?COMMAND + ?NEXTENDED,
    try iolist_to_binary(Data) of
	Data1 ->
	    Len = make_length(byte_size(Data1)),
	    Hdr = <<Address,Control,Len/binary>>,
	    FCS   = gsms_fcs:crc(Hdr),
	    gsms_uart:send(State#state.drv, <<?BASIC,Hdr/binary,
					      Data1/binary,
					      FCS,
					      ?BASIC>>)
    catch
	error:_ -> %% crash client
	    {error,badarg}
    end.

send_establish(Chan, State) when ?is_chan(Chan) ->
    Control = (?CONTROL_SABM+?CONTROL_P),
    Address = (Chan bsl 2) + ?COMMAND + ?NEXTENDED,
    Length  = 0,
    Hdr     = <<Address,Control,Length:7,1:1>>,
    FCS     = gsmux_fcs:crc(Hdr),
    gsms_uart:send(State#state.drv, <<?BASIC,Hdr/binary,FCS,?BASIC>>).

send_release(Chan, State) when ?is_chan(Chan) ->
    Control = (?CONTROL_DISC+?CONTROL_P),
    Address = (Chan bsl 2) + ?COMMAND + ?NEXTENDED,
    Length  = 0,
    Hdr     = <<Address,Control,Length:7,1:1>>,
    FCS     = gsmux_fcs:crc(Hdr),
    gsms_uart:send(State#state.drv,<<?BASIC,Hdr/binary,FCS,?BASIC>>).


handle_packet(Address,Control,Len,Data,_FCS,Valid,State) ->
    P = (Control band ?CONTROL_P) =/= 0,
    Ctrl = case Control band (bnot ?CONTROL_P) of
	       ?CONTROL_SABM -> sabm;
	       ?CONTROL_UA -> ua;
	       ?CONTROL_DM -> dm;
	       ?CONTROL_DISC-> disc;
	       ?CONTROL_UIH -> uih;
	       ?CONTROL_UI -> ui;
	       C -> C
	   end,
    Chan = (Address bsr 2),
    io:format("Got basic packet:(~w) chan=~w, ctrl=~s,p=~w,len=~w,data=~p\n", 
	      [Valid,Chan,Ctrl,P,Len,Data]),
    if Ctrl =:= uih, P =:= false;
       Ctrl =:= ui,  P =:= false ->
	    case lists:keyfind(Chan, #subscriber.channel, State#state.sub) of
		false ->
		    State;
		#subscriber { pid=Pid } ->
		    Pid ! {gsm_0710,Chan,Data},
		    State
	    end;
       true ->
	    State
    end.

make_length(N) when N =< 16#7f ->
    <<((N bsl 1) + 1)>>;
make_length(N) when N =< 16#7fff ->
    L0 = N band 16#7f,
    L1 = N bsr 7,
    <<L0:7,1:0,L1>>.

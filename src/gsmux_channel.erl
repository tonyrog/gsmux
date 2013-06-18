%%%-------------------------------------------------------------------
%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2013, Tony Rogvall
%%% @doc
%%%    GSM mux channel process
%%% @end
%%% Created :  7 Jun 2013 by Tony Rogvall <tony@rogvall.se>
%%%-------------------------------------------------------------------
-module(gsmux_channel).

-behaviour(gen_server).

%% API
-export([start/3, start_link/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include_lib("kernel/include/file.hrl").

-record(state, 
	{
	  mux,           %% multiplexor (parent)
	  chan,          %% channel number
	  pty,           %% master side of pty
	  ptypkt=false,  %% pty packet mode enabled ?
	  symlink,       %% symlink name
	  ptyname        %% the (pty slave) device used
	 }).

-define(TIOCPKT_DATA,		16#00).	%% data packet
-define(TIOCPKT_FLUSHREAD,	16#01).	%% flush packet
-define(TIOCPKT_FLUSHWRITE,	16#02).	%% flush packet
-define(TIOCPKT_STOP,		16#04).	%% stop output
-define(TIOCPKT_START,		16#08).	%% start output
-define(TIOCPKT_NOSTOP,		16#10).	%% no more ^S, ^Q
-define(TIOCPKT_DOSTOP,		16#20).	%% now do ^S ^Q
-define(TIOCPKT_IOCTL,		16#40).	%% state change of pty driver
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
start(Mux, SymLink, Chan) ->
    gen_server:start(?MODULE, [Mux,SymLink,Chan], []).

start_link(Mux, SymLink, Chan) ->
    gen_server:start_link(?MODULE, [Mux,SymLink,Chan], []).

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
init([Mux,SymLink,Chan]) ->
    link(Mux),
    R1 = gsmux_0710:establish(Mux, Chan),  %% establish multiplexer channel
    io:format("Establish: ~w = ~p\n", [Chan, R1]),
    %% enable the channel set FC=0!!!
    R2 = gsmux_0710:send_line_status(Mux,Chan,1,1,0),
    io:format("Line status: ~w = ~p\n", [Chan, R2]),
    State0 = #state{ mux = Mux, 
		     chan = Chan,
		     pty = undefined,
		     symlink = SymLink,
		     ptyname = undefined },
    State1 = do_open(State0),
    {ok, State1}.

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
handle_call(stop, _From, State) ->
    {stop, normal, ok, State};

handle_call(_Req, _From, State) ->
    {reply, {error,bad_call}, State}.

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

handle_info({uart,Pty,Data}, State) when Pty =:= State#state.pty ->
    {Cmd,Data1} = decode_pty_data(Data, State),
    uart:setopts(Pty, [{active,once}]),
    io:format("~w:~s: uart data: ~p ~p\n", 
	      [State#state.chan,State#state.ptyname,Cmd,Data1]),
    gsmux_0710:send(State#state.mux, Data),
    {noreply, State};
handle_info({gsm_0710,Chan,Data}, State) when Chan =:= State#state.chan ->
    io:format("~w:~s: mux data: ~p\n", 
	      [State#state.chan,State#state.ptyname,Data]),
    uart:send(State#state.pty,Data),
    {noreply, State};
handle_info({uart_closed,Pty}, State) when Pty =:= State#state.pty ->
    io:format("uart_closed: re-create and link\n", []),
    %% slave disconnected / recreate the connection
    State1 = do_close(State),
    State2 = do_open(State1),
    {noreply, State2};

handle_info(_Info, State) ->
    io:format("handle_info: ~p\n", [_Info]),
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
terminate(_Reason, State) ->
    gsmux_0710:release(State#state.mux, State#state.chan),
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

-define(PKTSTAT(M,F,A),
	if (F) band (M) =/= 0 -> [F]; true -> [] end).

decode_pty_data(<<Mode,Data/binary>>, State) when State#state.ptypkt ->
    M = ?PKTSTAT(Mode,?TIOCPKT_FLUSHREAD,flushread) ++
	?PKTSTAT(Mode,?TIOCPKT_FLUSHWRITE,flushwrite) ++
	?PKTSTAT(Mode,?TIOCPKT_STOP,stop) ++
	?PKTSTAT(Mode,?TIOCPKT_START,start) ++
	?PKTSTAT(Mode,?TIOCPKT_NOSTOP,nostop) ++
	?PKTSTAT(Mode,?TIOCPKT_DOSTOP,dostop) ++
	?PKTSTAT(Mode,?TIOCPKT_IOCTL,ioctl),
    {M, Data};
decode_pty_data(Data, _State) ->
    {[], Data}.

do_open(State) ->
    State1 = do_close(State),  %% close the old master
    {ok,Pty} = uart:open("//pty", [{baud,115200},
				   {ptypkt,true}
				   %% {debug,debug}]),
				   ]),
    {ok,Ptyname} = uart:getopt(Pty, device),
    Status = make_symlink(Ptyname, State1#state.symlink),
    io:format("~s -> ~s status = ~p\n", 
	      [Ptyname, State1#state.symlink,Status]),
    uart:setopts(Pty, [{active,once}]),
    State1#state { pty = Pty, ptyname = Ptyname, ptypkt = true }.

do_close(State) when State#state.ptyname =/= undefined ->
    uart:close(State#state.pty),
    State#state { pty = undefined, ptyname=undefined };
do_close(State) ->
    State.

make_symlink(_Ptyname, undefined) -> ok;
make_symlink(_Ptyname, "") -> ok;
make_symlink(Ptyname, SymLink) ->
    case file:read_link(SymLink) of
	{error,enoent} ->
	    make_link_perm(Ptyname, SymLink);
	{ok,Ptyname} ->
	    set_perm(Ptyname, SymLink);
	{ok,_} ->
	    file:delete(SymLink),
	    make_link_perm(Ptyname, SymLink)
    end.

make_link_perm(Ptyname, SymLink) ->
    case file:make_symlink(Ptyname, SymLink) of
	ok ->
	    set_perm(Ptyname, SymLink);
	Error ->
	    Error
    end.

set_perm(Ptyname, SymLink) ->
    case file:read_file_info(Ptyname) of
	{ok,Info} ->
	    %% does not work
	    %%file:raw_write_file_info(SymLink, Info);
	    Gid  = Info#file_info.gid,
	    Mode = Info#file_info.mode band 8#777,
	    io:format("Set grp to ~w and mode 0~.8B on symlink ~s\n",
		      [Gid, Mode, SymLink]),
	    os:cmd("chgrp -h " ++ integer_to_list(Gid) ++ " " ++ SymLink),
	    os:cmd("chmod -h " ++ "0"++tl(integer_to_list(8#1000+Mode,8))++
		       SymLink),
	    ok;
	Error ->
	    Error
    end.


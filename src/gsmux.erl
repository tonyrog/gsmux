%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2013, Tony Rogvall
%%% @doc
%%%    Start gsmux
%%% @end
%%% Created :  9 Jun 2013 by Tony Rogvall <tony@rogvall.se>

-module(gsmux).

-export([start/0]).
-export([start_link/1]).

start() ->
    application:start(uart),
    application:start(gsmux).

start_link(Opts) ->
    case gsmux_0710:start_link(Opts) of
	{ok,Pid} ->
	    timer:sleep(3000),   %% up ? mux? fixme
	    %% FIXME: pickup number of channels from command!
	    %% add each channel to supervisor!
	    {ok,_Chan1} = gsmux_channel:start(Pid, "/dev/ttyGSM1", 1), 
	    {ok,_Chan2} = gsmux_channel:start(Pid, "/dev/ttyGSM2", 2), 
	    {ok,_Chan3} = gsmux_channel:start(Pid, "/dev/ttyGSM3", 3),
	    {ok,Pid};
	Res ->
	    Res
    end.
	    
	    

% The game master sits in a loop spawning game processes when requested
-module(c4_game_master).
-export([start/2,start_loop/1]).

% Spawns and registers game master process
start(Nr, Nc) ->
	ParentPid = self(),
	register(?MODULE, spawn_link(c4_game_master, start_loop, [{ParentPid, Nr, Nc, none}])).
	
% @doc Initial process setup and into main loop.
start_loop({ParentPid, Nr, Nc, P1}) ->
	process_flag(trap_exit, true),
	loop({ParentPid, Nr, Nc, P1}).

% @doc Game master loop. Receives request from player processes to join
% a game or forget about joining a game.
loop({ParentPid, Nr, Nc, P1}) ->
	receive
		{'EXIT', ParentPid, Reason} ->
			exit(Reason);
		{'EXIT', _Pid, _Reason} ->
			loop({ParentPid, Nr, Nc, P1});
		{join, P2} -> 
			NewP = 
				case P1 of 
					none -> P2;
					_ ->
						c4_game:start(P1, P2, P1, Nr, Nc),
						none
				end,
			loop({ParentPid, Nr, Nc, NewP});
		% Current player wants to forget about joining
		{forget_game, P1} -> 
			P1 ! {game_forgotten, P1},
			loop({ParentPid, Nr, Nc, none});
		% Player already in a game sent request to forget about it.
		{forget_game, OldP} ->
			OldP ! {game_started, OldP},
			loop({ParentPid, Nr, Nc, P1})
	end.

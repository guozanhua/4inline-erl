% Description: process that receives messages from game client.
-module(c4_player).
-export([start/1]).

-define(INIT_TIMEOUT, 5000).
% @doc Timeout for other server processes.
-define(INTERNAL_TIMEOUT, 10000).
-define(MSG_END, ";").
-define(MSG_INIT, "CONNECT4").
-define(MSG_BAD_CMD, "INVALID_COMMAND").
-define(MSG_TIMEOUT, "TIMEOUT").
-define(MSG_JOIN, "JOIN").
-define(MSG_BUSY, "SERVER_BUSY").
-define(MSG_QUIT, "QUIT").
-define(ends_with(Bin, Str), Str == binary_part(Bin, {byte_size(Bin), -byte_size(Str)})).

% @doc Initial handshake with client, then go to Idle state if successful.
start(S) ->
	receive
		{tcp, S, <<?MSG_INIT ?MSG_END>>} ->
			send(S, ?MSG_INIT),
			idle(S);
		{tcp, S, _} -> 
			% Just abort on any other message for our protection
			exit_msg(S, ?MSG_BAD_CMD)
	after ?INIT_TIMEOUT ->
		exit_msg(S, ?MSG_TIMEOUT)
	end.

% @doc Sends one last message and closes the socket.
exit_msg(S, Msg) ->
	send(S, Msg),
	gen_tcp:close(S).

% @doc Sends a message after adding the standard message terminator.
send(S, Msg) ->
	ok = gen_tcp:send(S, [Msg | $;]).
	
% @doc Limbo state when no game is going on and user has not requested to join a game
idle(S)  ->
	receive
		{tcp, S, <<?MSG_JOIN ?MSG_END>>} -> waiting_for_game({S, nogame});
		{tcp, S, _} -> exit_msg(S, ?MSG_BAD_CMD);
		{tcp_closed, S} -> ok;
		{tcp_error, S, Reason} -> io:format("Socket error ~w ~n", [Reason])
	end.

% @doc contacts game coordinator to request joining a game.
% @todo handle long delay with user requesting quit game?
waiting_for_game(S) ->
	Pid = self(),
	c4_game_master ! { join_game, Pid },
	receive
		{new_game, play, GamePid} -> 
			my_turn(S, GamePid);
		{new_game, wait, GamePid} -> 
			other_turn(S, GamePid);
		{tcp, S, <<?MSG_QUIT ?MSG_END>>} -> 
			ok = cancel_join(S), 
			idle(S);
		{tcp_closed, S} -> 
			ok = cancel_join(S)
	after ?INTERNAL_TIMEOUT ->
		exit_msg(S, ?MSG_BUSY)
	end.

% Message game master to forget our request to join a game, wait for response.
cancel_join(S) ->
	Pid = self(),
	c4_game_master ! { forget_game, Pid},
	receive
		{game_forgotten, Pid} -> ok;
		{game_started, Pid} ->
			receive
				{new_game, _, GamePid} -> 
					abandon_game(S, GamePid),
					ok
			end
	end.

my_turn(S, GamePid) ->
	receive
		{tcp, S, Bin} 
		when ?ends_with(Bin, <<?MSG_QUIT ?MSG_END>>) ->
			abandon_game(S, GamePid),
			idle(S);
		% @todo needs change to support more than 9 columns.
		{tcp, S, <<"DROP ", Col:8/integer, ";">>} ->
			GamePid ! {self(), drop, list_to_integer([Col])},
			other_turn;
		{tcp_closed, S} ->
			io:format("Connection closed ~n", []);
		{tcp_error, S, Reason} ->
			io:format("Socket error ~w ~n", [Reason]);
		{GamePid, player_left} ->
			send(S, "EXITED"),
			idle(S);
		_ -> 
			goodbye(S)
%   - Disconnect -> AbortGame, Abort
%   - Connection error -> AbortGame, Abort
%   - Game error, dies -> GameError, Idle
%   - Game, bad move -> AbortGame, Abort
%
%  When a game crashes or exits, player processes get notified
	end.

other_turn(S, GamePid) ->
	receive
		{GamePid, dropped, Col} ->
			send(S, ["DROPPED ", erlang:integer_to_list(Col), ?MSG_END]),
			my_turn(S, GamePid);
		{GamePid, dropped_won, Col} ->
			send(S, ["DROPPED ", erlang:integer_to_list(Col), "  WON" ?MSG_END]),
			idle(S);
		{GamePid, player_left} ->
			send(S, "EXITED"),
			idle(S);
		{tcp, S, "QUIT" ?MSG_END} ->
			abandon_game(S,GamePid),
			idle(S)
%   - Game error, dies -> GameError, Idle
	end.

abandon_game(S, GamePid) ->
% Send Abandon msg to game process, wait for confirmation.
%   - Game Exit:  -> Idle
	GamePid ! {self(), quit},
	receive
		{GamePid, game_abandoned} -> ok
	after ?INTERNAL_TIMEOUT ->
		send(S, ?MSG_BUSY),
		exit(internal_timeout)
	end.

goodbye(S) ->
	gen_tcp:close(S).
	
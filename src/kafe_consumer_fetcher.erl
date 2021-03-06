% @hidden
-module(kafe_consumer_fetcher).
-compile([{parse_transform, lager_transform}]).
-behaviour(gen_server).

-include("../include/kafe.hrl").

%% API.
-export([start_link/14]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-record(state, {
          topic = undefined,
          partition = undefined,
          server = undefined,
          fetch_interval = undefined,
          timer = undefined,
          offset = -1,
          group_id = undefined,
          generation_id = undefined,
          member_id = undefined,
          fetch_size = ?DEFAULT_CONSUMER_FETCH_SIZE,
          autocommit = ?DEFAULT_CONSUMER_AUTOCOMMIT,
          min_bytes = ?DEFAULT_FETCH_MIN_BYTES,
          max_bytes = ?DEFAULT_FETCH_MAX_BYTES,
          max_wait_time = ?DEFAULT_FETCH_MAX_WAIT_TIME,
          callback = undefined,
          processing = ?DEFAULT_CONSUMER_PROCESSING
         }).

start_link(Topic, Partition, Srv, FetchInterval,
           GroupID, GenerationID, MemberID,
           FetchSize, Autocommit,
           MinBytes, MaxBytes, MaxWaitTime,
           Callback, Processing) ->
  gen_server:start_link(?MODULE, [
                                  Topic
                                  , Partition
                                  , Srv
                                  , FetchInterval
                                  , GroupID
                                  , GenerationID
                                  , MemberID
                                  , FetchSize
                                  , Autocommit
                                  , MinBytes
                                  , MaxBytes
                                  , MaxWaitTime
                                  , Callback
                                  , Processing
                                 ], []).

%% gen_server.

init([Topic, Partition, Srv, FetchInterval,
      GroupID, GenerationID, MemberID,
      FetchSize, Autocommit,
      MinBytes, MaxBytes, MaxWaitTime, Callback,
      Processing]) ->
  NoError = kafe_error:code(0),
  case kafe:offset_fetch(GroupID, [{Topic, [Partition]}]) of
    {ok, [#{name := Topic,
            partitions_offset := [#{error_code := NoError,
                                    offset := Offset,
                                    partition := Partition}]}]} ->
      lager:info("Start fetcher for ~p#~p with offset ~p", [Topic, Partition, Offset]),
      {ok, #state{
              topic = Topic,
              partition = Partition,
              server = Srv,
              fetch_interval = FetchInterval,
              timer = erlang:send_after(FetchInterval, self(), fetch),
              offset = Offset,
              group_id = GroupID,
              generation_id = GenerationID,
              member_id = MemberID,
              fetch_size = FetchSize,
              autocommit = Autocommit,
              min_bytes = MinBytes,
              max_bytes = MaxBytes,
              max_wait_time = MaxWaitTime,
              callback = Callback,
              processing = Processing
             }};
    _ ->
      lager:debug("Failed to fetch offset for ~p:~p in group ~p", [Topic, Partition, GroupID]),
      {stop, fetch_offset_faild}
  end.

handle_call(_Request, _From, State) ->
  {reply, ignored, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(fetch, State) ->
  {noreply, fetch(State)};
handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  lager:debug("Stop fetcher ~p", [_State]),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

fetch(#state{fetch_interval = FetchInterval,
             topic = Topic,
             partition = Partition,
             server = Srv,
             offset = OffsetFetch,
             fetch_size = FetchSize,
             autocommit = Autocommit,
             processing = Processing,
             min_bytes = MinBytes,
             max_bytes = MaxBytes,
             max_wait_time = MaxWaitTime,
             callback = Callback} = State) ->
  OffsetFetch1 = case kafe:offset([{Topic, [{Partition, -1, 1}]}]) of
                   {ok, [#{name := Topic,
                           partitions := [#{error_code := none,
                                            id := Partition,
                                            offsets := [Offset]}]}]} ->
                     if
                       OffsetFetch + 1 =< Offset - 1 ->
                         Offsets = lists:sublist(lists:seq(OffsetFetch + 1, Offset - 1), FetchSize),
                         lager:debug("~p#~p Fetch ~p", [Topic, Partition, Offsets]),
                         case perform_fetch(Offsets, [], Topic, Partition,
                                            Autocommit, Processing, Srv, Callback,
                                            MinBytes, MaxBytes, MaxWaitTime) of
                           [] ->
                             lists:max(Offsets);
                           Fetched ->
                             lists:max(Fetched)
                         end;
                       true ->
                         OffsetFetch
                     end;
                   {ok, [#{name := Topic,
                           partitions := [#{error_code := Error}]}]} ->
                     lager:error("Get offset for ~p#~p error : ~p", [Topic, Partition, Error]),
                     OffsetFetch;
                   {error, Error} ->
                     lager:error("Get offset for ~p#~p error : ~p", [Topic, Partition, Error]),
                     OffsetFetch
                 end,
  State#state{timer = erlang:send_after(FetchInterval, self(), fetch),
              offset = OffsetFetch1}.

perform_fetch([], Acc, _, _, _, _, _, _, _, _, _) ->
  Acc;
perform_fetch([Offset|Offsets], Acc,
              Topic, Partition, Autocommit, Processing, Srv, Callback,
              MinBytes, MaxBytes, MaxWaitTime) ->
  case gen_server:call(Srv, can_fetch) of
    true ->
      NoError = kafe_error:code(0),
      OffsetOutOfRange = kafe_error:code(1),
      case kafe:fetch(-1, Topic, #{partition => Partition,
                                   offset => Offset,
                                   max_bytes => MaxBytes,
                                   min_bytes => MinBytes,
                                   max_wait_time => MaxWaitTime}) of
        {ok, #{topics :=
               [#{name := Topic,
                  partitions :=
                  [#{error_code := NoError,
                     message := #{key := Key,
                                  offset := Offset,
                                  value := Value},
                     partition := Partition}]}]}} ->
          CommitRef = gen_server:call(Srv, {store_for_commit, Topic, Partition, Offset}, infinity),
          case commit(CommitRef, Autocommit, Processing, at_most_once) of
            {error, Reason} ->
              lager:error("[~p] Commit error for offset ~p of ~p#~p : ~p", [Processing, Offset, Topic, Partition, Reason]),
              Acc;
            _ ->
              lager:debug("Fetch offset ~p for ~p#~p with commit ref ~p", [Offset, Topic, Partition, CommitRef]),
              case try
                     erlang:apply(Callback, [CommitRef, Topic, Partition, Offset, Key, Value])
                   catch
                     Class:Reason0 ->
                       lager:error(
                         "Callback for message #~p of ~p#~p crash:~s",
                         [Offset, Topic, Partition, lager:pr_stacktrace(erlang:get_stacktrace(), {Class, Reason0})]),
                       callback_exception
                   end of
                ok ->
                  case commit(CommitRef, Autocommit, Processing, at_least_once) of
                    {error, Reason} ->
                      lager:error("[~p] Commit error for offset ~p of ~p#~p : ~p", [Processing, Offset, Topic, Partition, Reason]),
                      Acc;
                    _ ->
                      perform_fetch(Offsets, [Offset|Acc], Topic, Partition, Autocommit, Processing, Srv, Callback,
                                    MinBytes, MaxBytes, MaxWaitTime)
                  end;
                callback_exception ->
                  Acc;
                {error, Error} ->
                  lager:error("Callback for message #~p of ~p#~p return error : ~p", [Offset, Topic, Partition, Error]),
                  Acc
              end
          end;
        {ok, #{topics :=
               [#{name := Topic,
                  partitions :=
                  [#{error_code := OffsetOutOfRange,
                     partition := Partition}]}]}} ->
          lager:debug("Offset #~p topic ~p:~p : out of range", [Offset, Topic, Partition]),
          perform_fetch(Offsets, Acc, Topic, Partition, Autocommit, Processing, Srv, Callback,
                        MinBytes, MaxBytes, MaxWaitTime);
        Error ->
          lager:error("Failed to fetch message #~p topic ~p:~p : ~p", [Offset, Topic, Partition, Error]),
          Acc
      end;
    false ->
      Acc
  end.

commit(CommitRef, true, Processing, Processing) when Processing == at_least_once;
                                                     Processing == at_most_once ->
  kafe_consumer:commit(CommitRef, #{retry => 3, delay => 1000});
commit(_, _, Processing, _) when Processing == at_least_once;
                                 Processing == at_most_once ->
  ok.


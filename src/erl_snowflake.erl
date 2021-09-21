-module(erl_snowflake).

-export([generate/0, generate_unsafe/0, generate/1, generate_unsafe/1]).
-export([to/2, from/2]).
-export([get_machine_id/0, set_machine_id/1, term_to_machine_id/1, hostname/0]).
-export([snowflake_now/0, get_and_increment_counter/1]).

-type     id() :: {timestamp(), machine_id(), counter()}.
-type format() :: bin | int | str | b62.

-type    counter() :: non_neg_integer().
-type  timestamp() :: non_neg_integer().
-type machine_id() :: non_neg_integer().

-define(max_counter_value, (1 bsl ?counter_bits - 1)).
-define(str_int_base, 62).
-define(rollover_error       , 'maximum counter value reached' ).
-define(time_adjustment_error, 'system time has gone backwards').

-define(id_bin(Timestamp, MachineID, Count),
  <<0:?zero_bits, (Timestamp):?timestamp_bits, (MachineID):?machine_id_bits, (Count):?counter_bits>>
).
-define(id_int(IDInt), <<(IDInt):64/integer>>).

%%

-spec generate() ->
  id().
generate() ->
  try
    generate_unsafe()
  catch
    error:?rollover_error ->
      timer:sleep(1),
      generate_unsafe()
  end.

-spec generate_unsafe() ->
  id().
generate_unsafe() ->
  Timestamp = snowflake_now(),
  {Timestamp, get_machine_id(), get_and_increment_counter(Timestamp)}.

-spec generate(format()) ->
  ID::term().
generate(Format) ->
  to(Format, generate()).

-spec generate_unsafe(format()) ->
  ID::term().
generate_unsafe(Format) ->
  to(Format, generate_unsafe()).

%%

-spec to(format(), id()) ->
  ID::term().
to(Format, ID = {Timestamp, MachineID, Count}) ->
  Bin = ?id_int(IDInt) = ?id_bin(Timestamp, MachineID, Count),
  case Format of
    bin -> Bin;
    int -> IDInt;
    str -> erlang:integer_to_binary(IDInt);
    b62 -> format_int_base(IDInt, ?str_int_base);
    _   -> erlang:error(badarg, [Format, ID])
  end;
to(Format, ID) ->
  erlang:error(badarg, [Format, ID]).

-spec from(format(), ID::term()) ->
  id().
from(bin, ?id_bin(Timestamp, MachineID, Count)) ->
  {Timestamp, MachineID, Count};
from(int, IDInt) ->
  from(bin, ?id_int(IDInt));
from(str, IDStr) ->
  from(int, erlang:binary_to_integer(IDStr));
from(b62, IDB62) ->
  from(int, parse_int_base(IDB62, ?str_int_base));
from(Format, ID) ->
  erlang:error(badarg, [Format, ID]).

%%

-define(pt_get(Key, Expr),
  case persistent_term:get(Key, undefined) of
    undefined ->
      __InitValue = Expr,
      ok = persistent_term:put(Key, __InitValue),
      __InitValue;
    __Value ->
      __Value
  end
).

-spec get_machine_id() ->
  machine_id().
get_machine_id() ->
  ?pt_get(erl_snowflake_machine_id, term_to_machine_id(hostname())).

-spec set_machine_id(machine_id()) ->
  ok.
set_machine_id(MachineID) when is_integer(MachineID) andalso MachineID < 1 bsl ?machine_id_bits ->
  persistent_term:put(erl_snowflake_machine_id, MachineID);
set_machine_id(MachineID) ->
  erlang:error(badarg, [MachineID]).

-spec term_to_machine_id(term()) ->
  machine_id().
term_to_machine_id(Term) ->
  erlang:phash2(Term, 1 bsl ?machine_id_bits).

-spec hostname() ->
  string().
hostname() ->
  case erlang:node() of
    'nonode@nohost' -> {ok, Node} = inet:gethostname(), Node;
    Node            -> erlang:atom_to_list(Node)
  end.

%%

-spec snowflake_now() ->
  timestamp().
snowflake_now() ->
  erlang:system_time(millisecond) - ?epoch.

-spec get_and_increment_counter(timestamp()) ->
  counter().
get_and_increment_counter(Timestamp) ->
  AtomicsRef = ?pt_get(erl_snowflake_counter, atomics:new(1, [{signed, false}])),
  AtomicValue = atomics:get(AtomicsRef, 1),
  get_and_increment_counter(Timestamp, AtomicsRef, AtomicValue).

get_and_increment_counter(Timestamp, AtomicsRef, AtomicValue) ->
  MSInitial = Timestamp bsl ?counter_bits,
  Diff = AtomicValue - MSInitial,
  NewAtomicValue =
    if
      Diff == ?max_counter_value ->
        erlang:error(?rollover_error);
      Diff > ?max_counter_value ->
        erlang:error(?time_adjustment_error);
      Diff >= 0 ->
        AtomicValue + 1;
      true -> % new millisecond
        MSInitial
    end,
  case atomics:compare_exchange(AtomicsRef, 1, AtomicValue, NewAtomicValue) of
    ok ->
      NewAtomicValue band ?max_counter_value;
    UpdatedCounter ->
      get_and_increment_counter(Timestamp, AtomicsRef, UpdatedCounter)
  end.

%%
%% formatting integer with specific base
%% code from https://github.com/rbkmoney/genlib/blob/b08ef4d61e0dde98995ec3d2f69a4447255e79ef/src/genlib_format.erl#L38
%%
-spec format_int_base(integer(), integer()) ->
  binary().
format_int_base(I, Base) when is_integer(Base), Base >= 2, Base =< 62->
  R = list_to_binary(format_int_base(abs(I), Base, [])),
  if
    I >  0 -> R;
    I == 0 -> <<$0>>
  end.

format_int_base(0, _Base, R0) ->
    R0;
format_int_base(I0, Base, R0) ->
    D  = I0 rem Base,
    I1 = I0 div Base,
    R1 =
        if
            D >= 36 -> [D - 36 + $a | R0];
            D >= 10 -> [D - 10 + $A | R0];
            true    -> [D      + $0 | R0]
        end,
    format_int_base(I1, Base, R1).

-spec parse_int_base(binary(), integer()) ->
  integer().
parse_int_base(<<$-, Bin/binary>>, Base) when byte_size(Bin) > 0 ->
  -parse_int_base(Bin, Base);
parse_int_base(Bin, Base) when byte_size(Bin) > 0, is_integer(Base), Base >= 2, Base =< 62 ->
  parse_int_base(Bin, Base, 0).

parse_int_base(<<>>, _Base, R) ->
  R;
parse_int_base(<<D, Bin/binary>>, Base, R0) ->
  parse_int_base(
    Bin,
    Base,
    R0 * Base +
      if
        D >= $a -> D - $a + 36;
        D >= $A -> D - $A + 10;
        true    -> D - $0
      end
  ).

%%
%% tests
%%
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

generate_test() ->
  InitialID = generate(),
  generate_test(InitialID, 1).
generate_test(PrevID = {PrevTimestamp, _, PrevCounter}, Iter) ->
  try
    ID = {Timestamp, _, Counter} = generate_unsafe(),
    case Timestamp == PrevTimestamp of
      true  -> Counter == PrevCounter + 1 orelse erlang:error({'invalid new counter value'   , Iter, PrevID, ID});
      false -> Counter == 0               orelse erlang:error({'invalid new ms counter value', Iter, PrevID, ID})
    end,
    generate_test(ID, Iter + 1)
  catch error:?rollover_error ->
    PrevCounter == ?max_counter_value orelse erlang:error({'invalid max counter value', Iter, PrevID}),
    ok
  end.

different_ms_test() ->
  {Timestamp1, _, _} = generate(),
  ok = timer:sleep(1),
  {Timestamp2, _, _} = generate(),
  ?assertNotEqual(Timestamp1, Timestamp2).

time_ajustments_test() ->
  Timestamp = 1632249289197,
  _ = get_and_increment_counter(Timestamp),
  ?assertException(error, ?time_adjustment_error, get_and_increment_counter(Timestamp - 1)).

formats_test() ->
  ID = {306675022123, 42, 1},
  lists:foreach(
    fun test_format/1,
    [
      {bin, ID, <<17,217,208,94,74,194,160,1>>},
      {int, ID, 1286288271990759425           },
      {str, ID, <<"1286288271990759425">>     },
      {b62, ID, <<"1X1DGM2oOsz">>             }
    ]
  ).

test_format({Format, ID, IDFormatted}) ->
  ?assertEqual(IDFormatted,   to(Format, ID         )),
  ?assertEqual(ID         , from(Format, IDFormatted)).

-endif.

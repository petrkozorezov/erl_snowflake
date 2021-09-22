# erl_snowflake

Erlang fast [snowflake id](https://en.wikipedia.org/wiki/Snowflake_ID) generator. Instead of others erlang snowflake libraries based on `gen_servers` this one uses `persistent_term` and `atomics` for counter storage. This is simple and fast.

## Simple example

```erlang
1> erl_snowflake:generate(b62).
<<"1X1Dr9LDBx3">>
```

## ID formats

There are three representation formats for snowflake id:
 * tuple {timestamp(), machine_id(), counter()}
 * integer
 * binary
 * binary string
 * base62 binary string

```erlang
1> ID = erl_snowflake:generate().
{306679254831,949,1}
2> erl_snowflake:to(bin, ID).
<<17,217,224,131,203,251,80,1>>
3> erl_snowflake:to(int, ID).
1286306025258569729
4> erl_snowflake:to(str, ID).
<<"1286306025258569729">>
5> erl_snowflake:to(b62, ID).
<<"1X1IIuWythR">>
```

## Machine id

By default hash from hostname is used, but you can specify your own by `erl_snowflake:set_machine_id/1`.

```erlang
1> erl_snowflake:get_machine_id().
949
2> erl_snowflake:hostname().
"asrock-x300"
3> erl_snowflake:set_machine_id(erl_snowflake:term_to_machine_id("asrock-x300-1")).
ok
4> erl_snowflake:get_machine_id().
238
```

## ID structure

Classical twitter id structure is 41-10-12
 * 41 timestamp
 * 10 machine id
 * 12 counter

It can be configured via defines for your needs (e.g. as in [instagram](https://instagram-engineering.com/sharding-ids-at-instagram-1cf5a71e5a5c) 41-13-10).

### rebar.config
```erlang
{overrides, [
  {override, erl_snowflake, [
    {erl_opts, [
      % instagram id structure
      {d, timestamp_bits , 41},
      {d, machine_id_bits, 13},
      {d, counter_bits   , 10},
      {d, epoch          , 1314220021721}
    ]}
  ]}
]}.
```

## Rollover

`generate_*` functions check counter rollover and `generate_unsafe` will throw `error:'maximum counter value reached'`, while `generate` function will wait 1 ms and try again (and throw the error if second attemt will fail).

## Time adjustments

If for some reasons (e.g. NTP) time will go backwards `generate_*` functions will throw `error:'system time has gone backwards'` to prevent IDs collision.

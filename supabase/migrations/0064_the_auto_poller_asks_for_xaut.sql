-- 0064_the_auto_poller_asks_for_xaut.sql
--
-- Run this whole file in the Supabase SQL Editor after 0063.
--
-- queue_strategy_checks has asked for every option on the exchange since 0008:
--
--     /v2/tickers?contract_types=call_options,put_options
--
-- no underlying filter, 1079 tickers, 1.37 MB of JSON, of which 159 are XAUT and
-- the rest are read past. pg_net stores that body in net._http_response, so the
-- whole 1.37 MB lands in the database and is written to disk before anything
-- looks at it. The delta engine's own poller has asked the narrow way since
-- 0050; this one was left behind, and 0058's header says so in as many words:
--
--     Note, not fixed here: queue_strategy_checks still pulls the whole exchange
--     once a minute. That is the auto strategy's own poller and its engine reads
--     replies the same loose way, so it deserves the same treatment.
--
-- This is the first half of that treatment. The second half — the auto engine
-- matching its reply by request id rather than by describing it — is 0065.
--
-- Worth being accurate about the size of this: the cron entry is per minute, but
-- the function gates itself to armed accounts inside the first five minutes of
-- the hour, so it is five calls an hour when a book is armed and none when it is
-- not. 6.9 MB/hour becomes 1.0 MB/hour. That is a real saving and a small one;
-- the reason to do it is the next paragraph.
--
-- The unfiltered reply is also the hazard 0058 had to build request-id matching
-- to survive. Two pollers, two replies in the same shared net._http_response
-- table, and the delta engine picked whichever matched a description that fit
-- both — so a 1043-row body carrying BTC at 78,741 became XAUT's spot for every
-- account, permanently. 0058 fixed the matching. Narrowing this reply removes
-- the thing that had to be told apart in the first place: with the filter, the
-- only tickers in the body are the ones both engines want anyway.
--
-- Nothing else in the function changes: the same two gates, the same candle
-- call, the same return of 2.
-- ---------------------------------------------------------------------------

create or replace function public.queue_strategy_checks()
returns integer
language plpgsql
security definer
set search_path = public, net
as $$
declare
  v_now bigint;
begin
  if not exists (select 1 from public.strategy_settings where armed) then
    return 0;
  end if;
  if extract(minute from (now() at time zone 'UTC'))::int >= 5 then
    return 0;
  end if;

  v_now := extract(epoch from now())::bigint;
  perform net.http_get(
    url := 'https://api.india.delta.exchange/v2/history/candles?resolution=1h&symbol=.DEXAUTUSD&start='
           || (v_now - 4 * 3600) || '&end=' || v_now,
    timeout_milliseconds := 5000
  );
  -- The one line this migration exists for.
  perform net.http_get(
    url := 'https://api.india.delta.exchange/v2/tickers'
           || '?contract_types=call_options,put_options'
           || '&underlying_asset_symbols=XAUT',
    timeout_milliseconds := 8000
  );
  return 2;
end;
$$;

-- create or replace keeps a function's ACL, so these are already in force.
-- Restated because the grant surface of a cron-only function is worth being
-- explicit about: nothing outside pg_cron should be able to call it.
revoke all on function public.queue_strategy_checks() from public, anon, authenticated;

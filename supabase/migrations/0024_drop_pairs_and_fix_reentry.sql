-- ============================================================================
-- XAUT Options Paper Trading — one size control, and a session that can reopen
-- Run this whole file in the Supabase SQL Editor after 0023_explicit_expiry.sql.
--
-- Two changes to the delta strategy, both in apply_delta_strategy, so they land
-- together rather than recreating that function twice.
--
-- ---------------------------------------------------------------------------
-- 1. `pairs` goes; `qty` is the only size control
-- ---------------------------------------------------------------------------
-- The spec's N ("sell a symmetric pair … repeat for N pairs") is a quantity, and
-- so is qty. Because the strike is chosen by a rule that gives the same answer
-- each repeat, N pairs was never N *different* pairs — it was N lots of one pair.
-- So the two multiplied into a single lot count:
--
--     lots per leg = round(qty / contract_value) * pairs
--
-- Two knobs for one number is a live footgun: qty 0.01 with pairs 3 sells 30 lots
-- when 10 was meant. qty is kept because it is the more useful unit — the same one
-- the auto strategy and the order ticket use — and no spec parameter is lost:
-- qty *is* N, measured in XAUT instead of lots.
--
-- Existing size is preserved by folding pairs into qty before the column goes, so
-- no account's position size changes on the next entry.
--
-- ---------------------------------------------------------------------------
-- 2. A session that closes and reopens the same day can enter again
-- ---------------------------------------------------------------------------
-- Deselecting a weekday mid-session made the session read closed, which flattened
-- the book and stamped flattened_day. Re-selecting it reopened the session — but
-- entered_day still said today, so the entry branch concluded it had already
-- entered and did nothing. The account sat flat for the rest of the day reporting
-- Δp = 0, which is indistinguishable from a healthy balanced book.
--
-- The flatten now clears entered_day, so a session that reopens can enter again;
-- and the entry clears flattened_day, so the close still flattens afterwards.
-- Clearing only the first would leave flattened_day stamped and skip the 22:00
-- flatten, carrying a position overnight — the two have to move in step.
--
-- Both are only reachable by a config change mid-session (a day toggled, session
-- times edited). At the ordinary close the phase stays closed until the next
-- session day, where the day-change reset zeroes everything anyway.
-- ============================================================================

-- Fold the multiplier into the size it multiplied, then drop it.
update public.delta_strategy_settings
set qty = qty * greatest(pairs, 1)
where pairs is distinct from 1;

alter table public.delta_strategy_settings drop column if exists pairs;

comment on column public.delta_strategy_settings.qty is
  'XAUT per leg at the open, converted to lots by contract_value. The spec''s N, in XAUT rather than lots. Lots scale Δp one-for-one, so raising this means scaling band_low/band_high too.';

-- ---------------------------------------------------------------------------
-- delta_sell_entry loses p_pairs. Signature changes, so it is dropped. The
-- all-or-nothing savepoint from 0019 is unchanged.
-- ---------------------------------------------------------------------------
drop function if exists public.delta_sell_entry(uuid, uuid, text, numeric, numeric, text, int, numeric, numeric);

create or replace function public.delta_sell_entry(p_account uuid, p_user uuid, p_exp text,
                                                   p_entry numeric, p_floor numeric,
                                                   p_tie text, p_qty numeric, p_spot numeric)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  c        record;
  p        record;
  v_before numeric;
  v_after  numeric;
  v_lots_c int;
  v_lots_p int;
begin
  select * into c from public.delta_pick_premium(p_exp, 'call_options', p_entry, p_floor, p_tie, null);
  select * into p from public.delta_pick_premium(p_exp, 'put_options',  p_entry, p_floor, p_tie, null);

  -- Symmetric or not at all: half a pair is a directional position the strategy
  -- never intends to open.
  if c.symbol is null or p.symbol is null then
    raise log 'delta_sell_entry: no symmetric pair at or above the % floor', p_floor;
    return 0;
  end if;

  -- XAUT to lots, per leg, off that contract's own value. A missing or zero
  -- contract_value falls back to one lot rather than sizing off a guess.
  select greatest(1, coalesce(round(p_qty / nullif(contract_value, 0))::int, 1))
    into v_lots_c from public.delta_chain where symbol = c.symbol;
  select greatest(1, coalesce(round(p_qty / nullif(contract_value, 0))::int, 1))
    into v_lots_p from public.delta_chain where symbol = p.symbol;

  if coalesce(v_lots_c, 0) <= 0 or coalesce(v_lots_p, 0) <= 0 then
    raise log 'delta_sell_entry: qty % sized to no lots', p_qty;
    return 0;
  end if;

  -- One block, one implicit savepoint. delta_sell swallows a failed fill and
  -- returns normally, so a leg that did not open is detected by the position not
  -- moving and turned into an exception here — which unwinds everything this block
  -- did, including the other leg's fill.
  begin
    v_before := coalesce((select net_qty from public.positions
                          where account_id = p_account and symbol = c.symbol), 0);
    perform public.delta_sell(p_account, p_user, c.symbol, v_lots_c, p_spot);
    v_after  := coalesce((select net_qty from public.positions
                          where account_id = p_account and symbol = c.symbol), 0);
    -- Selling makes net_qty more negative, so a fill moves this the other way.
    if v_before - v_after <= 0 then
      raise exception 'call leg % did not fill', c.symbol;
    end if;

    v_before := coalesce((select net_qty from public.positions
                          where account_id = p_account and symbol = p.symbol), 0);
    perform public.delta_sell(p_account, p_user, p.symbol, v_lots_p, p_spot);
    v_after  := coalesce((select net_qty from public.positions
                          where account_id = p_account and symbol = p.symbol), 0);
    if v_before - v_after <= 0 then
      raise exception 'put leg % did not fill', p.symbol;
    end if;
  exception when others then
    raise log 'delta_sell_entry: % — entry rolled back, nothing left open', sqlerrm;
    return 0;
  end;

  return 2;
end;
$$;

revoke all on function public.delta_sell_entry(uuid, uuid, text, numeric, numeric, text, numeric, numeric)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- apply_delta_strategy. Body is 0023's; pairs is gone from the entry call, and
-- the flatten and entry branches now clear each other's day stamp.
-- ---------------------------------------------------------------------------
create or replace function public.apply_delta_strategy()
returns integer
language plpgsql
security definer
set search_path = public, net
as $$
declare
  v_tickers   jsonb;
  v_spot      numeric;
  r           record;
  s           record;
  v_phase     text;
  v_day       text;
  v_exp       text;
  v_legs      int;
  v_dp        numeric;
  v_missing   int;
  v_target    numeric;
  v_breach    text;
  v_rollside  text;
  v_sellside  text;
  v_used      int;
  v_leg       record;
  v_repl      record;
  v_pick      record;
  v_q         int;
  v_gap       numeric;
  v_acted     boolean;
  v_n         int := 0;
begin
  select (content::jsonb -> 'result') into v_tickers
  from net._http_response
  where status_code = 200
    and created > now() - interval '180 seconds'
    and content like '%"result":[%'
    and content like '%XAUT%'
    and (content::jsonb -> 'result' -> 0) ? 'greeks'
  order by created desc limit 1;

  if v_tickers is null then
    raise log 'apply_delta_strategy: no fresh XAUT tickers reply';
    return 0;
  end if;

  if not pg_try_advisory_xact_lock(hashtext('delta_strategy_engine')) then
    return 0;
  end if;

  delete from public.delta_chain;
  insert into public.delta_chain (symbol, contract_type, strike, expiry_label,
                                  contract_value, product_id, best_bid, best_ask,
                                  delta, spot_price)
  select (t ->> 'symbol'),
         (t ->> 'contract_type'),
         (t ->> 'strike_price')::numeric,
         split_part((t ->> 'symbol'), '-', 4),
         nullif(t ->> 'contract_value', '')::numeric,
         (t ->> 'product_id')::bigint,
         nullif(t -> 'quotes' ->> 'best_bid', '')::numeric,
         nullif(t -> 'quotes' ->> 'best_ask', '')::numeric,
         nullif(t -> 'greeks' ->> 'delta', '')::numeric,
         nullif(t ->> 'spot_price', '')::numeric
  from jsonb_array_elements(v_tickers) t
  where (t ->> 'symbol') like 'C-XAUT-%' or (t ->> 'symbol') like 'P-XAUT-%'
  on conflict (symbol) do nothing;

  select max(spot_price) into v_spot from public.delta_chain where spot_price is not null;
  if v_spot is null or v_spot <= 0 then
    raise log 'apply_delta_strategy: no spot in the chain';
    return 0;
  end if;

  for r in
    select s2.*, a.user_id
    from public.delta_strategy_settings s2
    join public.accounts a on a.id = s2.account_id
    where s2.armed
  loop
    v_acted := false;
    select * into s from public.delta_strategy_settings where account_id = r.account_id;

    -- Refresh spacing. Clearing last_cycle (the tab's manual refresh) makes the
    -- next tick act regardless of how long the interval is.
    if s.last_cycle is not null
       and now() - s.last_cycle < make_interval(secs => s.cycle_seconds) then
      continue;
    end if;
    update public.delta_strategy_settings set last_cycle = now() where account_id = r.account_id;

    select phase, sday into v_phase, v_day
    from public.delta_session(s.session_open, s.session_close, s.trade_days);

    if s.session_day is distinct from v_day then
      update public.delta_strategy_settings
      set session_day = v_day, rolls_used_call = 0, rolls_used_put = 0,
          entered_day = null, flattened_day = null, touched_symbols = '{}', pass_open = false
      where account_id = r.account_id;
      select * into s from public.delta_strategy_settings where account_id = r.account_id;
    end if;

    -- ---- Session close: flatten, whatever the band says --------------------
    -- entered_day is cleared with the flatten. A session can close and reopen
    -- inside one day — a weekday toggled off and on again, session times edited —
    -- and leaving the stamp made the reopened session refuse to enter, sitting flat
    -- and reporting Δp = 0 for the rest of the day.
    --
    -- Ahead of the expiry check on purpose: a stale expiry must never strand an
    -- open book. Flattening reads the positions, not the setting.
    if v_phase <> 'open' then
      if s.flattened_day is distinct from v_day
         and exists (select 1 from public.positions where account_id = r.account_id and net_qty <> 0) then
        perform public.delta_flatten(r.account_id, r.user_id, v_spot);
        update public.delta_strategy_settings
        set flattened_day = v_day, entered_day = null,
            touched_symbols = '{}', pass_open = false
        where account_id = r.account_id;
        v_n := v_n + 1;
      end if;
      continue;
    end if;

    -- Expiry. A chosen date wins outright, honoured only while listed and
    -- unsettled; with none chosen, expiry_pick's nearest/next applies.
    if s.expiry_label is not null then
      select expiry_label into v_exp
      from public.delta_chain
      where expiry_label = s.expiry_label
        and (to_date(expiry_label, 'DDMMYY')::timestamp at time zone 'UTC') + interval '16 hours' > now()
      group by expiry_label
      limit 1;
    else
      select expiry_label into v_exp
      from public.delta_chain
      where expiry_label ~ '^\d{6}$'
        and (to_date(expiry_label, 'DDMMYY')::timestamp at time zone 'UTC') + interval '16 hours' > now()
      group by expiry_label
      order by to_date(expiry_label, 'DDMMYY') asc
      offset (case when s.expiry_pick = 'next' then 1 else 0 end)
      limit 1;
      if v_exp is null then
        select expiry_label into v_exp
        from public.delta_chain
        where expiry_label ~ '^\d{6}$'
          and (to_date(expiry_label, 'DDMMYY')::timestamp at time zone 'UTC') + interval '16 hours' > now()
        group by expiry_label
        order by to_date(expiry_label, 'DDMMYY') asc limit 1;
      end if;
    end if;

    if v_exp is null then
      raise log 'apply_delta_strategy: account % — expiry % unavailable, standing down',
        r.account_id, coalesce(s.expiry_label, '(by rule)');
      continue;
    end if;

    -- ---- S4: daily entry ---------------------------------------------------
    -- The day is stamped only once a full pair is open, and flattened_day is
    -- cleared with it so the close still flattens what this entry opened.
    if s.entered_day is distinct from v_day then
      v_legs := public.delta_sell_entry(r.account_id, r.user_id, v_exp, s.entry_premium,
                                        s.min_premium, s.tie_break, s.qty, v_spot);
      if v_legs < 2 then
        raise log 'apply_delta_strategy: account % entry did not fill, retrying next refresh',
          r.account_id;
        continue;
      end if;

      update public.delta_strategy_settings
      set entered_day = v_day, flattened_day = null
      where account_id = r.account_id;
      v_n := v_n + 1;
      continue;
    end if;

    -- ---- Net portfolio delta ----------------------------------------------
    select count(*) filter (where c.delta is null), coalesce(sum(p.net_qty * c.delta), 0)
      into v_missing, v_dp
    from public.positions p
    left join public.delta_chain c on c.symbol = p.symbol
    where p.account_id = r.account_id and p.net_qty <> 0;

    if v_missing > 0 then
      raise log 'apply_delta_strategy: account % waiting on greeks for % leg(s)', r.account_id, v_missing;
      continue;
    end if;

    v_breach := case when v_dp < s.band_low then 'low'
                     when v_dp > s.band_high then 'high' end;

    if v_breach is null then
      if s.pass_open then
        update public.delta_strategy_settings
        set pass_open = false, touched_symbols = '{}' where account_id = r.account_id;
      end if;
      continue;
    end if;

    if s.target_landing = 'mid' then
      v_target := (s.band_low + s.band_high) / 2;
    elsif v_breach = 'low' then
      v_target := least(s.band_low + s.band_buffer, (s.band_low + s.band_high) / 2);
    else
      v_target := greatest(s.band_high - s.band_buffer, (s.band_low + s.band_high) / 2);
    end if;

    v_rollside := case when v_breach = 'low' then 'call_options' else 'put_options' end;
    v_sellside := case when v_breach = 'low' then 'put_options'  else 'call_options' end;
    v_used     := case when v_breach = 'low' then s.rolls_used_call else s.rolls_used_put end;

    -- ---- S5.1/5.2: walk the ITM queue, most-ITM first ----------------------
    for v_leg in
      select p.id, p.symbol, p.net_qty, p.strike_price::numeric as strike, p.contract_value,
             p.product_id, c.delta, c.best_ask,
             case when p.contract_type = 'call_options' then v_spot - p.strike_price::numeric
                  else p.strike_price::numeric - v_spot end as itm_distance
      from public.positions p
      join public.delta_chain c on c.symbol = p.symbol
      where p.account_id = r.account_id
        and p.net_qty < 0
        and p.contract_type = v_rollside
        and not (p.symbol = any (s.touched_symbols))
        and (case when p.contract_type = 'call_options' then v_spot - p.strike_price::numeric
                  else p.strike_price::numeric - v_spot end) >= s.itm_trigger
      order by itm_distance desc
    loop
      if v_used >= s.max_rolls then
        perform public.delta_close_leg(r.account_id, r.user_id, v_leg.symbol, abs(v_leg.net_qty), v_spot);
        update public.delta_strategy_settings
        set touched_symbols = array_append(touched_symbols, v_leg.symbol)
        where account_id = r.account_id;
        v_acted := true;
        exit;
      end if;

      select * into v_repl from public.delta_pick_premium(
        v_exp, v_rollside, s.entry_premium, s.min_premium, s.tie_break, v_leg.strike);
      if v_repl.symbol is null then continue; end if;

      v_gap := abs(v_leg.delta) - abs(v_repl.delta);
      if v_gap <= 0 then continue; end if;

      v_q := floor(abs(v_target - v_dp) / v_gap + 1e-9)::int;
      v_q := least(v_q, abs(v_leg.net_qty));
      if v_q <= 0 then continue; end if;

      perform public.delta_close_leg(r.account_id, r.user_id, v_leg.symbol, v_q, v_spot);
      perform public.delta_sell(r.account_id, r.user_id, v_repl.symbol, v_q, v_spot);

      update public.delta_strategy_settings
      set touched_symbols = array_append(touched_symbols, v_leg.symbol),
          pass_open = true,
          rolls_used_call = rolls_used_call
            + case when v_rollside = 'call_options'
                        and (s.roll_counts = 'strike' or not s.pass_open) then 1 else 0 end,
          rolls_used_put = rolls_used_put
            + case when v_rollside = 'put_options'
                        and (s.roll_counts = 'strike' or not s.pass_open) then 1 else 0 end
      where account_id = r.account_id;

      v_acted := true;
      exit;
    end loop;

    if v_acted then
      v_n := v_n + 1;
      continue;
    end if;

    -- ---- S5.4: band correction, no ITM leg left to roll --------------------
    select * into v_pick from public.delta_pick_delta(
      v_exp, v_sellside, s.band_delta_low, s.band_delta_high, s.min_premium);
    if v_pick.symbol is null then
      raise log 'apply_delta_strategy: account % has no % strike in the %-% delta range',
        r.account_id, v_sellside, s.band_delta_low, s.band_delta_high;
      continue;
    end if;

    v_q := floor(abs(v_target - v_dp) / abs(v_pick.delta) + 1e-9)::int;
    if v_q <= 0 then continue; end if;

    perform public.delta_sell(r.account_id, r.user_id, v_pick.symbol, v_q, v_spot);
    v_n := v_n + 1;
  end loop;

  return v_n;
end;
$$;

revoke all on function public.apply_delta_strategy() from public, anon, authenticated;

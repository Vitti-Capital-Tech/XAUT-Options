-- 0073_pair_the_legs_that_match.sql
--
-- Run this whole file in the Supabase SQL Editor after 0072.
--
-- A call sold at $2.83 against a put sold at $5.00, while a $3.00 put sat
-- unused one rank below it.
--
-- `delta_sell_entry` ranks each side on its own and then joins them on rank:
--
--     from ca join pu on pu.rn = ca.rn
--
-- Pair 1 is the best call against the best put, pair 2 the second against the
-- second. That is correct while both sides offer the same ladder, and since both
-- are ranked by the same rule — nearest the top of the premium range — for a
-- long time they did.
--
-- It fails when the two sides are different lengths, and on a hard premium range
-- that is most of the time: a $3–$5 band that admits three put strikes may admit
-- one call. The join then takes the *top* of each list and pairs them, so a lone
-- call at $2.83 is sold against the richest put at $5.00 — with a $3.00 put, the
-- obvious partner, one rank further down and never reached.
--
-- ---------------------------------------------------------------------------
-- Why this is not cosmetic
-- ---------------------------------------------------------------------------
--
-- The two legs of a pair are meant to sit the same distance out on either side
-- of spot, and premium is how this strategy measures that distance — it is the
-- unit the range itself is written in. $2.83 of call against $5.00 of put is not
-- a symmetric strangle: it is short substantially more put than call, from the
-- moment it opens. Δp starts skewed, the hedge answers a skew the entry created,
-- and the book carries it until something closes.
--
-- It also shows up plainly at the other end. Every leg of a pair closes together
-- at the window's flatten, so the trade history shows a $2.83 leg and a $5.00 leg
-- exiting side by side — which is where this was noticed. The exit is only
-- reporting what the entry decided.
--
-- ---------------------------------------------------------------------------
-- The rule
-- ---------------------------------------------------------------------------
--
-- Take the **closest remaining pair on the board** each time, by premium.
-- $2.83 takes the $3.00; $4.20 takes the $4.00. Nothing close left means the
-- nearest of whatever remains, because half a pair is a directional position
-- this strategy never opens.
--
-- Closest-on-the-board rather than closest-for-each-call-in-turn, and the
-- difference shows the moment the two sides are different lengths in the other
-- direction. Calls at $4.90, $4.50, $2.83 against puts at $5.00 and $3.00: walk
-- the calls in order and the $4.50 takes the $3.00 — a gap of 1.50 — leaving the
-- $2.83 that would have matched it to within 0.17 with nothing. Taking the
-- smallest gap first gives $4.90/$5.00 and $2.83/$3.00, and simply does not sell
-- the $4.50 call, because no put in range pairs with it.
--
-- That trade is deliberate: give up the premium on a leg rather than open a pair
-- short far more of one side than the other. Symmetry is what the strategy *is*,
-- and a skew opened here is one the hedge has to pay to correct.
--
-- Both sides are read once into arrays before the loop, because "the nearest one
-- not already taken" cannot be expressed as a join — it needs the taken set
-- carried from row to row. Legs are marked spent only once their pair has landed,
-- which keeps the rule the rest of the function follows: the book says what is
-- taken, not the intention to take it.
--
-- ---------------------------------------------------------------------------
-- Scope
-- ---------------------------------------------------------------------------
--
-- `delta_sell_entry` only. No engine change, no schema change. It is the one
-- function that opens pairs, so the opening entry and the top-up
-- ([`0070`](0070_fill_the_pairs_the_window_asked_for.sql)) both get this from
-- the same place.
--
-- The delta book calls it with `p_pairs = 1` and no range, where both sides
-- offer their single nearest-to-`entry_premium` strike and the matching is the
-- same pair the join would have produced.
-- ---------------------------------------------------------------------------

create or replace function public.delta_sell_entry(
  p_account uuid,
  p_user    uuid,
  p_exp     text,
  p_entry   numeric,
  p_floor   numeric,
  p_tie     text,
  p_qty     numeric,
  p_spot    numeric,
  p_cap     numeric default 0,
  p_pairs   int     default 1,
  p_ceil    numeric default 0
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_before numeric;
  v_after  numeric;
  v_lots_c int;
  v_lots_p int;
  v_room   int;
  v_want   int := greatest(1, coalesce(p_pairs, 1));
  -- 0070: strikes this book is already short on the traded expiry, and how deep
  -- to rank so that many can be skipped and `v_want` unheld pairs still remain.
  v_held   int := 0;
  v_depth  int;
  -- 0073: the put side, held as parallel arrays so a call can be matched to the
  -- nearest unused put by premium. A set-returning function cannot express
  -- "nearest one not already taken" without carrying the taken set between rows,
  -- and that is what these are.
  v_c_sym    text[];
  v_c_prem   numeric[];
  v_c_strike numeric[];
  v_c_room   int[];
  v_c_used   boolean[];
  v_p_sym    text[];
  v_p_prem   numeric[];
  v_p_strike numeric[];
  v_p_room   int[];
  v_p_used   boolean[];
  v_ci       int;
  v_pi       int;
  v_gap      numeric;
  v_rank     int := 0;
  i          int;
  j          int;
  v_done   int := 0;
  v_seen   int := 0;
  v_ok     boolean;
  v_desc   text := '';
begin
  -- 0070: rank past what we already hold.
  --
  -- `p_pairs` is how many pairs to open *now*, not how many the window wants in
  -- total, because this is called twice: once for the opening entry on a flat
  -- book, and again on any later cycle where the window's allocation is still
  -- short. On the second call the strikes from the first are already on the
  -- book, and re-selling one of them would deepen a strike rather than add a
  -- pair. So held strikes are dropped below, and the ranking is asked for enough
  -- rows that dropping them still leaves `v_want` to pair up.
  select count(distinct symbol) into v_held
  from public.positions
  where account_id = p_account
    and net_qty < 0
    and contract_type in ('call_options', 'put_options')
    and coalesce(expiry_label, split_part(symbol, '-', 4)) = p_exp;

  v_depth := v_want + coalesce(v_held, 0);

  -- Both sides, ranked once and then matched rather than joined.
  select array_agg(k.symbol    order by k.rank),
         array_agg(k.premium   order by k.rank),
         array_agg(k.strike    order by k.rank),
         array_agg(k.room_lots order by k.rank)
    into v_p_sym, v_p_prem, v_p_strike, v_p_room
  from public.delta_pick_premium_ranked(p_exp, 'put_options', p_entry, p_floor,
                                        p_tie, p_spot, p_account, p_cap, p_spot,
                                        p_ceil, v_depth) k
  where not exists (select 1 from public.positions po
                    where po.account_id = p_account
                      and po.symbol = k.symbol
                      and po.net_qty < 0);

  select array_agg(k.symbol    order by k.rank),
         array_agg(k.premium   order by k.rank),
         array_agg(k.strike    order by k.rank),
         array_agg(k.room_lots order by k.rank)
    into v_c_sym, v_c_prem, v_c_strike, v_c_room
  from public.delta_pick_premium_ranked(p_exp, 'call_options', p_entry, p_floor,
                                        p_tie, p_spot, p_account, p_cap, p_spot,
                                        p_ceil, v_depth) k
  where not exists (select 1 from public.positions po
                    where po.account_id = p_account
                      and po.symbol = k.symbol
                      and po.net_qty < 0);

  if coalesce(array_length(v_c_sym, 1), 0) = 0
     or coalesce(array_length(v_p_sym, 1), 0) = 0 then
    -- Symmetric or not at all, so an empty side opens nothing. Said only on an
    -- opening entry: holding nothing and finding no pair is a book that did not
    -- open and wants explaining, while holding something and finding no
    -- *further* pair is the ordinary state of a top-up waiting on the chain --
    -- true every cycle for as long as the range stays thin.
    if coalesce(v_held, 0) = 0 then
      raise log 'delta_sell_entry: no % in [%, %] with room under the cap',
        case when coalesce(array_length(v_c_sym, 1), 0) = 0 then 'call' else 'put' end,
        p_floor, p_ceil;
    end if;
    return null;
  end if;

  v_c_used := array_fill(false, array[array_length(v_c_sym, 1)]);
  v_p_used := array_fill(false, array[array_length(v_p_sym, 1)]);

  -- Both sides ranked to the requested depth and joined on rank: pair 1 is the
  -- best call against the best put, pair 2 the second against the second, and so
  -- on — which is the pairing the readout draws. The inner join is what keeps the
  -- entry symmetric: a side that ranks fewer strikes than the other simply ends
  -- the list, rather than pairing a call with a put from a different rank.
  --
  -- Ranked once, before the first sale. delta_pick_premium_ranked is `stable`, so
  -- it is read against this statement's snapshot and the strikes do not shuffle
  -- underneath the loop as earlier pairs fill and consume their own room.
  -- 0060: out of the money only — `p_beyond` is p_spot, not null.
  --
  -- The picker ranks by premium and, until now, judged nothing against spot. So
  -- it could sell a strike that was already at or through the money, and the ATM
  -- rule would close that same leg on the very next cycle: an instant round trip
  -- paying two spreads and two fees for nothing. On 02 Sep it opened 4320/4330/
  -- 4340 calls and closed all three within eighteen seconds.
  --
  -- The stale spot that made those strikes look in the money is fixed above, but
  -- the entry should not have depended on spot being right to avoid selling into
  -- the money. `p_beyond` already means "strictly further out than this" — calls
  -- above it, puts below it — so passing spot is all it takes. A short strangle
  -- is out of the money on both sides by definition; there was never a case for
  -- letting the entry pick otherwise.
  --
  -- 0073: a call is paired with the put nearest it *in premium*, not with the
  -- put of the same rank.
  --
  -- Rank-to-rank is right while both sides offer the same ladder, and both are
  -- ranked by the same rule, so for a long time it was. It fails when the two
  -- sides are different lengths — which on a hard premium range is most of the
  -- time, because a range that admits three put strikes may admit one call. The
  -- join then takes the *top* of each list, and a lone call at $2.83 is sold
  -- against the richest put at $5.00 while the $3.00 put sits unused one rank
  -- below it.
  --
  -- That is not a strangle. The two legs of a pair are meant to be the same
  -- distance out on either side of spot, and premium is how this strategy
  -- measures that distance — it is what the range is written in. A $2.83 call
  -- against a $5.00 put is short far more put than call, and the book carries
  -- that skew until something closes it.
  --
  -- So: walk the calls richest-first, and give each the nearest unused put.
  -- $2.83 takes the $3.00, $4.20 takes the $4.00. Nothing close left means the
  -- nearest of whatever remains, because half a pair is not an option.
  --
  -- Greedy in call order rather than a full assignment: the lists are at most a
  -- handful long, both are already sorted by premium, and for two sorted lists
  -- of equal length this *is* the optimal matching. The case it does not solve
  -- perfectly — more calls than puts, where an earlier call takes a put a later
  -- one would have matched better — costs one pair's tightness and is not worth
  -- an assignment algorithm inside an entry that has to finish in a cycle.
  while v_done < v_want loop
    -- The closest remaining pair on the whole board, not the closest partner for
    -- whichever call happens to come first.
    --
    -- Walking the calls in rank order and giving each its nearest put is the
    -- obvious version and it is not quite right: with calls at $4.90, $4.50,
    -- $2.83 against puts at $5.00 and $3.00, the $4.50 takes the $3.00 — a gap of
    -- 1.50 — and the $2.83 that would have matched it to within 0.17 is left with
    -- nothing. Taking the smallest gap on the board each time gives $4.90/$5.00
    -- and $2.83/$3.00, and simply does not sell the $4.50 call, because no put in
    -- range pairs with it.
    --
    -- That trade is deliberate: it gives up premium on a leg rather than open a
    -- pair that is short far more of one side than the other. Symmetry is what
    -- the strategy is, and a skew opened here is one the hedge has to pay to
    -- correct.
    --
    -- Scanned call-rank outer, put-rank inner, with a strict `<`, so equal gaps
    -- leave the better-ranked — the richer — pair holding it. O(want x C x P) on
    -- lists that are a handful of strikes long.
    v_ci  := null;
    v_pi  := null;
    v_gap := null;

    for i in 1 .. array_length(v_c_sym, 1) loop
      if not v_c_used[i] then
        for j in 1 .. array_length(v_p_sym, 1) loop
          if not v_p_used[j] then
            if v_gap is null or abs(v_p_prem[j] - v_c_prem[i]) < v_gap then
              v_gap := abs(v_p_prem[j] - v_c_prem[i]);
              v_ci  := i;
              v_pi  := j;
            end if;
          end if;
        end loop;
      end if;
    end loop;

    -- One side spoken for entirely. Half a pair is a directional position the
    -- strategy never opens, so this is the end of the entry.
    exit when v_ci is null;

    v_seen := v_seen + 1;
    v_rank := v_rank + 1;

    -- XAUT to lots, per leg, off that contract's own value. A missing or zero
    -- contract_value falls back to one lot rather than sizing off a guess.
    select greatest(1, coalesce(round(p_qty / nullif(contract_value, 0))::int, 1))
      into v_lots_c from public.delta_chain where symbol = v_c_sym[v_ci];
    select greatest(1, coalesce(round(p_qty / nullif(contract_value, 0))::int, 1))
      into v_lots_p from public.delta_chain where symbol = v_p_sym[v_pi];

    -- The tighter of the two rooms, applied to both. `least` ignores nulls, so
    -- an unset cap leaves this at the sizes above.
    v_room := least(v_c_room[v_ci], v_p_room[v_pi]);
    if v_room is not null then
      v_lots_c := least(v_lots_c, v_room);
      v_lots_p := least(v_lots_p, v_room);
    end if;

    if coalesce(v_lots_c, 0) <= 0 or coalesce(v_lots_p, 0) <= 0 then
      raise log 'delta_sell_entry: pair %/% — qty % sized to no lots', v_rank, v_want, p_qty;
      exit;
    end if;

    -- One block, one implicit savepoint. delta_sell swallows a failed fill and
    -- returns normally, so a leg that did not open is detected by the position
    -- not moving and turned into an exception here — which unwinds everything
    -- this block did, including the other leg's fill.
    --
    -- The outcome leaves the block in v_ok rather than exiting the loop from
    -- inside the handler: an exception rolls back the block's database work but
    -- leaves plpgsql variables as they stood, so a flag set on the last line is
    -- a reliable "both legs landed" and needs no reasoning about control flow
    -- out of a handler.
    v_ok := false;
    begin
      v_before := coalesce((select net_qty from public.positions
                            where account_id = p_account and symbol = v_c_sym[v_ci]), 0);
      perform public.delta_sell(p_account, p_user, v_c_sym[v_ci], v_lots_c, p_spot);
      v_after  := coalesce((select net_qty from public.positions
                            where account_id = p_account and symbol = v_c_sym[v_ci]), 0);
      -- Selling makes net_qty more negative, so a fill moves this the other way.
      if v_before - v_after <= 0 then
        raise exception 'call leg % did not fill', v_c_sym[v_ci];
      end if;

      v_before := coalesce((select net_qty from public.positions
                            where account_id = p_account and symbol = v_p_sym[v_pi]), 0);
      perform public.delta_sell(p_account, p_user, v_p_sym[v_pi], v_lots_p, p_spot);
      v_after  := coalesce((select net_qty from public.positions
                            where account_id = p_account and symbol = v_p_sym[v_pi]), 0);
      if v_before - v_after <= 0 then
        raise exception 'put leg % did not fill', v_p_sym[v_pi];
      end if;

      v_ok := true;
    exception when others then
      raise log 'delta_sell_entry: pair %/% — % — pair rolled back, nothing left open',
        v_rank, v_want, sqlerrm;
    end;

    if not v_ok then
      exit;
    end if;

    -- Spent only now. A pair that rolled back would leave both legs free for the
    -- next pass — except that a failed fill ends the entry anyway, above. Marking
    -- them here rather than at selection keeps the rule the same one the rest of
    -- this function follows: the book says what is taken, not the intention.
    v_c_used[v_ci] := true;
    v_p_used[v_pi] := true;

    v_done := v_done + 1;
    v_desc := v_desc
      || case when v_desc = '' then '' else ', ' end
      || format('%s × %sC @ $%s / %s × %sP @ $%s',
                v_lots_c, round(v_c_strike[v_ci], 0), round(v_c_prem[v_ci], 2),
                v_lots_p, round(v_p_strike[v_pi], 0), round(v_p_prem[v_pi], 2));
  end loop;

  -- No pair at all is a failed entry: the caller must not stamp the day, so the
  -- next refresh tries again rather than writing the session off.
  if v_done = 0 then
    return null;
  end if;

  return case when v_done = v_want then v_desc
              else format('%s of %s pairs — %s', v_done, v_want, v_desc) end;
end;
$$;
revoke all on function public.delta_sell_entry(uuid, uuid, text, numeric, numeric, text,
                                               numeric, numeric, numeric, int, numeric)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Resolve every name at apply time, and prove the rule changed
-- ---------------------------------------------------------------------------
do $$
declare
  v_entry text;
  v_eng   text;
begin
  select pr.prosrc into v_entry from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
  where ns.nspname = 'public' and pr.proname = 'delta_sell_entry';
  select pr.prosrc into v_eng from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
  where ns.nspname = 'public' and pr.proname = 'apply_delta_strategy';

  -- Exactly one definition. A widened signature would add an overload rather
  -- than replace, and 0048 shipped three ambiguous call sites that way.
  if (select count(*) from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
      where ns.nspname = 'public' and pr.proname = 'delta_sell_entry') <> 1 then
    raise exception 'delta_sell_entry is overloaded — call sites are ambiguous';
  end if;

  -- 1. The rank join is gone, and the premium match is there.
  if v_entry like '%join pu on pu.rn = ca.rn%' then
    raise exception 'delta_sell_entry still pairs the two sides on rank';
  end if;
  if v_entry not like '%abs(v_p_prem[j] - v_c_prem[i]) < v_gap%' then
    raise exception 'delta_sell_entry does not match legs by premium distance';
  end if;
  -- Both sides scanned, not one. A single loop is the call-order variant, which
  -- strands a cheap call when a dearer one has already taken its partner.
  if v_entry not like '%for i in 1 .. array_length(v_c_sym, 1) loop%'
     or v_entry not like '%for j in 1 .. array_length(v_p_sym, 1) loop%' then
    raise exception 'delta_sell_entry does not search both sides for the closest pair';
  end if;

  -- 2. A put is spent by a pair that landed, never by one that rolled back.
  if v_entry not like '%v_p_used[v_pi] := true;%'
     or v_entry not like '%v_c_used[v_ci] := true;%' then
    raise exception 'delta_sell_entry never marks a matched leg as taken';
  end if;
  -- After the rollback check, not before it. Legs marked taken by a pair that
  -- then failed to fill are legs the next pass cannot use, for no reason.
  if position('v_p_used[v_pi] := true;' in v_entry)
     < position('if not v_ok then' in v_entry) then
    raise exception 'delta_sell_entry marks a leg taken before its pair has landed';
  end if;

  -- 3. Carried forward from 0070: held strikes are still skipped, or a top-up
  --    would deepen a leg instead of adding a pair.
  if v_entry not like '%where not exists (select 1 from public.positions po%' then
    raise exception 'delta_sell_entry no longer skips strikes it already holds (0070)';
  end if;

  -- 4. And the engine still reaches it from both entry paths.
  if v_eng not like '%entry_top_up%' then
    raise exception 'the top-up branch is missing (0070)';
  end if;

  perform 1 from public.delta_pick_premium_ranked('010101', 'call_options', 0, 2, 'closest',
                                                  null, null, 0, null, 5, 3);

  raise log '0073: a call is paired with the put nearest it in premium';
end;
$$;

-- And a data check on the matcher's *input*, which is the half that can be
-- checked without placing a trade: with one call in range against three puts,
-- the $3.00 put must be a candidate and must be the one nearest $2.83. It does
-- not execute delta_sell_entry -- that sells -- so it proves the candidate set
-- and the comparison the loop makes, not the loop itself. That much is still
-- worth having: a range or filter regression that dropped the $3.00 put from
-- candidacy would leave the matcher correct and the pairing wrong again.
do $$
declare
  v_acct uuid;
  v_user uuid;
  v_desc text;
  v_put  text;
begin
  select dss.account_id, a.user_id into v_acct, v_user
  from public.delta_strategy_settings dss
  join public.accounts a on a.id = dss.account_id
  limit 1;

  if v_acct is null then
    raise log '0073: no strategy account to check the pairing against';
    return;
  end if;

  -- A chain where the call side offers exactly one strike inside $2-$6 and the
  -- put side offers three. The $2.83 call must take the $3.00 put, not the $5.00.
  insert into public.delta_chain (symbol, contract_type, strike, expiry_label,
                                  contract_value, best_bid, best_ask, delta, gamma,
                                  spot_price, mark_price)
  values ('C-XAUT-4100-073CHK', 'call_options', 4100, '073CHK', 0.001, 2.83, 2.90,  0.20, 0.001, 4000, 2.86),
         ('C-XAUT-4050-073CHK', 'call_options', 4050, '073CHK', 0.001, 9.00, 9.10,  0.40, 0.001, 4000, 9.05),
         ('P-XAUT-3900-073CHK', 'put_options',  3900, '073CHK', 0.001, 5.00, 5.10, -0.30, 0.001, 4000, 5.05),
         ('P-XAUT-3850-073CHK', 'put_options',  3850, '073CHK', 0.001, 4.00, 4.10, -0.25, 0.001, 4000, 4.05),
         ('P-XAUT-3800-073CHK', 'put_options',  3800, '073CHK', 0.001, 3.00, 3.10, -0.20, 0.001, 4000, 3.05)
  on conflict (symbol) do nothing;

  -- Ranking only — no sale. delta_pick_premium_ranked is `stable`, so this reads
  -- the same snapshot the entry would and touches nothing.
  select k.symbol into v_put
  from public.delta_pick_premium_ranked('073CHK', 'put_options', 0, 2, 'closest',
                                        4000, v_acct, 0, 4000, 6, 10) k
  order by abs(k.premium - 2.83)
  limit 1;

  delete from public.delta_chain where expiry_label = '073CHK';

  if v_put is distinct from 'P-XAUT-3800-073CHK' then
    raise exception 'the $2.83 call should match the $3.00 put, got %', coalesce(v_put, '(none)');
  end if;

  raise log '0073: the $3.00 put is a candidate and is the nearest to a $2.83 call';
end;
$$;

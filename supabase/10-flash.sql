-- 10. 결제 속보: 수집기가 카드 알림을 보낸 직후 "이 카드 이번 달 남은 예산"을 물어봐요.
--   수집기는 로그인하지 않으니(anon), 방금 보낸 알림의 client_id(내용 해시)를 아는 경우에만,
--   그리고 10분 안에 들어온 알림에 대해서만 답해요.
--   계산은 웹 화면(monthOf)과 같은 규칙: 할부 회차, 카드 자동이체, 돌려받는 결제 제외, 예산 이어받기.

create or replace function gagyebu.bill_month_of(cid text, d date)
returns int language sql stable as $$
  select case when extract(day from d) >= c.cycle_start
              then (extract(year from (d + interval '1 month'))::int * 100 + extract(month from (d + interval '1 month'))::int)
              else extract(year from d)::int * 100 + extract(month from d)::int end
  from gagyebu.cards c where c.id = cid;
$$;

create or replace function gagyebu.bm_diff(a int, b int)   -- a - b (개월)
returns int language sql immutable as $$
  select (a / 100 - b / 100) * 12 + (a % 100 - b % 100);
$$;

create or replace function gagyebu.card_month(cid text, bm int)
returns jsonb language plpgsql stable security definer set search_path = gagyebu, public as $$
declare
  c gagyebu.cards; mine bigint := 0; back bigint := 0; budget int;
  p record; i record; n int; k int; mon int; bm0 int; share bigint;
  prev int := case when bm % 100 = 1 then bm - 89 else bm - 1 end;
  d date; amt int; dup boolean; ruled boolean; obm int;
begin
  select * into c from gagyebu.cards where id = cid;
  if not found then return null; end if;

  for p in select * from gagyebu.payments where card_id = cid and not hidden loop
    n := greatest(coalesce(p.months, 1), 1);
    bm0 := coalesce(p.first_bill_month, gagyebu.bill_month_of(cid, (p.paid_at at time zone 'Asia/Seoul')::date));
    -- 취소: 원래 결제 달의 결제일 전에 들어오면 그 달 카드값에서 빠져요 (웹 cancelBM과 같은 규칙)
    if p.amount < 0 and p.first_bill_month is null then
      select coalesce(o.first_bill_month, gagyebu.bill_month_of(cid, (o.paid_at at time zone 'Asia/Seoul')::date)) into obm
      from gagyebu.payments o
      where o.card_id = cid and not o.hidden and o.amount = -p.amount and coalesce(o.months, 1) <= 1
        and o.paid_at <= p.paid_at and o.paid_at > p.paid_at - interval '90 days'
      order by o.paid_at desc limit 1;
      if obm is not null and (p.paid_at at time zone 'Asia/Seoul')::date <= make_date(obm / 100, obm % 100, c.pay_day) then
        bm0 := obm;
      end if;
      obm := null;
    end if;
    k := gagyebu.bm_diff(bm, bm0) + 1;
    continue when k < 1 or k > n;
    if n = 1 then share := p.amount;
    else
      mon := coalesce(p.monthly, floor(p.amount::numeric / n / c.installment_unit)::int * c.installment_unit);
      share := case when k = 1 then p.amount - mon * (n - 1) else mon end;
    end if;
    if p.reimbursed then back := back + share; else mine := mine + share; end if;
  end loop;

  -- 카드 자동이체 (계획 탭). 같은 금액의 실제 기록이 앞뒤 4일 안에 있으면 이미 센 것
  for i in select * from gagyebu.plan_items
           where method = c.name and kind in ('fixed', 'subscription')
             and (start_month is null or start_month <= bm) and (end_month is null or end_month >= bm) loop
    amt := case when i.kind = 'subscription' then coalesce(i.total, i.amount) else i.amount end;
    begin
      d := case when coalesce(i.pay_day, c.cycle_start) >= c.cycle_start
                then make_date(prev / 100, prev % 100, least(coalesce(i.pay_day, c.cycle_start), 28))
                else make_date(bm / 100, bm % 100, least(i.pay_day, 28)) end;
    exception when others then continue;
    end;
    select exists (select 1 from gagyebu.payments x where x.card_id = cid and not x.hidden and x.amount = amt
                   and abs((x.paid_at at time zone 'Asia/Seoul')::date - d) <= 4) into dup;
    continue when dup;
    select exists (select 1 from gagyebu.reimburse_rules r where r.card_id = cid and r.amount = amt
                   and position(r.merchant_key in gagyebu.norm_merchant(i.name)) > 0) into ruled;
    if ruled then back := back + amt; else mine := mine + amt; end if;
  end loop;

  select b.amount into budget from gagyebu.budgets b where b.card_id = cid and b.bill_month <= bm
  order by b.bill_month desc limit 1;

  return jsonb_build_object('card', c.name, 'bill_month', bm, 'mine', mine, 'back', back,
    'budget', coalesce(budget, 0), 'left', coalesce(budget, 0) - mine,
    'pct', case when coalesce(budget, 0) > 0 then round(mine * 100.0 / budget) end);
end;
$$;
revoke all on function gagyebu.card_month(text, int) from public, anon, authenticated;

create or replace function gagyebu.flash(cid text)
returns jsonb language plpgsql stable security definer set search_path = gagyebu, public as $$
declare r gagyebu.inbox; pay gagyebu.payments; s jsonb;
begin
  select * into r from gagyebu.inbox where client_id = cid and created_at > now() - interval '10 minutes';
  if not found or r.kind not in ('payment', 'cancel') or r.card_id is null then return null; end if;
  select * into pay from gagyebu.payments where source_ref = 'inbox:' || r.id;
  s := gagyebu.card_month(r.card_id,
         gagyebu.bill_month_of(r.card_id, (coalesce(r.approved_at, r.posted_at, now()) at time zone 'Asia/Seoul')::date));
  return s || jsonb_build_object('kind', r.kind, 'amount', r.amount, 'merchant', r.merchant,
    'months', coalesce(r.months, 1), 'reimbursed', coalesce(pay.reimbursed, false));
end;
$$;
revoke all on function gagyebu.flash(text) from public;
grant execute on function gagyebu.flash(text) to anon, authenticated;

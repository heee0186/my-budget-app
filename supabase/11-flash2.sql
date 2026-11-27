-- 11. 결제 속보 2: 삼성페이 신호, 메모 바로 열기, 상황별 멘트용 정보
--   via_spay: 수집기가 "카드 알림 직전 2분 안에 삼성월렛 알림이 있었다"고 본 결제 (내용은 안 보냄)

alter table gagyebu.inbox add column if not exists via_spay boolean;

create or replace function gagyebu.flash(cid text)
returns jsonb language plpgsql stable security definer set search_path = gagyebu, public as $$
declare r gagyebu.inbox; pay gagyebu.payments; s jsonb; t timestamp; k text; same int;
begin
  select * into r from gagyebu.inbox where client_id = cid and created_at > now() - interval '10 minutes';
  if not found or r.kind not in ('payment', 'cancel') or r.card_id is null then return null; end if;
  select * into pay from gagyebu.payments where source_ref = 'inbox:' || r.id;
  t := coalesce(r.approved_at, r.posted_at, now()) at time zone 'Asia/Seoul';
  k := gagyebu.norm_merchant(r.merchant);
  -- 오늘 같은 가게에서 몇 번째인지 (이번 결제 포함)
  select count(*) into same from gagyebu.payments x
  where not x.hidden and x.amount > 0 and k <> ''
    and (x.paid_at at time zone 'Asia/Seoul')::date = t::date
    and (position(k in gagyebu.norm_merchant(x.merchant)) > 0 or position(gagyebu.norm_merchant(x.merchant) in k) > 0);
  s := gagyebu.card_month(r.card_id, gagyebu.bill_month_of(r.card_id, t::date));
  return s || jsonb_build_object('kind', r.kind, 'amount', r.amount, 'merchant', r.merchant,
    'months', coalesce(r.months, 1), 'reimbursed', coalesce(pay.reimbursed, false),
    'pay_id', pay.id, 'same_today', same, 'hour', extract(hour from t)::int,
    'via_spay', coalesce(r.via_spay, false));
end;
$$;
revoke all on function gagyebu.flash(text) from public;
grant execute on function gagyebu.flash(text) to anon, authenticated;

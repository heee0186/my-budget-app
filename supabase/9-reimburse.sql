-- 9. 돌려받는 결제 + 마통 진행률
--   내 카드로 냈지만 가족 등이 현금으로 돌려주는 결제를 표시해요.
--   카드 청구액은 그대로, 예산은 '내 실제 지출'(돌려받는 결제 뺀 금액) 기준.
--   기존 행은 바꾸지 않아요: 새 칸은 기본값(false / null)으로만 추가돼요.

-- 1) 결제에 표시 칸
alter table gagyebu.payments add column if not exists reimbursed boolean not null default false;
alter table gagyebu.payments add column if not exists reimbursed_by text;

-- 2) "같은 가게, 같은 금액이면 앞으로도 돌려받음" 규칙
create table if not exists gagyebu.reimburse_rules (
  id bigserial primary key,
  card_id text not null references gagyebu.cards(id),
  merchant_key text not null,          -- 정리한 가게 이름 (공백·(주)·주식회사 뺌, 소문자)
  amount integer not null,
  reimbursed_by text,
  created_at timestamptz not null default now(),
  unique (card_id, merchant_key, amount)
);
alter table gagyebu.reimburse_rules enable row level security;
drop policy if exists "owner all" on gagyebu.reimburse_rules;
create policy "owner all" on gagyebu.reimburse_rules for all to authenticated
  using (gagyebu.is_owner()) with check (gagyebu.is_owner());
revoke all on gagyebu.reimburse_rules from anon, authenticated;
grant select, insert, update, delete on gagyebu.reimburse_rules to authenticated;
grant usage, select on sequence gagyebu.reimburse_rules_id_seq to authenticated;

create or replace function gagyebu.norm_merchant(t text)
returns text language sql immutable as $$
  select lower(regexp_replace(coalesce(t, ''), '\s|\(주\)|주식회사|㈜|_|-|취소', '', 'g'));
$$;

-- 3) 새 결제가 들어올 때 규칙에 맞으면 자동으로 돌려받음 표시
create or replace function gagyebu.payments_reimburse()
returns trigger language plpgsql security definer set search_path = gagyebu, public as $$
declare r gagyebu.reimburse_rules; k text := gagyebu.norm_merchant(new.merchant);
begin
  if new.reimbursed or k = '' then return new; end if;
  select * into r from gagyebu.reimburse_rules x
  where x.card_id = new.card_id and x.amount = new.amount
    and (position(x.merchant_key in k) > 0 or position(k in x.merchant_key) > 0)
  limit 1;
  if found then new.reimbursed := true; new.reimbursed_by := r.reimbursed_by; end if;
  return new;
end;
$$;
drop trigger if exists payments_reimburse on gagyebu.payments;
create trigger payments_reimburse before insert on gagyebu.payments
  for each row execute function gagyebu.payments_reimburse();

-- 4) 마통 진행률: 처음 잔액 (0원까지 얼마나 갚았는지)
alter table gagyebu.loans add column if not exists start_balance integer;
update gagyebu.loans set start_balance = balance where start_balance is null;

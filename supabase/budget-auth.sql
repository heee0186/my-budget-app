-- =====================================================================
-- 가계부 잠금 (my_budget_table, sms_inbox)
-- Supabase 대시보드 → SQL Editor 에 통째로 붙여넣고, 아래 [바꿀 곳] 한 군데만
-- 내 로그인 이메일로 바꾼 뒤 Run.
--
-- 실행 전에 꼭:
--   1) 로그인 기능이 들어간 가계부가 먼저 배포돼 있어야 해요.
--      (이 SQL을 먼저 실행하면 옛 가계부는 아무것도 못 읽어요)
--   2) Authentication → Users 에 내 계정이 있어야 해요.
--
-- 결과:
--   - 가계부 자료와 결제 알림은 "가계부 주인"으로 등록된 계정만 읽고 쓸 수 있어요.
--     같은 Supabase를 쓰는 다른 앱 계정이나 여행 정산의 익명 방문자는 못 봐요.
--   - 알림 수집기 앱(anon 키)은 결제 알림을 "넣기"만 할 수 있고 읽거나 지울 수 없어요.
--   - 여러 번 실행해도 안전해요.
-- =====================================================================

-- 1) 가계부 주인 목록 (API로는 읽기/쓰기 불가)
create table if not exists public.budget_owners (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.budget_owners enable row level security;
revoke all on public.budget_owners from anon, authenticated;

-- 2) 지금 로그인한 사람이 주인인지 확인하는 함수
create or replace function public.is_budget_owner()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.budget_owners where user_id = auth.uid());
$$;
revoke all on function public.is_budget_owner() from public, anon;
grant execute on function public.is_budget_owner() to authenticated;

-- 3) 주인 등록  ───────────── [바꿀 곳] 따옴표 안을 내 로그인 이메일로 ─────────────
insert into public.budget_owners (user_id)
select id from auth.users where lower(email) = lower('여기에_내_로그인_이메일')
on conflict do nothing;

-- 4) 두 테이블의 기존 정책을 모두 지우고 새로 만듦
do $$
declare p record;
begin
  for p in
    select policyname, tablename from pg_policies
    where schemaname = 'public' and tablename in ('my_budget_table', 'sms_inbox')
  loop
    execute format('drop policy %I on public.%I', p.policyname, p.tablename);
  end loop;
end $$;

-- 가계부: 주인만 전부 가능
alter table public.my_budget_table enable row level security;
revoke all on public.my_budget_table from anon;
grant select, insert, update, delete on public.my_budget_table to authenticated;
create policy "budget owner only" on public.my_budget_table
  for all to authenticated
  using (public.is_budget_owner())
  with check (public.is_budget_owner());

-- 결제 알림 우체통: 수집기는 넣기만, 주인은 읽기·지우기
-- (anon의 select 권한은 남겨두되 읽기 정책이 없어서 항상 빈 결과.
--  수집기 앱의 "서버 연결 테스트"가 오류 대신 정상으로 나오게 하려는 것)
alter table public.sms_inbox enable row level security;
revoke all on public.sms_inbox from anon, authenticated;
grant select, insert on public.sms_inbox to anon;
grant select, delete on public.sms_inbox to authenticated;
create policy "collector insert" on public.sms_inbox
  for insert to anon
  with check (true);
create policy "owner read" on public.sms_inbox
  for select to authenticated
  using (public.is_budget_owner());
create policy "owner delete" on public.sms_inbox
  for delete to authenticated
  using (public.is_budget_owner());

-- 5) 확인: owners 가 1 이상이어야 해요. 0이면 3번의 이메일이 계정과 다른 거예요.
select
  (select count(*) from public.budget_owners) as owners,
  (select string_agg(u.email, ', ') from public.budget_owners o join auth.users u on u.id = o.user_id) as owner_emails;

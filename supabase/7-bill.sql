-- =====================================================================
-- 카드사 "결제예정금액" 알림 자동 읽기 (프로젝트 2 · 5-merchant.sql 다음에 Run)
--   예: [농협] "11/18 결제예정금액 557,824원 (11/05기준)"
--   → gagyebu.inbox 에 kind = 'bill', card_id, amount, bill_month 로 저장
--   → 가계부의 이번 결제·옮길 돈이 이 실제 금액을 써요. 손으로 옮겨 적을 필요 없어요.
-- 여러 번 실행해도 안전해요. 이미 받은 알림도 다시 읽어요.
-- =====================================================================

alter table gagyebu.inbox add column if not exists bill_month integer;

create or replace function gagyebu.parse_inbox(r gagyebu.inbox)
returns gagyebu.inbox language plpgsql stable as $$
declare
  body   text := replace(coalesce(nullif(r.big_text, ''), nullif(r.text, ''), ''), E'\r', E'\n');
  ln     text;
  cand   text;
  bd     int[];
  pm     int;
  posted timestamp := coalesce(r.posted_at, r.created_at, now()) at time zone 'Asia/Seoul';
  m text[]; head text; rest text; yy int; mo int;
begin
  r.kind := null; r.card_id := null; r.amount := null; r.merchant := null;
  r.months := null; r.approved_at := r.posted_at; r.note := null;

  if r.source = 'kakao' and coalesce(r.title, '') ~* '택사스|taxas' then
    r.kind := case when body ~ '급여' then 'payslip' else 'ignored' end;
    return r;
  end if;

  -- 카드사 청구 금액 안내: "11/18 결제예정금액 557,824원" 같은 알림 → 실제 청구액 (kind = bill)
  r.bill_month := null;
  if r.source in ('nhpay', 'kakao', 'toss')
     and body ~ '결제\s*예정\s*금액|청구\s*금액|결제하실\s*금액|이번\s*달\s*결제\s*금액'
     and body !~ '정상\s*납부|납부\s*되었|결제\s*되었' then
    m := regexp_match(body, '([0-9][0-9,]{2,})\s*원');
    if m is not null then
      r.kind := 'bill';
      r.amount := replace(m[1], ',', '')::int;
      r.card_id := case
        when r.source = 'nhpay' or body ~ 'NH|농협' then 'nh'
        when body ~ '삼성' or coalesce(r.title, '') ~ '삼성' then 'samsung'
        when body ~ '롯데' or coalesce(r.title, '') ~ '롯데' then 'lotte' end;
      -- 청구월: 본문의 "11/18" 같은 결제일 → 그 달. 없으면 알림 받은 달 (결제일이 지났으면 다음 달)
      m := regexp_match(body, '([0-9]{1,2})/([0-9]{1,2})\s*(결제|일)');
      if m is null then m := regexp_match(body, '([0-9]{1,2})월\s*([0-9]{1,2})일'); end if;
      if m is not null then
        pm := m[1]::int;
        r.bill_month := (extract(year from posted)::int + case when pm < extract(month from posted) - 6 then 1 else 0 end) * 100 + pm;
      else
        r.bill_month := extract(year from posted)::int * 100 + extract(month from posted)::int;
      end if;
      if r.card_id is null then r.kind := 'ignored'; r.note := '카드를 알 수 없는 청구 안내'; end if;
      return r;
    end if;
  end if;

  if r.source = 'toss' then
    m := regexp_match(coalesce(r.title, ''), '^\s*([0-9][0-9,]*)\s*원\s*(.*)$');
    if m is null or m[2] !~ '결제|취소' then r.kind := 'ignored'; return r; end if;
    r.amount := replace(m[1], ',', '')::int;
    r.kind := case when m[2] ~ '취소' then 'cancel' else 'payment' end;
    if position('|' in body) > 0 then
      head := btrim(split_part(body, '|', 1));
      rest := btrim(substr(body, position('|' in body) + 1));
    else
      head := body; rest := '';
    end if;
    m := regexp_match(rest, '\(([^()]*)\)\s*$');
    if m is not null and m[1] ~ '일시불|개월|할부' then
      r.months := coalesce(substring(m[1] from '([0-9]+)\s*개월')::int, 1);
      rest := btrim(regexp_replace(rest, '\([^()]*\)\s*$', ''));
    end if;
    r.merchant := nullif(rest, '');
    r.card_id := case when head ~ '롯데' then 'lotte' when head ~ '삼성' then 'samsung' when head ~ 'NH|농협' then 'nh' end;
    if r.card_id is null then r.kind := 'review'; r.note := '토스 결제지만 등록된 카드가 아님: ' || head; end if;
    return r;
  end if;

  if (r.source = 'kakao' and coalesce(r.title, '') ~ '삼성카드') or r.source = 'nhpay' then
    m := regexp_match(body, '(승인취소|취소|승인)');
    if m is null then r.kind := 'ignored'; return r; end if;
    r.kind := case when m[1] ~ '취소' then 'cancel' else 'payment' end;
    r.card_id := case when r.source = 'nhpay' then 'nh' else 'samsung' end;
    m := regexp_match(body, '([0-9]{1,2})/([0-9]{1,2})\s+([0-9]{1,2}):([0-9]{2})[ \t]*\n?[ \t]*([^\n]*)');
    if m is not null then
      mo := m[1]::int;
      yy := extract(year from posted)::int;
      if mo = 12 and extract(month from posted) = 1 then yy := yy - 1; end if;
      begin
        r.approved_at := make_timestamp(yy, mo, m[2]::int, m[3]::int, m[4]::int, 0) at time zone 'Asia/Seoul';
      exception when others then r.approved_at := r.posted_at;
      end;
      r.merchant := nullif(btrim(regexp_replace(m[5], '\s*누적.*$', ''), E' \t\n'), '');
    end if;
    -- 가맹점을 못 찾았으면: 카드번호·이름·금액·날짜·누적 줄을 빼고 남는 줄 중 마지막
    if r.merchant is null then
      cand := null;
      foreach ln in array regexp_split_to_array(body, E'\n+') loop
        ln := btrim(ln, E' \t');
        continue when ln = ''
          or ln ~ '(승인|취소)'
          or ln ~ '^[가-힣A-Za-z]\*[가-힣A-Za-z]{1,2}님?$'
          or ln ~ '[0-9][0-9,]*\s*원'
          or ln ~ '^[0-9]{1,2}/[0-9]{1,2}(\s+[0-9]{1,2}:[0-9]{2})?$'
          or ln ~ '누적|잔액|한도'
          or ln ~* '^(NH|농협|삼성)[가-힣 ]*카드$';
        cand := ln;
      end loop;
      r.merchant := cand;
    end if;
    rest := regexp_replace(body, '(누적|잔액|한도)[^\n]*', '', 'g');
    m := regexp_match(rest, '([0-9][0-9,]*)\s*원\s*(일시불|([0-9]+)\s*개월|할부)?');
    if m is null then
      r.kind := 'review';
      r.note := case when rest ~* '\$|USD|EUR|JPY|CNY|달러|외화' then '외화 결제 (원화 금액 없음)' else '금액을 찾지 못함' end;
      return r;
    end if;
    r.amount := replace(m[1], ',', '')::int;
    r.months := coalesce(m[3]::int, 1);
    return r;
  end if;

  r.kind := 'ignored';
  return r;
end;
$$;



-- 다시 해석할 때 bill_month 도 저장
create or replace function gagyebu.reparse_inbox()
returns integer language plpgsql security definer set search_path = gagyebu, public as $$
declare r gagyebu.inbox; n integer := 0;
begin
  if not gagyebu.is_owner() and current_user not in ('postgres', 'supabase_admin') then raise exception 'not allowed'; end if;
  for r in select * from gagyebu.inbox where kind is distinct from 'dismissed' and kind is distinct from 'resolved' and source is distinct from 'manual' loop
    r := gagyebu.parse_inbox(r);
    update gagyebu.inbox set kind = r.kind, card_id = r.card_id, amount = r.amount, merchant = r.merchant,
      months = r.months, approved_at = r.approved_at, note = r.note, bill_month = r.bill_month where id = r.id;
    perform gagyebu.inbox_to_payment(r);
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke all on function gagyebu.reparse_inbox() from public, anon;

select gagyebu.reparse_inbox();

-- 확인: 읽힌 청구 금액
select card_id, bill_month, amount, to_char(created_at at time zone 'Asia/Seoul', 'MM/DD HH24:MI') as received
from gagyebu.inbox where kind = 'bill' order by id desc;

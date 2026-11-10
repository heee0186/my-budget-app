-- =====================================================================
-- 가맹점 이름 해석 보강 (프로젝트 2 · 3-collector.sql 다음에 Run, 여러 번 실행해도 안전)
--   NH pay·삼성카드 알림에서 가맹점이 비던 문제:
--   줄바꿈이 \r\n 이거나 순서가 달라도, 카드번호·이름·금액·날짜 줄을 빼고 남는 줄을 가맹점으로 봐요.
--   이미 들어온 알림도 다시 해석해서, 비어 있던 가맹점을 채워요.
-- =====================================================================

create or replace function gagyebu.parse_inbox(r gagyebu.inbox)
returns gagyebu.inbox language plpgsql stable as $$
declare
  body   text := replace(coalesce(nullif(r.big_text, ''), nullif(r.text, ''), ''), E'\r', E'\n');
  ln     text;
  cand   text;
  posted timestamp := coalesce(r.posted_at, r.created_at, now()) at time zone 'Asia/Seoul';
  m text[]; head text; rest text; yy int; mo int;
begin
  r.kind := null; r.card_id := null; r.amount := null; r.merchant := null;
  r.months := null; r.approved_at := r.posted_at; r.note := null;

  if r.source = 'kakao' and coalesce(r.title, '') ~* '택사스|taxas' then
    r.kind := case when body ~ '급여' then 'payslip' else 'ignored' end;
    return r;
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


-- 다시 해석할 때 이미 있는 결제의 빈 가맹점·할부도 채워요
create or replace function gagyebu.inbox_to_payment(n gagyebu.inbox)
returns void language plpgsql security definer set search_path = gagyebu, public as $$
begin
  if n.kind not in ('payment', 'cancel') or n.card_id is null or n.amount is null then return; end if;
  insert into gagyebu.payments (card_id, paid_at, amount, merchant, months, source, source_ref)
  values (n.card_id, coalesce(n.approved_at, n.posted_at, n.created_at),
          case when n.kind = 'cancel' then -abs(n.amount) else abs(n.amount) end,
          n.merchant, coalesce(n.months, 1), 'notification', 'inbox:' || n.id)
  on conflict (source_ref) do update set merchant = case
    when nullif(btrim(coalesce(gagyebu.payments.merchant, ''), E' \t\r\n'), '') is null then excluded.merchant
    else gagyebu.payments.merchant end;
end;
$$;
revoke all on function gagyebu.inbox_to_payment(gagyebu.inbox) from public, anon, authenticated;

select gagyebu.reparse_inbox();

-- 확인: 최근 알림 해석 결과
select id, source, kind, card_id, amount, merchant, approved_at at time zone 'Asia/Seoul' as at,
       replace(coalesce(nullif(big_text, ''), text), E'\n', ' / ') as body
from gagyebu.inbox order by id desc limit 10;

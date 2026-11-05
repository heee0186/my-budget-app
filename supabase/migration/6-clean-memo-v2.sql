-- =====================================================================
-- 예전 메모 정리 v2 (프로젝트 2 에서 실행. 5번을 실행했든 안 했든 상관없어요)
--
-- 5번이 놓친 형식까지 정리해요.
--   "KCP-결제 보조: 수신시각: - - : :"               → "KCP-결제"
--   "앱: 패키지: 제목: 내용: * * / : 홍주유소 상세: …" → "홍주유소"
-- 결제가 아닌 청구 안내 알림("결제예정금액" 등)이 거래로 잘못 들어간 줄은 숨겨요.
--   (지출 합계에서 빠지고, 지우지 않으니 되돌릴 수 있어요)
--
-- 고치기 전 메모는 memo_original 에 남아 있어서 항상 원본에서 다시 정리해요.
-- 여러 번 실행해도 안전해요.
-- =====================================================================

alter table money.tx add column if not exists memo_original text;

-- 한 조각(내용·상세 등)에서 가맹점 이름만 남김
create or replace function money.clean_memo_part(s text)
returns text language plpgsql immutable as $$
declare
  t text := coalesce(s, '');
  m text[];
begin
  t := regexp_replace(t, '[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+){2,}', ' ', 'g');   -- 패키지 이름
  -- 토스: "롯데카드 | 가맹점(일시불)" → 막대 뒤가 가맹점
  if position('|' in t) > 0 then
    t := substr(t, length(t) - position('|' in reverse(t)) + 2);
  end if;
  -- 삼성·NH: "11/03 11:44 가맹점" → 시각 뒤가 가맹점
  m := regexp_match(t, '[0-9]{1,2}/[0-9]{1,2}\s+[0-9]{1,2}:[0-9]{2}\s+(.+)$');
  if m is not null then t := m[1]; end if;
  t := regexp_replace(t, '\((일시불|[0-9]+\s*개월[^)]*|할부[^)]*)\)', ' ', 'g');
  t := regexp_replace(t, '(삼성|NH|롯데|농협)?[가-힣A-Za-z]*카드[0-9*]*', ' ', 'g');
  t := regexp_replace(t, '(삼성|NH|롯데)[0-9*]{3,}', ' ', 'g');
  t := regexp_replace(t, '[가-힣]\*[가-힣]님?', ' ', 'g');
  t := regexp_replace(t, '(누적|잔액)\s*[0-9][0-9,]*\s*원?', ' ', 'g');
  t := regexp_replace(t, '[₩￦]?\s*[0-9][0-9,]*\s*원', ' ', 'g');
  t := regexp_replace(t, '(20[0-9]{2}[-./])?[0-9]{1,2}[/.-][0-9]{1,2}(\s+[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?)?', ' ', 'g');
  t := regexp_replace(t, '[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?', ' ', 'g');
  t := regexp_replace(t, '(승인취소|결제취소|결제 완료|승인|일시불|Web발신|자동 등록 내역|알림정리|NH ?pay|\[|\]|\|)', ' ', 'gi');
  -- 글자·숫자가 하나도 없는 조각(*, /, :, - 등)과 안내 단어 제거
  t := array_to_string(array(
         select w from regexp_split_to_table(t, '\s+') with ordinality as x(w, i)
         where w ~ '[0-9A-Za-z가-힣]'
           and w !~ '^(결제|토스|체크|해외|국내|사용|이용|알림|원)$'
         order by i), ' ');
  return nullif(btrim(t), '');
end;
$$;

-- 메모 전체: 꼬리표(앱:, 내용:, [제목:...] 등)로 나눠서 쓸 만한 조각을 고름
create or replace function money.clean_memo(s text)
returns text language plpgsql immutable as $$
declare
  t text := replace(replace(coalesce(s, ''), '[', ' '), ']', ' ');
  part text;
  label text;
  val text;
  cleaned text;
  pick_order text[] := array['', '내용', '상세', '보조'];
  vals jsonb := '{}'::jsonb;
  k text;
begin
  if t !~ '(앱|패키지|제목|내용|상세|보조|수신시각)\s*:' then
    return money.clean_memo_part(t);
  end if;
  t := regexp_replace(t, '(앱|패키지|제목|내용|상세|보조|수신시각)\s*:', chr(1) || '\1' || chr(2), 'g');
  foreach part in array string_to_array(t, chr(1)) loop
    if position(chr(2) in part) > 0 then
      label := split_part(part, chr(2), 1);
      val := split_part(part, chr(2), 2);
    else
      label := ''; val := part;
    end if;
    vals := vals || jsonb_build_object(label, coalesce(vals->>label, '') || ' ' || val);
  end loop;
  foreach k in array pick_order loop
    cleaned := money.clean_memo_part(vals->>k);
    if cleaned is not null then return cleaned; end if;
  end loop;
  return null;
end;
$$;

create or replace function money.memo_is_messy(s text)
returns boolean language sql immutable as $$
  select coalesce(s, '') ~ '(앱|패키지|제목|내용|상세|보조|수신시각)\s*:|\||[A-Za-z]+\.[A-Za-z]+\.[A-Za-z]+|승인|일시불|[가-힣]\*[가-힣]|[0-9]{1,2}:[0-9]{2}|Web발신|자동 등록 내역|(삼성|NH|롯데)[0-9*]{3,}|(^|\s)[*/:-]+(\s|$)'
$$;

-- 결제가 아니라 청구·안내 알림이었던 줄
create or replace function money.memo_is_notice(s text)
returns boolean language sql immutable as $$
  select coalesce(s, '') ~ '결제\s*예정\s*금액|결제예정|청구\s*금액|이용\s*대금|명세서|결제일\s*안내|출금\s*예정'
$$;

-- 1) 미리보기 (이 부분만 먼저 Run 해서 확인해도 돼요)
select id, card, amount, (used_at at time zone 'Asia/Seoul')::date as day,
       coalesce(memo_original, memo) as original,
       case when money.memo_is_notice(coalesce(memo_original, memo)) then '→ 숨김 (청구 안내 알림)'
            else coalesce(money.clean_memo(coalesce(memo_original, memo)), '(비움)') end as after
from money.tx
where source <> 'manual'
  and (money.memo_is_messy(coalesce(memo_original, memo)) or money.memo_is_notice(coalesce(memo_original, memo)))
order by used_at desc;

-- 2) 적용
update money.tx
set memo_original = coalesce(memo_original, memo),
    memo = money.clean_memo(coalesce(memo_original, memo))
where source <> 'manual' and money.memo_is_messy(coalesce(memo_original, memo));

update money.tx
set hidden = true
where source <> 'manual' and not hidden and money.memo_is_notice(coalesce(memo_original, memo));

-- 되돌리기
--   메모:  update money.tx set memo = memo_original where memo_original is not null;
--   숨김:  update money.tx set hidden = false where money.memo_is_notice(coalesce(memo_original, memo));

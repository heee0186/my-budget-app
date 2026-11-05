-- =====================================================================
-- 예전 기록의 지저분한 메모 정리 (프로젝트 2 에서 실행, 4-bill-month.sql 다음)
--   예: "[앱:토스] [패키지:viva.republica.toss] [제목:19,000원 결제] [내용:롯데카드 | 네이버페이(일시불)]"
--       → "네이버페이"
--   예: "삼성0243 김*권 85,668원 일시불 11/03 11:44 Aliexpress" → "Aliexpress"
--
-- 안전장치
--   - 직접 쓴 메모(떡볶이 같은)는 손대지 않고, 기계가 만든 흔적이 있는 메모만 고쳐요.
--   - 고치기 전 메모는 memo_original 칸에 남겨요. 되돌리기는 맨 아래 참고.
--   - 여러 번 실행해도 안전해요.
-- =====================================================================

alter table money.tx add column if not exists memo_original text;

create or replace function money.clean_memo(s text)
returns text language plpgsql immutable as $$
declare
  t text := coalesce(s, '');
  m text[];
begin
  -- 수집기 꼬리표: 쓸모없는 칸은 지우고, 제목·내용·상세는 내용만 남김
  t := regexp_replace(t, '\[(앱|패키지|수신시각|보조):[^\]]*\]?', ' ', 'g');
  t := regexp_replace(t, '\[(제목|내용|상세):([^\]]*)\]?', ' \2 ', 'g');
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
  t := regexp_replace(t, '(^|\s)(결제|토스|체크|해외|국내|사용|이용|알림)(?=\s|$)', ' ', 'g');
  t := btrim(regexp_replace(t, '\s+', ' ', 'g'));
  return nullif(t, '');
end;
$$;

-- 기계가 만든 메모인지 판별
create or replace function money.memo_is_messy(s text)
returns boolean language sql immutable as $$
  select coalesce(s, '') ~ '\[(앱|패키지|제목|내용|상세|보조|수신시각):|\||[A-Za-z]+\.[A-Za-z]+\.[A-Za-z]+|승인|일시불|[가-힣]\*[가-힣]|[0-9]{1,2}:[0-9]{2}|Web발신|자동 등록 내역|(삼성|NH|롯데)[0-9*]{3,}'
$$;

-- 1) 미리보기: 무엇이 어떻게 바뀌는지 (실행 전에 확인하고 싶으면 이 부분만 Run)
select id, card, amount, (used_at at time zone 'Asia/Seoul')::date as day,
       memo as before, coalesce(money.clean_memo(memo), '(비움)') as after
from money.tx
where source <> 'manual' and money.memo_is_messy(memo)
order by used_at desc;

-- 2) 적용
update money.tx
set memo_original = coalesce(memo_original, memo),
    memo = money.clean_memo(memo)
where source <> 'manual' and money.memo_is_messy(memo);

-- 되돌리기가 필요하면:
-- update money.tx set memo = memo_original where memo_original is not null;

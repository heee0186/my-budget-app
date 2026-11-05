-- =====================================================================
-- 결제가 아닌 안내 알림이 거래로 들어간 줄 숨기기 (프로젝트 2, 6번 다음)
--   예: "카드대금 정상 납부 되었습니다", "결제예정금액", 자동이체·포인트·이벤트 안내
-- 지우지 않고 hidden 만 켜요 → 지출 합계에서 빠지고, 되돌릴 수 있어요.
-- 직접 쓴 기록(manual)과 현금·이체 기록은 건드리지 않아요. 여러 번 실행해도 안전해요.
-- (새 수집 방식은 "승인/취소"가 없는 알림을 처음부터 거래로 만들지 않아요)
-- =====================================================================

create or replace function money.memo_is_notice(s text)
returns boolean language sql immutable as $$
  select coalesce(s, '') ~ '대금|납부|결제\s*예정|결제예정|청구|명세서|결제일|출금|입금|자동이체|이체|한도|포인트|적립|캐시백|혜택|이벤트|안내|연체|리볼빙|선결제|분할납부|현금서비스|카드론'
$$;

-- 1) 미리보기: 숨겨질 줄 (가맹점 이름에 저 단어가 들어간 진짜 결제가 있으면 알려주세요)
select id, card, amount, (used_at at time zone 'Asia/Seoul')::date as day,
       coalesce(memo_original, memo) as original
from money.tx
where source <> 'manual' and card <> '현금' and not hidden
  and money.memo_is_notice(coalesce(memo_original, memo))
order by used_at desc;

-- 2) 적용
update money.tx
set hidden = true
where source <> 'manual' and card <> '현금' and not hidden
  and money.memo_is_notice(coalesce(memo_original, memo));

-- 되돌리기 (특정 줄만): update money.tx set hidden = false where id = 번호;

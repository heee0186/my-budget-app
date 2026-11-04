-- =====================================================================
-- [지금 쓰는 옛 프로젝트]에서 실행
-- 가계부·결제 알림·타오바오 자료를 새 프로젝트에 넣을 SQL로 만들어 줘요.
-- 옛 프로젝트의 자료는 건드리지 않아요 (읽기만 함).
--
-- 실행 방법
--   1) 옛 프로젝트 SQL Editor 에 통째로 붙여넣고 Run
--   2) 결과에 나온 import_sql 칸의 글자를 통째로 복사
--      (칸을 클릭하면 오른쪽에 내용이 열려요. 거기서 전체 선택 → 복사)
--   3) 프로젝트 2(예절퀘스트 프로젝트) SQL Editor 에 붙여넣고 Run
--   4) 마지막에 나오는 개수가 아래 rows_* 숫자와 같으면 끝
-- =====================================================================

select
  (select count(*) from public.my_budget_table) as rows_budget,
  (select count(*) from public.sms_inbox)        as rows_inbox,
  (select count(*) from public.tb_docs)          as rows_taobao,
  concat_ws(E'\n',
    '-- 옛 프로젝트에서 ' || to_char(now() at time zone 'Asia/Seoul', 'YYYY-MM-DD HH24:MI') || ' 에 내보낸 자료',
    'begin;',
    (select string_agg(format(
        'insert into money.my_budget_table select * from jsonb_populate_record(null::money.my_budget_table, %L::jsonb) on conflict (id) do update set content = excluded.content;',
        to_jsonb(t)), E'\n' order by t.id)
     from public.my_budget_table t),
    (select string_agg(format(
        'insert into money.sms_inbox select * from jsonb_populate_record(null::money.sms_inbox, %L::jsonb) on conflict (id) do nothing;',
        to_jsonb(t)), E'\n' order by t.id)
     from public.sms_inbox t),
    (select string_agg(format(
        'insert into money.tb_docs select * from jsonb_populate_record(null::money.tb_docs, %L::jsonb) on conflict (id) do update set body = excluded.body, updated_at = excluded.updated_at;',
        to_jsonb(t)), E'\n' order by t.id)
     from public.tb_docs t),
    -- 결제 알림 번호가 겹치지 않도록 다음 번호를 맞춤
    'select setval(pg_get_serial_sequence(''money.sms_inbox'', ''id''), greatest((select coalesce(max(id), 0) from money.sms_inbox), 1), (select count(*) > 0 from money.sms_inbox));',
    'commit;',
    'select (select count(*) from money.my_budget_table) as rows_budget, (select count(*) from money.sms_inbox) as rows_inbox, (select count(*) from money.tb_docs) as rows_taobao;'
  ) as import_sql;

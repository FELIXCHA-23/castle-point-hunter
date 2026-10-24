-- Supabase > SQL Editor 에 붙여넣고 Run 한 번만 실행하세요.
create table if not exists public.castle_kv (
  key text primary key,
  value text not null
);
-- 학생 브라우저가 직접 읽지 못하게 막습니다 (서버의 service_role 키만 접근).
alter table public.castle_kv enable row level security;
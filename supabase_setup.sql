-- 캐슬 포인트 헌터 — Supabase 설정 (SQL Editor 에 통째로 붙여넣고 Run 한 번만 실행)
-- 모든 표와 내부 함수는 외부에 공개되지 않는 castle 스키마에 있고,
-- 화면이 부를 수 있는 함수는 public.castle_api 하나뿐입니다.
-- 정답·비밀번호는 이 함수를 거치지 않고는 읽을 수 없습니다.

create extension if not exists pgcrypto with schema extensions;
create schema if not exists castle;

-- ---------- 표 ----------
create table if not exists castle.cfg (id int primary key check (id = 1), data jsonb not null default '{}');
insert into castle.cfg values (1, '{}') on conflict do nothing;
create table if not exists castle.admin (id int primary key check (id = 1), hash text not null);
create table if not exists castle.students (
  id text primary key, name text not null, points int not null default 0,
  must_change boolean not null default true, pw_hash text not null,
  done text[] not null default '{}', created_at timestamptz not null default now());
create table if not exists castle.problems (
  id text primary key, grade text not null, text text not null, answer text not null,
  image text not null default '', explanation text not null default '', extra text not null default '',
  active boolean not null default true, created_at timestamptz not null default now());
-- 관리용 분류 (학생 화면에는 보이지 않음)
alter table castle.problems add column if not exists term text not null default '';      -- 예: 2학기 기말
alter table castle.problems add column if not exists subject text not null default '';   -- 예: 공통수학2 (고등만)
alter table castle.problems add column if not exists unit_large text not null default ''; -- 대단원 (2022 개정)
alter table castle.problems add column if not exists unit text not null default '';       -- 중단원 (2022 개정)
alter table castle.problems add column if not exists src text not null default '';        -- 출처 (예: RPM 공통수학2 0312). 같은 출처로 다시 올리면 덮어씀
create unique index if not exists problems_src_uq on castle.problems (src) where src <> '';
alter table castle.students add column if not exists is_admin boolean not null default false;      -- 선생님 계정에 관리자 권한을 줄 때
alter table castle.students add column if not exists is_teacher boolean not null default false;  -- 선생님(담당 학생 현황을 볼 수 있음)
alter table castle.students add column if not exists title text not null default '';             -- 호칭: 선생님 / 원장님 / 관리자님 (비우면 '님')
alter table castle.students add column if not exists grade text not null default '';             -- 학생 학년: 중1 … 고3 (학년별 순위용)
alter table castle.problems add column if not exists book text not null default '';              -- 문제 출처 설명 (예: 미래엔 교과서 문제 변형). 나중에 분류할 때 써요
alter table castle.problems add column if not exists level int not null default 0;               -- 난이도 1하 2중하 3중 4상 5최상 (0=미정)
create table if not exists castle.roster (
  teacher text not null references castle.students(id) on delete cascade,
  student text not null references castle.students(id) on delete cascade,
  primary key (teacher, student));
create table if not exists castle.seasons (
  id serial primary key, name text not null, starts_at timestamptz not null, ends_at timestamptz not null,
  min_level int not null default 4, prize text not null default '', created_at timestamptz not null default now());
create table if not exists castle.reset_requests (
  id serial primary key, student text not null, created_at timestamptz not null default now(), done boolean not null default false);
alter table castle.students add column if not exists season_grades text[];   -- 시즌 랭킹전에서 고를 수 있는 학년 (예외). 비우면 본인 학년만
alter table castle.students add column if not exists last_seen timestamptz;   -- 마지막으로 앱을 연 시각 (관리자 화면에서 정렬용)
alter table castle.reset_requests enable row level security;
alter table castle.roster enable row level security;
alter table castle.seasons enable row level security;
alter table castle.problems add column if not exists expl_image text not null default '';  -- 해설을 그림(캡처)으로 올릴 때
create table if not exists castle.attempts (
  id bigserial primary key, sid text not null references castle.students(id) on delete cascade,
  pid text not null, grade text not null, state text not null,
  preview_at timestamptz not null default now(), start_at timestamptz, deadline timestamptz, day date,
  mult int, answer text, correct boolean, timeout boolean, end_at timestamptz, reward int not null default 0);
create index if not exists attempts_sid_idx on castle.attempts (sid, id desc);
alter table castle.attempts add column if not exists season_id int;                              -- 시즌 랭킹전에서 푼 시도
alter table castle.attempts add column if not exists score int not null default 0;               -- 시즌 점수
create table if not exists castle.log (
  id bigserial primary key, sid text not null, t timestamptz not null default now(),
  delta int not null, reason text not null, balance int not null);
create index if not exists log_sid_idx on castle.log (sid);
-- 학생별 오답노트: 푼 적 있는 문제만 담을 수 있고, 메모·분류 이름은 학생이 직접 정리한다
create table if not exists castle.notes (
  sid text not null references castle.students(id) on delete cascade, pid text not null,
  memo text not null default '', tag text not null default '', created_at timestamptz not null default now(),
  primary key (sid, pid));
alter table castle.notes enable row level security;
create table if not exists castle.sessions (token text primary key, id text not null, role text not null, exp timestamptz not null);
create table if not exists castle.tries (key text primary key, n int not null default 0, until_at timestamptz);

alter table castle.cfg enable row level security;
alter table castle.admin enable row level security;
alter table castle.students enable row level security;
alter table castle.problems enable row level security;
alter table castle.attempts enable row level security;
alter table castle.log enable row level security;
alter table castle.sessions enable row level security;
alter table castle.tries enable row level security;

-- ---------- 도우미 ----------
create or replace function castle.fail(code int, msg text) returns void language plpgsql as $$
begin raise exception '%', msg using errcode = 'PT' || code::text; end $$;

create or replace function castle.ms(t timestamptz) returns bigint language sql immutable as $$
  select (extract(epoch from t) * 1000)::bigint $$;

create or replace function castle.grades() returns text[] language sql immutable as $$
  select array['중1','중2','중3','고1','고2','고3'] $$;

-- 본인 학년과 그 위 학년만 풀 수 있음 (아래 학년 제외). 학년 미지정·선생님·관리자는 전체.
create or replace function castle.allowed_grades(st castle.students) returns text[] language sql immutable as $$
  select case when st.is_admin or st.is_teacher or not (st.grade = any (castle.grades())) then castle.grades()
    else (select array_agg(g order by o) from unnest(castle.grades()) with ordinality as t(g, o)
          where o >= array_position(castle.grades(), st.grade)) end $$;

-- 시즌 랭킹전: 점수는 학년 구분 없이 겨루되, 문제는 본인 학년 것만 나온다 (학년이 없는 계정은 전체)
create or replace function castle.season_grades(st castle.students) returns text[] language sql immutable as $$
  select case when coalesce(array_length(st.season_grades, 1), 0) > 0 then st.season_grades
              when st.grade = any (castle.grades()) then array[st.grade]
              else castle.grades() end $$;

create or replace function castle.cfg_all() returns jsonb language sql stable as $$
  select '{"START_POINTS":5000,"PREVIEW_COST":10,"PREVIEW_SEC":10,"ACCEPT_COST":100,"TIME_LIMIT_SEC":1800,"REWARD":500,"MORNING_FROM":7,"MORNING_TO":9,"DAILY_BONUS_COUNT":15}'::jsonb
         || coalesce((select data from castle.cfg where id = 1), '{}'::jsonb) $$;

-- 학년별로 학생에게 보일 단원 (관리자 "출제 단원" 탭). 설정이 없는 학년은 모든 문제가 나옵니다.
create or replace function castle.unit_ok(g text, subj text, ul text, u text) returns boolean language sql stable as $$
  select case when jsonb_typeof(castle.cfg_all() -> 'UNITS' -> g) is distinct from 'array' then true
              else (castle.cfg_all() -> 'UNITS' -> g) ? (subj || '|' || ul || '|' || u) end $$;

create or replace function castle.c(k text) returns int language sql stable as $$
  select (castle.cfg_all() ->> k)::int $$;

create or replace function castle.kst_today() returns date language sql stable as $$
  select (now() at time zone 'Asia/Seoul')::date $$;

create or replace function castle.norm(s text) returns text language plpgsql immutable as $$
declare t text := normalize(coalesce(s, ''), NFKC); u text;
begin
  -- 한글 초성(U+1100대)으로 입력된 ㄱㄴㄷ 도 호환 자모로 맞춘다
  u := translate(t, 'ᄀᄁᄂᄃᄄᄅᄆᄇᄈᄉᄊᄋᄌᄍᄎᄏᄐᄑᄒ', 'ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ');
  u := regexp_replace(u, '[\s,.·・/、;:]', '', 'g');
  if u ~ '^[ㄱ-ㅎ]+$' then
    return (select string_agg(c, '' order by c) from (select distinct regexp_split_to_table(u, '') as c) x);
  end if;
  return regexp_replace(regexp_replace(translate(t, '−–—‐', '----'), '[\s,]', '', 'g'), '^\+', '');
end $$;

create or replace function castle.same(a text, b text) returns boolean language plpgsql immutable as $$
declare na text := castle.norm(a); nb text := castle.norm(b);
begin
  if na ~ '^-?[0-9]+(\.[0-9]+)?$' and nb ~ '^-?[0-9]+(\.[0-9]+)?$' then
    return abs(na::numeric - nb::numeric) < 0.000000001;
  end if;
  return na = nb;
end $$;

create or replace function castle.add_pts(p_sid text, p_delta int, p_reason text) returns void language plpgsql as $$
declare v_bal int;
begin
  update castle.students set points = points + p_delta where id = p_sid returning points into v_bal;
  insert into castle.log (sid, delta, reason, balance) values (p_sid, p_delta, p_reason, v_bal);
  -- 풀이 포인트(100P)보다 모자라 문제를 못 풀게 되면 110P로 맞춰 줌
  if p_delta < 0 and v_bal < castle.c('ACCEPT_COST') then
    update castle.students set points = 110 where id = p_sid;
    insert into castle.log (sid, delta, reason, balance) values (p_sid, 110 - v_bal, '포인트 소진 자동 충전(110P)', 110);
  end if;
end $$;

create or replace function castle.today_count(p_sid text) returns int language sql stable as $$
  select count(*)::int from castle.attempts where sid = p_sid and day = castle.kst_today() and correct is true $$;  -- 오늘 맞힌 문제 수만 센다

-- 한국 공휴일(평일에 걸리는 날 + 대체공휴일). 해마다 새로 채워 넣어야 해요. 주말은 따로 계산해요.
create or replace function castle.is_holiday(p_day date) returns boolean language sql immutable as $$
  select p_day = any (array[
    -- 2026
    '2026-01-01', '2026-02-16', '2026-02-17', '2026-02-18', '2026-03-02', '2026-05-05', '2026-05-25', '2026-06-03',
    '2026-08-17', '2026-09-24', '2026-09-25', '2026-10-05', '2026-10-09', '2026-12-25',
    -- 2027
    '2027-01-01', '2027-02-08', '2027-02-09', '2027-03-01', '2027-05-05', '2027-05-13', '2027-06-07', '2027-08-16',
    '2027-09-14', '2027-09-15', '2027-09-16', '2027-10-04', '2027-10-11', '2027-12-27'
  ]::date[]) $$;

create or replace function castle.next_mult(p_sid text) returns jsonb language plpgsql stable as $$
declare h int := extract(hour from now() at time zone 'Asia/Seoul')::int; m boolean; d boolean;
        v_day date := (now() at time zone 'Asia/Seoul')::date;
begin
  -- 주말·공휴일 아침 시간대(기본 7~9시)에만 2배 이벤트
  m := h >= castle.c('MORNING_FROM') and h < castle.c('MORNING_TO')
       and (extract(dow from v_day) in (0, 6) or castle.is_holiday(v_day));
  d := castle.today_count(p_sid) >= castle.c('DAILY_BONUS_COUNT');  -- 오늘 맞힌 문제가 N개 이상이면 그 뒤부터 2배
  return jsonb_build_object('morning', m, 'daily', d, 'value', case when m or d then 2 else 1 end);
end $$;

create or replace function castle.auth(tok text, want text) returns text language plpgsql as $$
declare s castle.sessions;
begin
  select * into s from castle.sessions where token = tok and exp > now();
  if not found then perform castle.fail(401, '다시 로그인해 주십시오.'); end if;
  if want is not null and s.role <> want then perform castle.fail(403, '권한이 없습니다.'); end if;
  return s.id;
end $$;

-- 학생 로그인 확인 + 같은 학생의 동시 요청이 겹치지 않게 행을 잠급니다.
create or replace function castle.stu(tok text) returns castle.students language plpgsql as $$
declare v_id text := castle.auth(tok, 'student'); st castle.students;
begin
  select * into st from castle.students where id = v_id for update;
  if not found then perform castle.fail(401, '다시 로그인해 주십시오.'); end if;
  return st;
end $$;

create or replace function castle.finish(p_aid bigint, p_answer text, p_timeout boolean) returns void language plpgsql as $$
declare a castle.attempts; p castle.problems; ok boolean; rw int;
begin
  select * into a from castle.attempts where id = p_aid;
  select * into p from castle.problems where id = a.pid;
  ok := not p_timeout and p.id is not null and castle.same(p_answer, p.answer);
  if a.season_id is not null then  -- 시즌 랭킹전: 포인트 대신 점수(난이도×10)만 올라요
    update castle.attempts set state = 'done', answer = left(coalesce(p_answer, ''), 60), correct = ok,
           timeout = p_timeout, end_at = now(), reward = 0, score = case when ok then greatest(p.level, 1) * 10
                         when not p_timeout and btrim(coalesce(p_answer, '')) <> '' then -greatest(p.level, 1) * 5 else 0 end where id = a.id;  -- 오답을 제출하면 난이도×5점 감점, 시간 초과는 감점 없음
    return;
  end if;
  rw := case when ok then castle.c('REWARD') * a.mult else 0 end;
  update castle.attempts set state = 'done', answer = left(coalesce(p_answer, ''), 60), correct = ok,
         timeout = p_timeout, end_at = now(), reward = rw where id = a.id;
  update castle.students set done = case when a.pid = any(done) then done else array_append(done, a.pid) end where id = a.sid;
  if ok then
    perform castle.add_pts(a.sid, rw, '정답 보상 (+' || castle.c('REWARD') || case when a.mult > 1 then ' ×' || a.mult else '' end || ')');
  end if;
end $$;

-- 미리보기/풀이 시간이 지났으면 정리하고, 진행 중인 시도를 돌려줍니다 (없으면 id 가 null).
create or replace function castle.settle(p_sid text) returns castle.attempts language plpgsql as $$
declare a castle.attempts;
begin
  select * into a from castle.attempts where sid = p_sid and state in ('preview', 'solving') order by id desc limit 1;
  if not found then return a; end if;
  if a.state = 'preview' and now() > a.preview_at + make_interval(secs => (castle.c('PREVIEW_SEC') + 3)::double precision) then
    update castle.attempts set state = 'skipped', end_at = now() where id = a.id;
    a := null;
  elsif a.state = 'solving' and now() > a.deadline + interval '5 seconds' then
    perform castle.finish(a.id, '', true);
    a := null;
  end if;
  return a;
end $$;

create or replace function castle.active_view(a castle.attempts) returns jsonb language plpgsql stable as $$
declare p castle.problems;
begin
  if a.id is null then return null; end if;
  select * into p from castle.problems where id = a.pid;
  if not found then return null; end if;
  return jsonb_build_object('state', a.state,
    'problem', jsonb_build_object('id', p.id, 'grade', p.grade, 'text', p.text, 'image', p.image, 'kind', case when p.answer ~ '^[ㄱ-ㅎ]+$' then 'set' else 'num' end),
    'season', a.season_id is not null,
    'previewEndsAt', castle.ms(a.preview_at + make_interval(secs => castle.c('PREVIEW_SEC')::double precision)),
    'deadline', coalesce(castle.ms(a.deadline), 0));
end $$;

create or replace function castle.mask_name(n text) returns text language sql immutable as $$
  select case when length(n) <= 1 then n when length(n) = 2 then left(n, 1) || '*'
              else left(n, 1) || repeat('*', length(n) - 2) || right(n, 1) end $$;

create or replace function castle.upsert_problem(b jsonb) returns jsonb language plpgsql as $$
declare v_id text := nullif(b->>'id', ''); v_ans text := castle.norm(b->>'answer'); v_txt text := left(btrim(coalesce(b->>'text', '')), 4000);
        v_img text := coalesce(b->>'image', ''); v_eimg text := coalesce(b->>'expl_image', ''); v_src text := left(btrim(coalesce(b->>'src', '')), 200);
begin
  if not ((b->>'grade') = any (castle.grades())) then perform castle.fail(400, '학년이 올바르지 않습니다.'); end if;
  if v_txt = '' and v_img = '' then perform castle.fail(400, '문제 내용을 입력해 주십시오.'); end if;
  if v_ans !~ '^-?[0-9]+(\.[0-9]+)?$' and v_ans !~ '^[ㄱ-ㅎ]+$' then perform castle.fail(400, '정답은 숫자(예: 12, -3, 0.5) 또는 보기 기호(예: ㄱ, ㄷ)만 쓸 수 있습니다.'); end if;
  if v_img not in ('', '@keep') and (v_img !~ '^data:image/(jpeg|png|webp|gif);base64,[A-Za-z0-9+/=]+$' or length(v_img) > 600000) then
    perform castle.fail(400, '그림이 올바르지 않거나 너무 큽니다.');
  end if;
  if v_eimg not in ('', '@keep') and (v_eimg !~ '^data:image/(jpeg|png|webp|gif);base64,[A-Za-z0-9+/=]+$' or length(v_eimg) > 600000) then
    perform castle.fail(400, '해설 그림이 올바르지 않거나 너무 큽니다.');
  end if;
  if v_id is null and v_src <> '' then select id into v_id from castle.problems where src = v_src; end if;
  if v_id is null or not exists (select 1 from castle.problems where id = v_id) then
    v_id := encode(extensions.gen_random_bytes(5), 'hex');
    insert into castle.problems (id, grade, text, answer, image, expl_image, explanation, extra, active, term, subject, unit_large, unit, src, level, book)
    values (v_id, b->>'grade', v_txt, v_ans, case when v_img = '@keep' then '' else v_img end, case when v_eimg = '@keep' then '' else v_eimg end, left(coalesce(b->>'explanation', ''), 6000), left(coalesce(b->>'extra', ''), 6000),
            coalesce((b->>'active')::boolean, true), left(coalesce(b->>'term', ''), 40), left(coalesce(b->>'subject', ''), 40),
            left(coalesce(b->>'unit_large', ''), 60), left(coalesce(b->>'unit', ''), 60), v_src, least(greatest(coalesce((b->>'level')::int, 0), 0), 5), left(coalesce(b->>'book', ''), 200));
  else
    update castle.problems set grade = b->>'grade', text = v_txt, answer = v_ans,
           image = case when v_img = '@keep' then image else v_img end, expl_image = case when v_eimg = '@keep' then expl_image else v_eimg end,
           explanation = left(coalesce(b->>'explanation', ''), 6000), extra = left(coalesce(b->>'extra', ''), 6000),
           active = coalesce((b->>'active')::boolean, true),
           term = left(coalesce(b->>'term', term), 40), subject = left(coalesce(b->>'subject', subject), 40),
           unit_large = left(coalesce(b->>'unit_large', unit_large), 60), unit = left(coalesce(b->>'unit', unit), 60),
           src = case when b ? 'src' then v_src else src end,
           level = case when b ? 'level' then least(greatest(coalesce((b->>'level')::int, 0), 0), 5) else level end,
           book = case when b ? 'book' then left(coalesce(b->>'book', ''), 200) else book end where id = v_id;
  end if;
  return jsonb_build_object('id', v_id);
end $$;

-- ---------- 화면이 부르는 기능들 ----------
-- 로그인 실패는 오류로 던지지 않고 {"error":...} 로 돌려줍니다 (오류를 던지면 실패 횟수 기록이 취소되기 때문).
create or replace function castle.r_login(b jsonb) returns jsonb language plpgsql as $$
declare v_id text := regexp_replace(normalize(coalesce(b->>'id', ''), NFC), '\s', '', 'g');
        v_pw text := coalesce(b->>'pw', '');
        v_ip text := coalesce((nullif(current_setting('request.headers', true), '')::jsonb)->>'x-forwarded-for', '');
        v_key text; t castle.tries; v_adm boolean := lower(v_id) = 'admin'; v_hash text; v_must boolean := false; v_tok text; v_staff boolean := false; v_name text := ''; v_title text := '';
begin
  v_key := v_id || '|' || v_ip;
  select * into t from castle.tries where key = v_key;
  if found and t.until_at is not null and t.until_at > now() then
    return jsonb_build_object('error', '로그인 시도가 너무 많습니다. 5분 뒤에 다시 해 주십시오.');
  end if;
  if v_adm then select hash into v_hash from castle.admin where id = 1;
  else select pw_hash, must_change, is_admin, name, title into v_hash, v_must, v_staff, v_name, v_title from castle.students where id = v_id; end if;
  v_staff := coalesce(v_staff, false);
  if v_hash is null or v_hash <> extensions.crypt(v_pw, v_hash) then
    insert into castle.tries as x (key, n) values (v_key, 1)
      on conflict (key) do update set n = case when x.n + 1 >= 5 then 0 else x.n + 1 end,
                                      until_at = case when x.n + 1 >= 5 then now() + interval '5 minutes' else x.until_at end;
    return jsonb_build_object('error', '아이디 또는 비밀번호가 맞지 않습니다.');
  end if;
  delete from castle.tries where key = v_key;
  delete from castle.sessions where exp < now();
  v_tok := encode(extensions.gen_random_bytes(24), 'hex');
  if not v_adm then update castle.students set last_seen = now() where id = v_id; end if;
  -- 관리자 권한이 있는 선생님 계정은 비밀번호를 바꾼 뒤부터 관리자 화면으로 들어가요 (처음 0000일 때는 학생으로 들어가 비밀번호부터 바꿔요)
  insert into castle.sessions values (v_tok, case when v_adm then 'admin' else v_id end,
    case when v_adm or (v_staff and not v_must) then 'admin' else 'student' end, now() + interval '7 days');
  return jsonb_build_object('token', v_tok, 'role', case when v_adm or (v_staff and not v_must) then 'admin' else 'student' end,
    'mustChange', v_must and not v_adm, 'staff', v_staff, 'name', v_name, 'title', v_title);
end $$;

-- 회원가입: 아이디와 비밀번호만 받는다. 가입하면 바로 로그인된다.
create or replace function castle.r_register(b jsonb) returns jsonb language plpgsql as $$
declare v_id text := regexp_replace(normalize(coalesce(b->>'id', ''), NFC), '\s', '', 'g');
        v_pw text := coalesce(b->>'pw', '');
        v_ip text := coalesce((nullif(current_setting('request.headers', true), '')::jsonb)->>'x-forwarded-for', '');
        v_key text := 'reg|' || coalesce(nullif(v_ip, ''), 'local'); t castle.tries; v_tok text;
begin
  if coalesce(castle.cfg_all() ->> 'SIGNUP_OPEN', '0') <> '1' then
    return jsonb_build_object('error', '지금은 회원가입을 받지 않습니다. 선생님께 등록을 부탁하십시오.');
  end if;
  select * into t from castle.tries where key = v_key;
  if found and t.until_at is not null and t.until_at > now() then
    return jsonb_build_object('error', '가입을 너무 많이 시도했습니다. 10분 뒤에 다시 해 주십시오.');
  end if;
  if v_id !~ '^[가-힣A-Za-z0-9_]{2,20}$' then
    return jsonb_build_object('error', '아이디는 한글·영문·숫자·_ 로 2~20자입니다.');
  end if;
  if lower(v_id) = 'admin' then return jsonb_build_object('error', '쓸 수 없는 아이디입니다.'); end if;
  if length(v_pw) < 4 or length(v_pw) > 30 then
    return jsonb_build_object('error', '비밀번호는 4~30자입니다.');
  end if;
  if exists (select 1 from castle.students where id = v_id) then
    return jsonb_build_object('error', '이미 있는 아이디입니다. 다른 아이디를 써 주십시오.');
  end if;
  insert into castle.tries as x (key, n) values (v_key, 1)
    on conflict (key) do update set n = case when x.n + 1 >= 100 then 0 else x.n + 1 end,
                                    until_at = case when x.n + 1 >= 100 then now() + interval '10 minutes' else x.until_at end;
  insert into castle.students (id, name, points, must_change, pw_hash)
    values (v_id, v_id, 0, false, extensions.crypt(v_pw, extensions.gen_salt('bf', 6)));
  perform castle.add_pts(v_id, castle.c('START_POINTS'), '기본 포인트');
  delete from castle.sessions where exp < now();
  v_tok := encode(extensions.gen_random_bytes(24), 'hex');
  insert into castle.sessions values (v_tok, v_id, 'student', now() + interval '7 days');
  return jsonb_build_object('token', v_tok, 'role', 'student', 'mustChange', false);
end $$;

create or replace function castle.r_logout(tok text) returns jsonb language plpgsql as $$
begin
  delete from castle.sessions where token = tok;
  return jsonb_build_object('ok', true);
end $$;

create or replace function castle.r_setpw(tok text, b jsonb) returns jsonb language plpgsql as $$
declare st castle.students := castle.stu(tok); v_pw text := coalesce(b->>'pw', '');
begin
  if length(v_pw) < 4 or length(v_pw) > 30 then perform castle.fail(400, '비밀번호는 4~30자입니다.'); end if;
  if v_pw = '0000' then perform castle.fail(400, '0000은 쓸 수 없습니다. 다른 숫자로 정해 주십시오.'); end if;
  update castle.students set pw_hash = extensions.crypt(v_pw, extensions.gen_salt('bf', 6)), must_change = false where id = st.id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function castle.r_me(tok text) returns jsonb language plpgsql as $$
declare st castle.students := castle.stu(tok); a castle.attempts := castle.settle(st.id); v_pts int;
begin
  update castle.students set last_seen = now() where id = st.id and (last_seen is null or last_seen < now() - interval '2 minutes');
  select points into v_pts from castle.students where id = st.id;
  return jsonb_build_object('id', st.id, 'name', st.name, 'points', v_pts, 'mustChange', st.must_change, 'isAdmin', st.is_admin, 'isTeacher', st.is_teacher, 'title', st.title, 'grade', st.grade,
    'grades', to_jsonb(castle.allowed_grades(st)), 'cfg', castle.cfg_all(), 'mult', castle.next_mult(st.id),
    'todayCount', castle.today_count(st.id), 'active', castle.active_view(a), 'serverNow', castle.ms(clock_timestamp()));
end $$;

create or replace function castle.r_rank(tok text) returns jsonb language plpgsql as $$
declare st castle.students := castle.stu(tok); v_ok boolean := (not st.is_teacher and not st.is_admin);
begin
  -- 순위는 학생만, 1,000P 이상만 보인다 (전체 순위 + 내 학년 순위)
  return jsonb_build_object('grade', st.grade,
    'top', (select coalesce(jsonb_agg(jsonb_build_object('rank', rk, 'name', castle.mask_name(name), 'grade', grade, 'points', points, 'me', id = st.id) order by rk), '[]')
            from (select id, name, grade, points, row_number() over (order by points desc, created_at) as rk
                  from castle.students where points >= 1000 and not is_teacher and not is_admin) q where rk <= 10),
    'myRank', case when v_ok and st.points >= 1000 then 1 + (select count(*) from castle.students where points > st.points and not is_teacher and not is_admin) end,
    'total', (select count(*) from castle.students where points >= 1000 and not is_teacher and not is_admin),
    'gradeTop', (select coalesce(jsonb_agg(jsonb_build_object('rank', rk, 'name', castle.mask_name(name), 'grade', grade, 'points', points, 'me', id = st.id) order by rk), '[]')
            from (select id, name, grade, points, row_number() over (order by points desc, created_at) as rk
                  from castle.students where points >= 1000 and not is_teacher and not is_admin and grade = st.grade and st.grade <> '') q where rk <= 10),
    'myGradeRank', case when v_ok and st.grade <> '' and st.points >= 1000
                   then 1 + (select count(*) from castle.students where points > st.points and not is_teacher and not is_admin and grade = st.grade) end,
    'gradeTotal', (select count(*) from castle.students where points >= 1000 and not is_teacher and not is_admin and grade = st.grade and st.grade <> ''));
end $$;

create or replace function castle.r_preview(tok text, b jsonb) returns jsonb language plpgsql as $$
declare st castle.students := castle.stu(tok); a castle.attempts := castle.settle(st.id); p castle.problems; v_g text := b->>'grade';
begin
  if a.id is not null then perform castle.fail(400, '진행 중인 문제가 있습니다.'); end if;
  if v_g is null or not (v_g = any (castle.allowed_grades(st))) then perform castle.fail(400, '본인 학년 이상의 문제만 풀 수 있습니다.'); end if;
  if st.points < castle.c('PREVIEW_COST') then perform castle.fail(400, '포인트가 부족합니다.'); end if;
  select * into p from castle.problems where grade = v_g and active and not (id = any (st.done))
    and castle.unit_ok(v_g, subject, unit_large, unit)
    and not exists (select 1 from castle.attempts x where x.sid = st.id and x.pid = problems.id) order by random() limit 1;
  if not found then
    select * into p from castle.problems where grade = v_g and active and not (id = any (st.done)) and castle.unit_ok(v_g, subject, unit_large, unit) order by random() limit 1;
  end if;
  if not found then perform castle.fail(400, '지금은 이 학년에 풀 수 있는 문제가 없습니다. 다른 학년을 선택해 주십시오.'); end if;
  perform castle.add_pts(st.id, -castle.c('PREVIEW_COST'), '문제 미리보기');
  insert into castle.attempts (sid, pid, grade, state) values (st.id, p.id, p.grade, 'preview') returning * into a;
  return jsonb_build_object('points', (select points from castle.students where id = st.id), 'active', castle.active_view(a), 'serverNow', castle.ms(clock_timestamp()));
end $$;

create or replace function castle.r_skip(tok text) returns jsonb language plpgsql as $$
declare st castle.students := castle.stu(tok);
begin
  update castle.attempts set state = 'skipped', end_at = now() where sid = st.id and state = 'preview';
  return jsonb_build_object('points', st.points);
end $$;

create or replace function castle.r_accept(tok text) returns jsonb language plpgsql as $$
declare st castle.students := castle.stu(tok); a castle.attempts; v_mult int;
begin
  select * into a from castle.attempts where sid = st.id and state in ('preview', 'solving') order by id desc limit 1;
  if not found or a.state <> 'preview' then perform castle.fail(400, '미리보기 중인 문제가 없습니다.'); end if;
  if st.points < castle.c('ACCEPT_COST') then perform castle.fail(400, '풀이 포인트(' || castle.c('ACCEPT_COST') || 'P)가 부족합니다.'); end if;
  perform castle.add_pts(st.id, -castle.c('ACCEPT_COST'), '문제 풀기 선택');
  v_mult := (castle.next_mult(st.id)->>'value')::int;
  update castle.attempts set day = castle.kst_today(), mult = v_mult, state = 'solving', start_at = now(),
         deadline = now() + make_interval(secs => castle.c('TIME_LIMIT_SEC')::double precision)
   where id = a.id returning * into a;
  return jsonb_build_object('points', (select points from castle.students where id = st.id), 'active', castle.active_view(a),
                            'mult', v_mult, 'serverNow', castle.ms(clock_timestamp()));
end $$;

create or replace function castle.r_submit(tok text, b jsonb) returns jsonb language plpgsql as $$
declare st castle.students := castle.stu(tok); a castle.attempts; p castle.problems;
begin
  select * into a from castle.attempts where sid = st.id and state = 'solving' order by id desc limit 1;
  if not found then perform castle.fail(400, '풀고 있는 문제가 없습니다.'); end if;
  perform castle.finish(a.id, b->>'answer', now() > a.deadline + interval '5 seconds');
  select * into a from castle.attempts where id = a.id;
  select * into p from castle.problems where id = a.pid;
  return jsonb_build_object('pid', a.pid, 'correct', a.correct, 'timeout', a.timeout, 'reward', a.reward, 'mult', a.mult,
    'points', (select points from castle.students where id = st.id),
    'answer', coalesce(p.answer, ''), 'explanation', coalesce(p.explanation, ''), 'extra', coalesce(p.extra, ''), 'explImage', coalesce(p.expl_image, ''),
    'season', a.season_id is not null, 'score', a.score);
end $$;

create or replace function castle.r_history(tok text) returns jsonb language plpgsql as $$
declare st castle.students := castle.stu(tok);
begin
  return (select coalesce(jsonb_agg(jsonb_build_object('pid', q.pid, 't', castle.ms(q.end_at), 'grade', q.grade,
            'text', coalesce(q.ptext, '(삭제된 문제)'), 'image', case when q.rn <= 10 then coalesce(q.pimage, '') else '' end,
            'correct', q.correct, 'timeout', q.timeout, 'reward', q.reward, 'myAnswer', q.answer, 'answer', q.panswer,
            'explanation', q.pexpl, 'extra', q.pextra, 'explImage', case when q.rn <= 10 then coalesce(q.pexi, '') else '' end) order by q.id desc), '[]')
          from (select a.*, p.text as ptext, p.image as pimage, p.answer as panswer, p.explanation as pexpl, p.extra as pextra, p.expl_image as pexi,
                       row_number() over (order by a.id desc) as rn
                from castle.attempts a left join castle.problems p on p.id = a.pid
                where a.sid = st.id and a.state = 'done' and a.season_id is null order by a.id desc limit 30) q);
end $$;


-- ----- 공지사항 · 내 통계 -----
create table if not exists castle.notices (
  id serial primary key, title text not null, body text not null default '', pinned boolean not null default false,
  created_at timestamptz not null default now());
alter table castle.notices enable row level security;

create or replace function castle.r_notices(tok text) returns jsonb language plpgsql as $$
begin
  perform castle.auth(tok, null);
  return (select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'title', n.title, 'body', n.body, 'pinned', n.pinned, 't', castle.ms(n.created_at))
            order by n.pinned desc, n.id desc), '[]')
          from (select * from castle.notices order by pinned desc, id desc limit 30) n);
end $$;

create or replace function castle.r_admin_notice_save(tok text, b jsonb) returns jsonb language plpgsql as $$
declare v_t text := btrim(coalesce(b->>'title', '')); v_b text := btrim(coalesce(b->>'body', ''));
begin
  perform castle.auth(tok, 'admin');
  if v_t = '' then perform castle.fail(400, '제목을 입력해 주십시오.'); end if;
  if length(v_t) > 60 or length(v_b) > 2000 then perform castle.fail(400, '제목은 60자, 내용은 2000자까지 쓸 수 있습니다.'); end if;
  insert into castle.notices (title, body, pinned) values (v_t, v_b, coalesce((b->>'pinned')::boolean, false));
  return jsonb_build_object('ok', true);
end $$;

create or replace function castle.r_admin_notice_del(tok text, b jsonb) returns jsonb language plpgsql as $$
begin
  perform castle.auth(tok, 'admin');
  delete from castle.notices where id = (b->>'id')::int;
  return jsonb_build_object('ok', true);
end $$;

-- 내 통계: 전체 정답률, 최근 7일, 학년별, 약한 단원(3문제 이상 푼 대단원 중 정답률이 낮은 순)
create or replace function castle.r_stats(tok text) returns jsonb language plpgsql as $$
declare st castle.students := castle.stu(tok); v_today date := (now() at time zone 'Asia/Seoul')::date;
begin
  return jsonb_build_object(
    'total', (select count(*) from castle.attempts where sid = st.id and state = 'done'),
    'ok', (select count(*) from castle.attempts where sid = st.id and state = 'done' and correct),
    'days', (select jsonb_agg(jsonb_build_object('d', to_char(d.day, 'FMMM/FMDD'), 'n', coalesce(x.n, 0), 'ok', coalesce(x.ok, 0)) order by d.day)
             from (select v_today - 6 + i as day from generate_series(0, 6) i) d
             left join (select (end_at at time zone 'Asia/Seoul')::date as day, count(*) as n, count(*) filter (where correct) as ok
                        from castle.attempts where sid = st.id and state = 'done' and end_at >= now() - interval '9 days' group by 1) x on x.day = d.day),
    'byGrade', (select coalesce(jsonb_agg(jsonb_build_object('grade', g.grade, 'n', g.n, 'ok', g.ok) order by g.grade), '[]')
                from (select grade, count(*) as n, count(*) filter (where correct) as ok from castle.attempts
                      where sid = st.id and state = 'done' group by grade) g),
    'weak', (select coalesce(jsonb_agg(jsonb_build_object('unit', w.u, 'n', w.n, 'ok', w.ok) order by w.rate, w.n desc), '[]')
             from (select p.unit_large as u, count(*) as n, count(*) filter (where a.correct) as ok,
                          (count(*) filter (where a.correct))::float / count(*) as rate
                   from castle.attempts a join castle.problems p on p.id = a.pid
                   where a.sid = st.id and a.state = 'done' and p.unit_large <> '' group by p.unit_large
                   having count(*) >= 3 order by 4, 2 desc limit 3) w));
end $$;


-- ----- 캐치유 테스트 오답모음 (KMMS 에서 복사해 온 데이터, 학생은 본인 것만 조회) -----
create table if not exists castle.catchu_rounds (
  id text primary key, title text not null, date date, grade text not null default '', total int not null default 0);
alter table castle.catchu_rounds add column if not exists scope text not null default '';   -- 시험 범위 (화면에 괄호로 표시)
create table if not exists castle.catchu_wrong (
  round_id text not null references castle.catchu_rounds(id) on delete cascade,
  sid text not null references castle.students(id) on delete cascade,
  wrong jsonb not null default '[]', retest_date date, still_wrong jsonb,
  primary key (round_id, sid));
create table if not exists castle.catchu_items (
  round_id text not null references castle.catchu_rounds(id) on delete cascade,
  no int not null, prob text not null default '', expl text not null default '',
  primary key (round_id, no));
alter table castle.catchu_rounds enable row level security;
alter table castle.catchu_items enable row level security;
alter table castle.catchu_wrong enable row level security;

create or replace function castle.r_catchu(tok text) returns jsonb language plpgsql as $$
declare st castle.students := castle.stu(tok);
begin
  return (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'title', r.title, 'date', r.date, 'grade', r.grade, 'scope', r.scope, 'total', r.total,
            'wrong', w.wrong, 'retestDate', w.retest_date, 'stillWrong', w.still_wrong, 'have', to_jsonb(castle.catchu_have(r.id))) order by r.date desc nulls last, r.title), '[]')
          from castle.catchu_wrong w join castle.catchu_rounds r on r.id = w.round_id where w.sid = st.id);
end $$;

-- 본인이 틀린 문항의 문제·해설 이미지만 내려준다 (다른 문항·다른 학생 것은 내려주지 않음)
create or replace function castle.r_catchu_item(tok text, b jsonb) returns jsonb language plpgsql as $$
declare st castle.students := castle.stu(tok); v_no int := (b->>'no')::int; r castle.catchu_items;
begin
  if not exists (select 1 from castle.catchu_wrong w where w.round_id = b->>'roundId' and w.sid = st.id and w.wrong @> to_jsonb(v_no)) then
    perform castle.fail(404, '해당 문항이 없습니다.');
  end if;
  select * into r from castle.catchu_items where round_id = b->>'roundId' and no = v_no;
  if not found then return jsonb_build_object('prob', '', 'expl', ''); end if;
  return jsonb_build_object('prob', r.prob, 'expl', r.expl);
end $$;

-- 문항 이미지가 올라가 있는 번호 목록 (이미지가 아직 없는 문항은 번호만 보임)
create or replace function castle.catchu_have(p_round text) returns int[] language sql stable as $$
  select coalesce(array_agg(no order by no), '{}') from castle.catchu_items where round_id = p_round and prob <> '' $$;

-- KMMS 에서 뽑은 JSON ({rounds:[...], rows:[{roundId, sid, wrong, retestDate, stillWrong}]})을 넣는다. SQL 편집기에서만 호출 (앱 경로에는 연결하지 않음).
create or replace function castle.catchu_import(j jsonb) returns jsonb language plpgsql as $$
declare x jsonb; n_r int := 0; n_w int := 0; n_skip int := 0;
begin
  for x in select * from jsonb_array_elements(coalesce(j->'rounds', '[]')) loop
    insert into castle.catchu_rounds (id, title, date, grade, total)
      values (x->>'id', x->>'title', nullif(x->>'date', '')::date, coalesce(x->>'grade', ''), coalesce((x->>'total')::int, 0))
      on conflict (id) do update set title = excluded.title, date = excluded.date, grade = excluded.grade, total = excluded.total;
    n_r := n_r + 1;
  end loop;
  for x in select * from jsonb_array_elements(coalesce(j->'rows', '[]')) loop
    if exists (select 1 from castle.students where id = x->>'sid') and exists (select 1 from castle.catchu_rounds where id = x->>'roundId') then
      insert into castle.catchu_wrong (round_id, sid, wrong, retest_date, still_wrong)
        values (x->>'roundId', x->>'sid', coalesce(x->'wrong', '[]'), nullif(x->>'retestDate', '')::date, case when jsonb_typeof(x->'stillWrong') = 'array' then x->'stillWrong' end)
        on conflict (round_id, sid) do update set wrong = excluded.wrong, retest_date = excluded.retest_date, still_wrong = excluded.still_wrong;
      n_w := n_w + 1;
    else n_skip := n_skip + 1; end if;
  end loop;
  return jsonb_build_object('rounds', n_r, 'rows', n_w, 'skipped', n_skip);
end $$;

-- ----- 오답노트 -----
create or replace function castle.r_notes(tok text) returns jsonb language plpgsql as $$
declare st castle.students := castle.stu(tok);
begin
  return (select coalesce(jsonb_agg(jsonb_build_object('pid', n.pid, 'memo', n.memo, 'unit', coalesce(p.unit_large, ''), 't', castle.ms(n.created_at),
            'grade', coalesce(p.grade, ''), 'text', coalesce(p.text, '(삭제된 문제)'), 'image', coalesce(p.image, ''),
            'answer', coalesce(p.answer, ''), 'explanation', coalesce(p.explanation, ''), 'extra', coalesce(p.extra, ''), 'explImage', coalesce(p.expl_image, ''))
            order by n.created_at desc), '[]')
          from castle.notes n left join castle.problems p on p.id = n.pid where n.sid = st.id);
end $$;

create or replace function castle.r_note_add(tok text, b jsonb) returns jsonb language plpgsql as $$
declare st castle.students := castle.stu(tok); v_pid text := b->>'pid';
begin
  if v_pid is null or not exists (select 1 from castle.attempts where sid = st.id and pid = v_pid and state = 'done') then
    perform castle.fail(400, '풀어 본 문제만 오답노트에 담을 수 있습니다.');
  end if;
  if (select count(*) from castle.notes where sid = st.id) >= 500 then perform castle.fail(400, '오답노트는 500개까지 담을 수 있습니다.'); end if;
  insert into castle.notes (sid, pid) values (st.id, v_pid) on conflict do nothing;
  return jsonb_build_object('ok', true);
end $$;

create or replace function castle.r_note_update(tok text, b jsonb) returns jsonb language plpgsql as $$
declare st castle.students := castle.stu(tok);
begin
  update castle.notes set memo = left(coalesce(b->>'memo', ''), 1000)
   where sid = st.id and pid = b->>'pid';
  return jsonb_build_object('ok', true);
end $$;

create or replace function castle.r_note_del(tok text, b jsonb) returns jsonb language plpgsql as $$
declare st castle.students := castle.stu(tok);
begin
  delete from castle.notes where sid = st.id and pid = b->>'pid';
  return jsonb_build_object('ok', true);
end $$;

-- ----- 관리자 -----
create or replace function castle.r_admin_students(tok text) returns jsonb language plpgsql as $$
begin
  perform castle.auth(tok, 'admin');
  return (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'points', points, 'mustChange', must_change, 'isAdmin', is_admin, 'isTeacher', is_teacher, 'title', title, 'grade', grade,
            'today', castle.today_count(id), 'solved', coalesce(array_length(done, 1), 0), 'lastSeen', castle.ms(last_seen)) order by id), '[]') from castle.students);
end $$;

create or replace function castle.r_admin_addstudents(tok text, b jsonb) returns jsonb language plpgsql as $$
declare ln text; tk text[]; t text; k int; v_id text; v_name text; v_grade text; v_digits text; v_hash text; added jsonb := '[]'; skipped jsonb := '[]';
begin
  perform castle.auth(tok, 'admin');
  v_hash := extensions.crypt('0000', extensions.gen_salt('bf', 6));
  -- 한 줄에 한 명: 아이디(학교이름+이름) [실제 이름] [학년]   예) 해원고이시현 이시현 고1
  foreach ln in array regexp_split_to_array(normalize(coalesce(b->>'text', ''), NFC), '\r?\n') loop
    ln := btrim(ln);
    if ln = '' then continue; end if;
    tk := regexp_split_to_array(ln, '[,[:space:]]+');
    v_id := tk[1]; v_name := null; v_grade := ''; v_digits := '';
    if v_id !~ '^[가-힣A-Za-z·]+[0-9]?$' then skipped := skipped || to_jsonb(ln || ' (형식 오류)'); continue; end if;
    for k in 2 .. coalesce(array_length(tk, 1), 1) loop
      t := tk[k];
      if t ~ '^(중|고)[1-3]$' then v_grade := t;
      elsif t ~ '^[0-9]{4}$' then v_digits := t;
      elsif t ~ '^[가-힣A-Za-z·]+$' then v_name := t;
      else skipped := skipped || to_jsonb(ln || ' (형식 오류)'); v_id := null; exit; end if;
    end loop;
    if v_id is null then continue; end if;
    v_id := v_id || v_digits;
    if lower(v_id) = 'admin' or exists (select 1 from castle.students where id = v_id) then
      skipped := skipped || to_jsonb(v_id || ' (이미 있음)'); continue;
    end if;
    insert into castle.students (id, name, points, must_change, pw_hash, grade)
      values (v_id, coalesce(v_name, regexp_replace(v_id, '[0-9]+$', '')), 0, true, v_hash, v_grade);
    perform castle.add_pts(v_id, castle.c('START_POINTS'), '기본 포인트');
    added := added || to_jsonb(v_id);
  end loop;
  return jsonb_build_object('added', added, 'skipped', skipped);
end $$;

-- ----- 풀이 분석: 너무 빨리 맞힌 학생 찾기 (AI·외부 도움 의심용) -----
create or replace function castle.r_admin_suspects(tok text, b jsonb) returns jsonb language plpgsql as $$
declare v_days int := least(greatest(coalesce((b->>'days')::int, 14), 1), 365);
        v_fast int := least(greatest(coalesce((b->>'fast')::int, 20), 3), 600);
begin
  perform castle.auth(tok, 'admin');
  return (
    with t as (
      select a.sid, a.pid, a.correct, a.end_at, greatest(0, extract(epoch from (a.end_at - a.start_at))::int) as sec
      from castle.attempts a
      where a.state = 'done' and a.start_at is not null and a.end_at > now() - make_interval(days => v_days)
    ), g as (
      select sid, count(*) as n, count(*) filter (where correct) as c,
             count(*) filter (where correct and sec < v_fast) as fc,
             percentile_cont(0.5) within group (order by sec) filter (where correct) as med
      from t group by sid
    )
    select coalesce(jsonb_agg(jsonb_build_object(
        'sid', g.sid, 'n', g.n, 'correct', g.c, 'rate', round(100.0 * g.c / g.n),
        'median', coalesce(round(g.med::numeric), 0), 'fastCount', g.fc,
        'flag', g.fc >= 3 and g.fc * 2 >= g.c,
        'fast', coalesce((select jsonb_agg(jsonb_build_object('src', f.src, 'sec', f.sec) order by f.end_at desc)
                          from (select p.src, x.sec, x.end_at from t x left join castle.problems p on p.id = x.pid
                                where x.sid = g.sid and x.correct and x.sec < v_fast order by x.end_at desc limit 6) f), '[]'))
      order by g.fc desc, g.c desc, g.sid), '[]')
    from g);
end $$;

create or replace function castle.r_admin_points(tok text, b jsonb) returns jsonb language plpgsql as $$
declare v_delta int; v_id text; n int := 0; v_why text := coalesce(nullif(left(btrim(coalesce(b->>'reason', '')), 60), ''), '관리자 지급');
begin
  perform castle.auth(tok, 'admin');
  begin v_delta := trunc((b->>'delta')::numeric)::int; exception when others then v_delta := null; end;
  if v_delta is null or v_delta = 0 then perform castle.fail(400, '포인트 숫자를 입력해 주십시오.'); end if;
  for v_id in select jsonb_array_elements_text(coalesce(b->'ids', '[]')) loop
    if exists (select 1 from castle.students where id = v_id) then
      perform castle.add_pts(v_id, v_delta, '관리자: ' || v_why); n := n + 1;
    end if;
  end loop;
  return jsonb_build_object('count', n);
end $$;

create or replace function castle.r_admin_resetpw(tok text, b jsonb) returns jsonb language plpgsql as $$
begin
  perform castle.auth(tok, 'admin');
  update castle.students set pw_hash = extensions.crypt('0000', extensions.gen_salt('bf', 6)), must_change = true where id = b->>'id';
  if not found then perform castle.fail(404, '학생이 없습니다.'); end if;
  delete from castle.sessions where id = b->>'id';
  update castle.reset_requests set done = true where student = b->>'id' and not done;
  return jsonb_build_object('ok', true);
end $$;

-- 비밀번호 초기화 요청 (로그인 전에 학생이 보냄)
create or replace function castle.r_reset_request(b jsonb) returns jsonb language plpgsql as $$
declare v_id text := regexp_replace(normalize(coalesce(b->>'id', ''), NFC), '\s', '', 'g');
begin
  if v_id = '' or lower(v_id) = 'admin' or not exists (select 1 from castle.students where id = v_id) then
    perform castle.fail(400, '등록되지 않은 아이디입니다. 아이디를 다시 확인해 주십시오.');
  end if;
  if exists (select 1 from castle.reset_requests where student = v_id and not done) then
    return jsonb_build_object('ok', true, 'dup', true);
  end if;
  if (select count(*) from castle.reset_requests where not done) >= 300 then
    perform castle.fail(429, '요청이 많아 접수할 수 없습니다. 원장에게 직접 문의해 주십시오.');
  end if;
  insert into castle.reset_requests (student) values (v_id);
  return jsonb_build_object('ok', true);
end $$;

create or replace function castle.r_admin_resets(tok text) returns jsonb language plpgsql as $$
begin
  perform castle.auth(tok, 'admin');
  return (select coalesce(jsonb_agg(jsonb_build_object('id', q.student, 'name', x.name, 'grade', x.grade, 't', castle.ms(q.created_at)) order by q.id), '[]')
          from castle.reset_requests q join castle.students x on x.id = q.student where not q.done);
end $$;

create or replace function castle.r_admin_deletestudent(tok text, b jsonb) returns jsonb language plpgsql as $$
begin
  perform castle.auth(tok, 'admin');
  delete from castle.students where id = b->>'id';
  delete from castle.sessions where id = b->>'id';
  return jsonb_build_object('ok', true);
end $$;

create or replace function castle.r_admin_adminpw(tok text, b jsonb) returns jsonb language plpgsql as $$
declare v_id text := castle.auth(tok, 'admin');
begin
  if length(coalesce(b->>'pw', '')) < 4 then perform castle.fail(400, '비밀번호는 4자 이상이어야 합니다.'); end if;
  if v_id = 'admin' then
    perform castle.init_admin(b->>'pw');
  else  -- 관리자 권한이 있는 선생님 계정은 자기 비밀번호만 바꿔요
    update castle.students set pw_hash = extensions.crypt(b->>'pw', extensions.gen_salt('bf', 6)), must_change = false where id = v_id;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- 관리자 권한이 있는 선생님이 관리자 화면 ↔ 학생 화면을 오갈 때
create or replace function castle.r_switch(tok text, b jsonb) returns jsonb language plpgsql as $$
declare s castle.sessions; st castle.students; v_to text := case when b->>'to' = 'admin' then 'admin' else 'student' end; v_tok text;
begin
  select * into s from castle.sessions where token = tok and exp > now();
  if not found then perform castle.fail(401, '다시 로그인해 주십시오.'); end if;
  select * into st from castle.students where id = s.id;
  if not found or not st.is_admin or st.must_change then perform castle.fail(403, '권한이 없습니다.'); end if;
  v_tok := encode(extensions.gen_random_bytes(24), 'hex');
  insert into castle.sessions values (v_tok, st.id, v_to, now() + interval '7 days');
  return jsonb_build_object('token', v_tok, 'role', v_to);
end $$;

create or replace function castle.r_admin_cfg(tok text) returns jsonb language plpgsql as $$
begin
  perform castle.auth(tok, 'admin');
  return castle.cfg_all();
end $$;

create or replace function castle.r_admin_setcfg(tok text, b jsonb) returns jsonb language plpgsql as $$
declare r record; v numeric; nxt jsonb := '{}';
begin
  perform castle.auth(tok, 'admin');
  for r in select * from (values ('START_POINTS', 0, 1000000), ('PREVIEW_COST', 0, 100000), ('PREVIEW_SEC', 3, 120), ('ACCEPT_COST', 0, 100000),
                                 ('TIME_LIMIT_SEC', 60, 21600), ('REWARD', 0, 1000000), ('MORNING_FROM', 0, 23), ('MORNING_TO', 1, 24),
                                 ('DAILY_BONUS_COUNT', 1, 500)) as t (k, lo, hi) loop
    begin v := trunc((b->>r.k)::numeric); exception when others then v := null; end;
    if v is null or v < r.lo or v > r.hi then
      perform castle.fail(400, r.k || ' 값은 ' || r.lo || '~' || r.hi || ' 사이 숫자여야 합니다.');
    end if;
    nxt := nxt || jsonb_build_object(r.k, v);
  end loop;
  if (nxt->>'MORNING_TO')::int <= (nxt->>'MORNING_FROM')::int then perform castle.fail(400, '아침 시간대의 끝은 시작보다 늦어야 합니다.'); end if;
  update castle.cfg set data = data || nxt where id = 1;
  return castle.cfg_all();
end $$;

create or replace function castle.r_admin_units(tok text) returns jsonb language plpgsql as $$
begin
  perform castle.auth(tok, 'admin');
  return jsonb_build_object(
    'selected', coalesce(castle.cfg_all() -> 'UNITS', '{}'::jsonb),
    'units', coalesce((select jsonb_agg(jsonb_build_object('grade', grade, 'subject', subject, 'unit_large', unit_large, 'unit', unit, 'n', n) order by grade, ord)
                       from (select grade, subject, unit_large, unit, count(*) as n, min(created_at) as ord
                             from castle.problems group by grade, subject, unit_large, unit) s), '[]'::jsonb));
end $$;

create or replace function castle.r_admin_setunits(tok text, b jsonb) returns jsonb language plpgsql as $$
declare g text := b->>'grade';
begin
  perform castle.auth(tok, 'admin');
  if g is null or not (g = any (castle.grades())) then perform castle.fail(400, '학년이 올바르지 않습니다.'); end if;
  if jsonb_typeof(b->'units') is distinct from 'array' then perform castle.fail(400, '단원 목록이 필요합니다.'); end if;
  if jsonb_array_length(b->'units') = 0 then
    update castle.cfg set data = data #- array['UNITS', g] where id = 1;
  else
    update castle.cfg set data = jsonb_set(data, '{UNITS}', coalesce(data->'UNITS', '{}'::jsonb) || jsonb_build_object(g, b->'units'), true) where id = 1;
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function castle.r_admin_problems(tok text) returns jsonb language plpgsql as $$
begin
  perform castle.auth(tok, 'admin');
  return (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'grade', grade, 'text', text, 'answer', answer, 'image', case when length(image) > 30000 then '@keep' else image end,
            'expl_image', case when expl_image <> '' then '@keep' else '' end, 'explanation', explanation, 'extra', extra, 'active', active, 'level', level, 'book', book,
            'term', term, 'subject', subject, 'unit_large', unit_large, 'unit', unit, 'src', src) order by created_at, id), '[]') from castle.problems);
end $$;

create or replace function castle.r_admin_problem(tok text, b jsonb) returns jsonb language plpgsql as $$
begin
  perform castle.auth(tok, 'admin');
  return castle.upsert_problem(b);
end $$;

create or replace function castle.r_admin_deleteproblem(tok text, b jsonb) returns jsonb language plpgsql as $$
begin
  perform castle.auth(tok, 'admin');
  delete from castle.problems where id = b->>'id';
  return jsonb_build_object('ok', true);
end $$;

create or replace function castle.r_admin_deleteall(tok text, b jsonb) returns jsonb language plpgsql as $$
declare n int;
begin
  perform castle.auth(tok, 'admin');
  delete from castle.problems where true;
  get diagnostics n = row_count;
  return jsonb_build_object('deleted', n);
end $$;

create or replace function castle.r_admin_import(tok text, b jsonb) returns jsonb language plpgsql as $$
declare it jsonb; n int := 0; i int := 0; errs jsonb := '[]';
begin
  perform castle.auth(tok, 'admin');
  if jsonb_typeof(b->'items') <> 'array' then perform castle.fail(400, '문제 목록(배열)이 필요합니다.'); end if;
  for it in select jsonb_array_elements(b->'items') loop
    i := i + 1;
    begin perform castle.upsert_problem(it); n := n + 1;
    exception when others then errs := errs || to_jsonb(i || '번째: ' || sqlerrm); end;
  end loop;
  return jsonb_build_object('count', n, 'errors', errs);
end $$;

create or replace function castle.r_admin_log(tok text) returns jsonb language plpgsql as $$
begin
  perform castle.auth(tok, 'admin');
  return (select coalesce(jsonb_agg(jsonb_build_object('t', castle.ms(t), 'sid', sid, 'delta', delta, 'balance', balance, 'reason', reason) order by id desc), '[]')
          from (select * from castle.log order by id desc limit 300) q);
end $$;

-- 관리자 비밀번호 설정 (SQL Editor 에서: select castle.init_admin('원하는비밀번호'); )
create or replace function castle.init_admin(pw text) returns void language sql as $$
  insert into castle.admin (id, hash) values (1, extensions.crypt(pw, extensions.gen_salt('bf', 8)))
  on conflict (id) do update set hash = excluded.hash $$;

-- ---------- 문 하나: 화면은 이 함수만 부를 수 있습니다 ----------

-- =====================================================================
-- 시즌 랭킹전 / 선생님 담당 학생 현황 / 학년 순위
-- =====================================================================
create or replace function castle.season_cur() returns castle.seasons language sql stable as $$
  select * from castle.seasons where now() >= starts_at and now() < ends_at order by id desc limit 1 $$;

-- 시즌 순위 (학생만, 점수 높은 순 → 같으면 먼저 달성한 순)
create or replace function castle.season_board(p_id int)
returns table (sid text, name text, grade text, score int, ok int, n int, last_at timestamptz, r bigint, gr bigint)
language sql stable as $$
  with sc as (
    select a.sid, sum(a.score)::int as score, (count(*) filter (where a.correct))::int as ok, count(*)::int as n, max(a.end_at) as last_at
    from castle.attempts a join castle.students x on x.id = a.sid
    where a.season_id = p_id and a.state = 'done' and not x.is_teacher and not x.is_admin group by a.sid)
  select sc.sid, x.name, x.grade, sc.score, sc.ok, sc.n, sc.last_at,
         row_number() over (order by sc.score desc, sc.last_at asc),
         row_number() over (partition by x.grade order by sc.score desc, sc.last_at asc)
  from sc join castle.students x on x.id = sc.sid $$;

create or replace function castle.r_season_info(tok text, b jsonb default '{}') returns jsonb language plpgsql as $$
declare st castle.students := castle.stu(tok); s castle.seasons := castle.season_cur(); v_status text := 'active'; v_me jsonb; v_pool int := 0;
        v_al text[] := castle.season_grades(st); v_pick boolean := coalesce(array_length(st.season_grades, 1), 0) > 1; v_sel text := nullif(b->>'grade', ''); v_lock text;
begin
  if s.id is null then
    select * into s from castle.seasons where now() < starts_at order by starts_at limit 1; v_status := 'upcoming';
    if s.id is null then select * into s from castle.seasons order by ends_at desc limit 1; v_status := 'ended'; end if;
  end if;
  if s.id is null then return jsonb_build_object('season', null, 'serverNow', castle.ms(clock_timestamp())); end if;
  select jsonb_build_object('score', b.score, 'rank', b.r, 'gradeRank', b.gr, 'ok', b.ok, 'n', b.n) into v_me from castle.season_board(s.id) b where b.sid = st.id;
  select a.grade into v_lock from castle.attempts a where a.sid = st.id and a.season_id = s.id order by a.id limit 1;   -- 한 번 고른 학년은 이번 시즌 동안 고정
  if v_pick and v_lock = any (v_al) then v_sel := v_lock; end if;
  if v_pick and (v_sel is null or not (v_sel = any (v_al))) then v_sel := v_al[1]; end if;
  select count(*) into v_pool from castle.problems p where p.active and p.level >= s.min_level and (case when v_pick then p.grade = v_sel else p.grade = any (v_al) end)
    and not exists (select 1 from castle.attempts x where x.sid = st.id and x.season_id = s.id and x.pid = p.id);
  return jsonb_build_object('serverNow', castle.ms(clock_timestamp()), 'grade', st.grade, 'canPlay', not st.is_teacher and not st.is_admin,
    'season', jsonb_build_object('id', s.id, 'name', s.name, 'status', v_status, 'startsAt', castle.ms(s.starts_at), 'endsAt', castle.ms(s.ends_at),
                                 'prize', s.prize, 'minLevel', s.min_level, 'timeLimitSec', castle.c('TIME_LIMIT_SEC')),
    'me', coalesce(v_me, jsonb_build_object('score', 0, 'rank', null, 'gradeRank', null, 'ok', 0, 'n', 0)), 'poolLeft', v_pool,
    'pickGrades', case when v_pick then to_jsonb(v_al) end, 'selGrade', v_sel, 'lockedGrade', case when v_pick and v_lock = any (v_al) then v_lock end,
    'total', (select count(*) from castle.season_board(s.id)),
    'top', (select coalesce(jsonb_agg(jsonb_build_object('rank', b.r, 'name', castle.mask_name(b.name), 'grade', b.grade, 'score', b.score, 'ok', b.ok, 'me', b.sid = st.id) order by b.r), '[]')
            from castle.season_board(s.id) b where b.r <= 20),
    'gradeTop', (select coalesce(jsonb_agg(jsonb_build_object('rank', b.gr, 'name', castle.mask_name(b.name), 'grade', b.grade, 'score', b.score, 'ok', b.ok, 'me', b.sid = st.id) order by b.gr), '[]')
            from castle.season_board(s.id) b where st.grade <> '' and b.grade = st.grade and b.gr <= 10));
end $$;

create or replace function castle.r_season_start(tok text, b jsonb default '{}') returns jsonb language plpgsql as $$
declare st castle.students := castle.stu(tok); a castle.attempts := castle.settle(st.id); s castle.seasons := castle.season_cur(); p castle.problems;
        v_al text[] := castle.season_grades(st); v_pick boolean := coalesce(array_length(st.season_grades, 1), 0) > 1; v_sel text := nullif(b->>'grade', ''); v_lock text;
begin
  if st.is_teacher or st.is_admin then perform castle.fail(403, '시즌 랭킹전은 학생만 참가할 수 있습니다.'); end if;
  if a.id is not null then
    if a.season_id is not null then return jsonb_build_object('active', castle.active_view(a), 'serverNow', castle.ms(clock_timestamp())); end if;
    perform castle.fail(400, '진행 중인 문제가 있습니다.');
  end if;
  if s.id is null then perform castle.fail(400, '지금 진행 중인 시즌이 없습니다.'); end if;
  if v_pick then
    select x.grade into v_lock from castle.attempts x where x.sid = st.id and x.season_id = s.id order by x.id limit 1;
    if v_lock = any (v_al) then v_sel := v_lock; end if;
    if v_sel is null or not (v_sel = any (v_al)) then perform castle.fail(400, '도전할 학년을 선택해 주십시오.'); end if;
  end if;
  select * into p from castle.problems q where q.active and q.level >= s.min_level and (case when v_pick then q.grade = v_sel else q.grade = any (v_al) end)
    and not exists (select 1 from castle.attempts x where x.sid = st.id and x.season_id = s.id and x.pid = q.id) order by random() limit 1;
  if not found then perform castle.fail(400, '이번 시즌의 문제를 모두 풀었습니다. 새 문제가 등록되면 다시 도전할 수 있습니다.'); end if;
  insert into castle.attempts (sid, pid, grade, state, season_id, start_at, deadline, mult)
    values (st.id, p.id, p.grade, 'solving', s.id, now(), now() + make_interval(secs => castle.c('TIME_LIMIT_SEC')::double precision), 1) returning * into a;
  return jsonb_build_object('active', castle.active_view(a), 'serverNow', castle.ms(clock_timestamp()));
end $$;

-- 담당 학생 현황
create or replace function castle.roster_rows(p_teacher text) returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'grade', x.grade, 'points', x.points, 'mustChange', x.must_change,
    'today', castle.today_count(x.id),
    'week', (select count(*) from castle.attempts a where a.sid = x.id and a.state = 'done' and a.season_id is null and a.end_at > now() - interval '7 days'),
    'weekOk', (select count(*) from castle.attempts a where a.sid = x.id and a.state = 'done' and a.season_id is null and a.correct and a.end_at > now() - interval '7 days'),
    'total', (select count(*) from castle.attempts a where a.sid = x.id and a.state = 'done' and a.season_id is null),
    'last', (select castle.ms(max(a.end_at)) from castle.attempts a where a.sid = x.id and a.state = 'done')
  ) order by x.grade, x.id), '[]')
  from castle.roster r join castle.students x on x.id = r.student where r.teacher = p_teacher $$;

create or replace function castle.r_roster(tok text) returns jsonb language plpgsql as $$
declare st castle.students := castle.stu(tok);
begin
  if not st.is_teacher then perform castle.fail(403, '권한이 없습니다.'); end if;
  return jsonb_build_object('teacher', st.id, 'name', st.name, 'students', castle.roster_rows(st.id), 'serverNow', castle.ms(clock_timestamp()));
end $$;

create or replace function castle.r_admin_rosters(tok text) returns jsonb language plpgsql as $$
begin
  perform castle.auth(tok, 'admin');
  return jsonb_build_object('serverNow', castle.ms(clock_timestamp()),
    'teachers', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'title', t.title, 'students', castle.roster_rows(t.id)) order by t.id), '[]')
                 from castle.students t where t.is_teacher),
    'unassigned', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'grade', x.grade) order by x.grade, x.id), '[]')
                   from castle.students x where not x.is_teacher and not x.is_admin and not exists (select 1 from castle.roster r where r.student = x.id)));
end $$;

-- 선생님 반에 학생 넣기/빼기: {teacher, add: [아이디...], remove: [아이디...]}
create or replace function castle.r_admin_roster_edit(tok text, b jsonb) returns jsonb language plpgsql as $$
declare v_t text := b->>'teacher'; v_id text; n_add int := 0; n_rm int := 0; miss text := '';
begin
  perform castle.auth(tok, 'admin');
  if not exists (select 1 from castle.students where id = v_t and is_teacher) then perform castle.fail(400, '선생님 계정이 아닙니다.'); end if;
  for v_id in select jsonb_array_elements_text(coalesce(b->'add', '[]')) loop
    if exists (select 1 from castle.students where id = v_id) then
      insert into castle.roster (teacher, student) values (v_t, v_id) on conflict do nothing; n_add := n_add + 1;
    else miss := miss || v_id || ' '; end if;
  end loop;
  for v_id in select jsonb_array_elements_text(coalesce(b->'remove', '[]')) loop
    delete from castle.roster where teacher = v_t and student = v_id; n_rm := n_rm + 1;
  end loop;
  return jsonb_build_object('added', n_add, 'removed', n_rm, 'missing', miss);
end $$;

-- 학년·호칭·선생님/관리자 표시: {id, grade?, title?, isTeacher?, isAdmin?}
create or replace function castle.r_admin_studentmeta(tok text, b jsonb) returns jsonb language plpgsql as $$
begin
  perform castle.auth(tok, 'admin');
  update castle.students set
    grade = case when b ? 'grade' then left(coalesce(b->>'grade', ''), 4) else grade end,
    title = case when b ? 'title' then left(coalesce(b->>'title', ''), 10) else title end,
    is_teacher = case when b ? 'isTeacher' then (b->>'isTeacher')::boolean else is_teacher end,
    is_admin = case when b ? 'isAdmin' then (b->>'isAdmin')::boolean else is_admin end
  where id = b->>'id';
  return jsonb_build_object('ok', true);
end $$;

-- ----- 시즌 관리 (관리자) -----
create or replace function castle.season_top(p_id int, p_n int) returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object('rank', b.r, 'id', b.sid, 'name', b.name, 'grade', b.grade, 'score', b.score, 'ok', b.ok) order by b.r), '[]')
  from castle.season_board(p_id) b where b.r <= p_n $$;

create or replace function castle.r_admin_seasons(tok text) returns jsonb language plpgsql as $$
begin
  perform castle.auth(tok, 'admin');
  return jsonb_build_object('serverNow', castle.ms(clock_timestamp()),
    'pool', (select count(*) from castle.problems where active and level >= 4),
    'pools', (select jsonb_agg((select count(*) from castle.problems where active and level >= n) order by n) from generate_series(1, 5) n),
    'seasons', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'startsAt', castle.ms(s.starts_at), 'endsAt', castle.ms(s.ends_at),
      'minLevel', s.min_level, 'prize', s.prize, 'pool', (select count(*) from castle.problems where active and level >= s.min_level),
      'players', (select count(*) from castle.season_board(s.id)), 'top', castle.season_top(s.id, 10)) order by s.id desc), '[]') from castle.seasons s));
end $$;

create or replace function castle.r_admin_season_save(tok text, b jsonb) returns jsonb language plpgsql as $$
declare v_id int := nullif(b->>'id', '')::int; v_start timestamptz; v_end timestamptz;
begin
  perform castle.auth(tok, 'admin');
  begin v_start := (b->>'startsAt')::timestamptz; v_end := (b->>'endsAt')::timestamptz;
  exception when others then perform castle.fail(400, '시작·종료 시각이 올바르지 않습니다.'); end;
  if v_start is null or v_end is null or v_end <= v_start then perform castle.fail(400, '종료 시각은 시작 시각보다 뒤여야 합니다.'); end if;
  if length(btrim(coalesce(b->>'name', ''))) = 0 then perform castle.fail(400, '시즌 이름을 입력해 주십시오.'); end if;
  if v_id is null then
    insert into castle.seasons (name, starts_at, ends_at, min_level, prize)
      values (left(btrim(b->>'name'), 40), v_start, v_end, least(greatest(coalesce((b->>'minLevel')::int, 4), 1), 5), left(coalesce(b->>'prize', ''), 300)) returning id into v_id;
  else
    update castle.seasons set name = left(btrim(b->>'name'), 40), starts_at = v_start, ends_at = v_end,
      min_level = least(greatest(coalesce((b->>'minLevel')::int, min_level), 1), 5), prize = left(coalesce(b->>'prize', ''), 300) where id = v_id;
  end if;
  return jsonb_build_object('id', v_id);
end $$;

create or replace function castle.r_admin_season_delete(tok text, b jsonb) returns jsonb language plpgsql as $$
begin
  perform castle.auth(tok, 'admin');
  delete from castle.attempts where season_id = (b->>'id')::int;
  delete from castle.seasons where id = (b->>'id')::int;
  return jsonb_build_object('ok', true);
end $$;


-- ----- 친구 + 팀 (팀은 시즌 전에 미리 꾸림, 2~4명) -----
-- 친구: 아이디로 신청 → 상대가 수락하면 친구. 팀 초대는 친구에게만 보낼 수 있음.
create table if not exists castle.friends (
  a text not null references castle.students(id) on delete cascade,      -- 신청한 학생
  b text not null references castle.students(id) on delete cascade,      -- 신청받은 학생
  state text not null default 'pending' check (state in ('pending', 'accepted')),
  created_at timestamptz not null default now(), primary key (a, b), check (a <> b));
create unique index if not exists friends_pair on castle.friends (least(a, b), greatest(a, b));
alter table castle.friends enable row level security;

-- 예전(시즌에 묶인) 팀 표가 있으면 한 번만 정리한다 (팀은 이제 시즌과 무관)
do $$ begin
  if exists (select 1 from information_schema.columns where table_schema = 'castle' and table_name = 'teams' and column_name = 'season_id') then
    drop table if exists castle.team_members cascade;
    drop table if exists castle.teams cascade;
  end if;
end $$;

create table if not exists castle.teams (
  id serial primary key, name text not null unique, leader text not null references castle.students(id) on delete cascade,
  created_at timestamptz not null default now());
create table if not exists castle.team_members (
  team_id int not null references castle.teams(id) on delete cascade,
  sid text not null references castle.students(id) on delete cascade,
  state text not null default 'invited' check (state in ('invited', 'joined')),
  created_at timestamptz not null default now(), primary key (team_id, sid));
create unique index if not exists team_members_one_team on castle.team_members (sid) where state = 'joined';
create table if not exists castle.team_stints (
  id serial primary key, team_id int not null references castle.teams(id) on delete cascade,
  sid text not null references castle.students(id) on delete cascade,
  from_at timestamptz not null default now(), to_at timestamptz);
create index if not exists team_stints_team on castle.team_stints (team_id);
insert into castle.team_stints (team_id, sid, from_at)
  select m.team_id, m.sid, m.created_at from castle.team_members m
  where m.state = 'joined' and not exists (select 1 from castle.team_stints z where z.team_id = m.team_id and z.sid = m.sid and z.to_at is null);
alter table castle.team_stints enable row level security;
alter table castle.teams enable row level security;
alter table castle.team_members enable row level security;

-- 팀 점수를 매기는 시즌: 진행 중인 시즌, 없으면 다음 시즌, 그것도 없으면 가장 최근 시즌
create or replace function castle.team_season() returns castle.seasons language plpgsql stable as $$
declare s castle.seasons := castle.season_cur();
begin
  if s.id is null then select * into s from castle.seasons where now() < starts_at order by starts_at limit 1; end if;
  if s.id is null then select * into s from castle.seasons order by ends_at desc limit 1; end if;
  return s;
end $$;

-- 시즌 중에도 팀 구성은 자유롭게 바꿀 수 있다. 팀 점수는 그 팀의 팀원이던 동안 얻은 점수만 센다.
create or replace function castle.team_member_score(p_team int, p_sid text, p_season int) returns int language sql stable as $$
  select coalesce(sum(a.score), 0)::int from castle.team_stints z
  join castle.attempts a on a.sid = z.sid and a.season_id = p_season and a.state = 'done'
       and a.end_at >= z.from_at and (z.to_at is null or a.end_at < z.to_at)
  where z.team_id = p_team and z.sid = p_sid $$;

-- 팀 순위: 팀원 2명 이상인 팀만, 팀원 시즌 점수의 합이 높은 순 (같으면 먼저 만든 팀)
create or replace function castle.team_board(p_id int)
returns table (team_id int, name text, score int, n int, r bigint) language sql stable as $$
  with t as (
    select t.id, t.name, (select coalesce(sum(castle.team_member_score(t.id, z.sid, p_id)), 0) from (select distinct sid from castle.team_stints where team_id = t.id) z)::int as score,
           (select count(*) from castle.team_members m where m.team_id = t.id and m.state = 'joined')::int as n
    from castle.teams t)
  select t.id, t.name, t.score, t.n, row_number() over (order by t.score desc, t.id) from t where t.n >= 2 $$;

create or replace function castle.is_friend(x text, y text) returns boolean language sql stable as $$
  select exists (select 1 from castle.friends where state = 'accepted' and ((a = x and b = y) or (a = y and b = x))) $$;

create or replace function castle.r_friend_list(tok text) returns jsonb language plpgsql as $$
declare st castle.students := castle.stu(tok);
begin
  return jsonb_build_object(
    'friends', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'grade', x.grade) order by x.name), '[]')
                from castle.friends f join castle.students x on x.id = case when f.a = st.id then f.b else f.a end
                where f.state = 'accepted' and st.id in (f.a, f.b)),
    'incoming', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'grade', x.grade) order by f.created_at), '[]')
                from castle.friends f join castle.students x on x.id = f.a where f.state = 'pending' and f.b = st.id),
    'outgoing', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'grade', x.grade) order by f.created_at), '[]')
                from castle.friends f join castle.students x on x.id = f.b where f.state = 'pending' and f.a = st.id));
end $$;

create or replace function castle.r_friend_add(tok text, p jsonb) returns jsonb language plpgsql as $$
declare st castle.students := castle.stu(tok); v_to castle.students; v_f castle.friends;
begin
  if st.is_teacher or st.is_admin then perform castle.fail(403, '학생만 친구를 등록할 수 있습니다.'); end if;
  select * into v_to from castle.students where id = btrim(coalesce(p->>'id', ''));
  if v_to.id is null or v_to.is_teacher or v_to.is_admin then perform castle.fail(404, '해당 아이디의 학생을 찾을 수 없습니다.'); end if;
  if v_to.id = st.id then perform castle.fail(400, '본인은 친구로 등록할 수 없습니다.'); end if;
  select * into v_f from castle.friends where (a = st.id and b = v_to.id) or (a = v_to.id and b = st.id);
  if v_f.a is not null then
    if v_f.state = 'accepted' then perform castle.fail(400, '이미 친구입니다.'); end if;
    if v_f.a = st.id then perform castle.fail(400, '이미 친구 신청을 보냈습니다.'); end if;
    update castle.friends set state = 'accepted' where a = v_f.a and b = v_f.b;   -- 상대가 먼저 신청했으면 바로 친구가 됨
    return jsonb_build_object('ok', true, 'accepted', true);
  end if;
  insert into castle.friends (a, b) values (st.id, v_to.id);
  return jsonb_build_object('ok', true, 'accepted', false);
end $$;

create or replace function castle.r_friend_respond(tok text, p jsonb) returns jsonb language plpgsql as $$
declare st castle.students := castle.stu(tok); v_id text := btrim(coalesce(p->>'id', ''));
begin
  if not exists (select 1 from castle.friends where a = v_id and b = st.id and state = 'pending') then perform castle.fail(404, '친구 신청이 없거나 이미 취소되었습니다.'); end if;
  if coalesce((p->>'accept')::boolean, false) then update castle.friends set state = 'accepted' where a = v_id and b = st.id;
  else delete from castle.friends where a = v_id and b = st.id; end if;
  return jsonb_build_object('ok', true);
end $$;

-- 친구 끊기 / 보낸 신청 취소
create or replace function castle.r_friend_remove(tok text, p jsonb) returns jsonb language plpgsql as $$
declare st castle.students := castle.stu(tok); v_id text := btrim(coalesce(p->>'id', ''));
begin
  delete from castle.friends where (a = st.id and b = v_id) or (a = v_id and b = st.id);
  return jsonb_build_object('ok', true);
end $$;

create or replace function castle.r_team_info(tok text) returns jsonb language plpgsql as $$
declare st castle.students := castle.stu(tok); s castle.seasons := castle.team_season(); v_t castle.teams; v_sid int := coalesce(s.id, 0);
begin
  select t.* into v_t from castle.teams t join castle.team_members m on m.team_id = t.id where m.sid = st.id and m.state = 'joined';
  return jsonb_build_object(
    'season', case when s.id is null then null else jsonb_build_object('id', s.id, 'name', s.name, 'startsAt', castle.ms(s.starts_at), 'endsAt', castle.ms(s.ends_at),
                'status', case when now() < s.starts_at then 'upcoming' when now() >= s.ends_at then 'ended' else 'active' end) end,
    'canPlay', not st.is_teacher and not st.is_admin,
    'team', case when v_t.id is null then null else jsonb_build_object('id', v_t.id, 'name', v_t.name, 'leader', v_t.leader = st.id,
      'score', (select coalesce(sum(castle.team_member_score(v_t.id, z.sid, v_sid)), 0)::int from (select distinct sid from castle.team_stints where team_id = v_t.id) z),
      'rank', (select tb.r from castle.team_board(v_sid) tb where tb.team_id = v_t.id),
      'members', (select coalesce(jsonb_agg(jsonb_build_object('name', x.name, 'grade', x.grade, 'state', m.state, 'leader', x.id = v_t.leader, 'me', x.id = st.id,
                    'score', castle.team_member_score(v_t.id, x.id, v_sid), 'id', x.id) order by (x.id = v_t.leader) desc, m.created_at), '[]')
                  from castle.team_members m join castle.students x on x.id = m.sid where m.team_id = v_t.id)) end,
    'invites', (select coalesce(jsonb_agg(jsonb_build_object('teamId', t.id, 'teamName', t.name, 'from', lx.name,
                  'size', (select count(*) from castle.team_members z where z.team_id = t.id and z.state = 'joined')) order by m.created_at), '[]')
                from castle.team_members m join castle.teams t on t.id = m.team_id join castle.students lx on lx.id = t.leader
                where m.sid = st.id and m.state = 'invited'),
    'total', (select count(*) from castle.team_board(v_sid)),
    'top', (select coalesce(jsonb_agg(jsonb_build_object('rank', tb.r, 'name', tb.name, 'score', tb.score, 'n', tb.n,
                  'members', (select string_agg(castle.mask_name(x.name), ', ' order by m.created_at) from castle.team_members m join castle.students x on x.id = m.sid where m.team_id = tb.team_id and m.state = 'joined'),
                  'me', v_t.id = tb.team_id) order by tb.r), '[]')
            from castle.team_board(v_sid) tb where tb.r <= 20));
end $$;

create or replace function castle.r_team_create(tok text, b jsonb) returns jsonb language plpgsql as $$
declare st castle.students := castle.stu(tok); v_name text := btrim(coalesce(b->>'name', '')); v_id int;
begin
  if st.is_teacher or st.is_admin then perform castle.fail(403, '학생만 팀을 만들 수 있습니다.'); end if;
  if char_length(v_name) < 2 or char_length(v_name) > 12 then perform castle.fail(400, '팀 이름은 2~12자로 입력하십시오.'); end if;
  if exists (select 1 from castle.team_members where sid = st.id and state = 'joined') then perform castle.fail(400, '이미 팀에 속해 있습니다.'); end if;
  if exists (select 1 from castle.teams where name = v_name) then perform castle.fail(400, '이미 사용 중인 팀 이름입니다.'); end if;
  insert into castle.teams (name, leader) values (v_name, st.id) returning id into v_id;
  insert into castle.team_members (team_id, sid, state) values (v_id, st.id, 'joined');
  insert into castle.team_stints (team_id, sid) values (v_id, st.id);
  delete from castle.team_members where sid = st.id and state = 'invited';
  return jsonb_build_object('ok', true);
end $$;

create or replace function castle.r_team_invite(tok text, b jsonb) returns jsonb language plpgsql as $$
declare st castle.students := castle.stu(tok); v_t castle.teams; v_to text := btrim(coalesce(b->>'id', ''));
begin
  select t.* into v_t from castle.teams t where t.leader = st.id;
  if v_t.id is null then perform castle.fail(403, '팀장만 초대할 수 있습니다.'); end if;
  if not exists (select 1 from castle.students x where x.id = v_to and not x.is_teacher and not x.is_admin) then perform castle.fail(404, '해당 아이디의 학생을 찾을 수 없습니다.'); end if;
  if v_to = st.id then perform castle.fail(400, '본인은 이미 팀에 속해 있습니다.'); end if;
  if exists (select 1 from castle.team_members where sid = v_to and state = 'joined') then perform castle.fail(400, '이미 다른 팀에 속한 학생입니다.'); end if;
  if exists (select 1 from castle.team_members where team_id = v_t.id and sid = v_to) then perform castle.fail(400, '이미 초대한 학생입니다.'); end if;
  if (select count(*) from castle.team_members where team_id = v_t.id) >= 4 then perform castle.fail(400, '팀은 최대 4명까지입니다. 초대 대기 인원도 정원에 포함됩니다.'); end if;
  insert into castle.team_members (team_id, sid, state) values (v_t.id, v_to, 'invited');
  return jsonb_build_object('ok', true);
end $$;

create or replace function castle.r_team_respond(tok text, b jsonb) returns jsonb language plpgsql as $$
declare st castle.students := castle.stu(tok); v_tid int := (b->>'teamId')::int;
begin
  if not exists (select 1 from castle.team_members where team_id = v_tid and sid = st.id and state = 'invited') then
    perform castle.fail(404, '초대가 없거나 이미 취소되었습니다.'); end if;
  if coalesce((b->>'accept')::boolean, false) then
    if exists (select 1 from castle.team_members where sid = st.id and state = 'joined') then perform castle.fail(400, '이미 팀에 속해 있습니다.'); end if;
    update castle.team_members set state = 'joined' where team_id = v_tid and sid = st.id;
    insert into castle.team_stints (team_id, sid) values (v_tid, st.id);
    delete from castle.team_members where sid = st.id and state = 'invited';
  else
    delete from castle.team_members where team_id = v_tid and sid = st.id and state = 'invited';
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- 팀원은 탈퇴, 팀장은 팀 해체
create or replace function castle.r_team_leave(tok text) returns jsonb language plpgsql as $$
declare st castle.students := castle.stu(tok); v_t castle.teams;
begin
  select t.* into v_t from castle.teams t join castle.team_members m on m.team_id = t.id where m.sid = st.id and m.state = 'joined';
  if v_t.id is null then perform castle.fail(404, '속한 팀이 없습니다.'); end if;
  if v_t.leader = st.id then delete from castle.teams where id = v_t.id;
  else
    update castle.team_stints set to_at = now() where team_id = v_t.id and sid = st.id and to_at is null;
    delete from castle.team_members where team_id = v_t.id and sid = st.id;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- 팀장이 대기 중인 초대를 취소
create or replace function castle.r_team_cancel(tok text, b jsonb) returns jsonb language plpgsql as $$
declare st castle.students := castle.stu(tok);
begin
  delete from castle.team_members m using castle.teams t
   where t.id = m.team_id and t.leader = st.id and m.sid = b->>'id' and m.state = 'invited';
  return jsonb_build_object('ok', true);
end $$;


-- ----- 로그인 없이 구경하기 (체험 모드): 포인트·기록은 저장하지 않고 문제만 보여 줌 -----
create or replace function castle.r_guest_start(b jsonb) returns jsonb language plpgsql as $$
declare v_tok text;
begin
  delete from castle.sessions where exp < now();
  if (select count(*) from castle.sessions where role = 'guest') >= 5000 then perform castle.fail(429, '지금은 체험 접속이 많습니다. 잠시 후 다시 시도해 주십시오.'); end if;
  v_tok := encode(extensions.gen_random_bytes(24), 'hex');
  insert into castle.sessions values (v_tok, 'guest', 'guest', now() + interval '3 hours');
  return jsonb_build_object('token', v_tok);
end $$;

create or replace function castle.r_guest_problem(tok text, b jsonb) returns jsonb language plpgsql as $$
declare p castle.problems; v_g text := nullif(b->>'grade', ''); v_min int := coalesce((b->>'minLevel')::int, 0);
        v_ex text[] := coalesce(array(select jsonb_array_elements_text(coalesce(b->'exclude', '[]'::jsonb))), '{}');
begin
  perform castle.auth(tok, 'guest');
  select * into p from castle.problems q where q.active and q.level >= v_min and (v_g is null or q.grade = v_g)
    and (v_g is null or castle.unit_ok(v_g, q.subject, q.unit_large, q.unit)) and not (q.id = any (v_ex)) order by random() limit 1;
  if not found then
    select * into p from castle.problems q where q.active and q.level >= v_min and (v_g is null or q.grade = v_g)
      and (v_g is null or castle.unit_ok(v_g, q.subject, q.unit_large, q.unit)) order by random() limit 1;
  end if;
  if not found then perform castle.fail(400, '지금은 이 학년에 풀 수 있는 문제가 없습니다. 다른 학년을 선택해 주십시오.'); end if;
  return jsonb_build_object('id', p.id, 'grade', p.grade, 'text', p.text, 'image', p.image, 'level', p.level,
                            'kind', case when p.answer ~ '^[ㄱ-ㅎ]+$' then 'set' else 'num' end);
end $$;

create or replace function castle.r_guest_pool(tok text, b jsonb) returns jsonb language plpgsql as $$
begin
  perform castle.auth(tok, 'guest');
  return jsonb_build_object('n', (select count(*) from castle.problems where active and level >= coalesce((b->>'minLevel')::int, 0)));
end $$;

create or replace function castle.r_guest_check(tok text, b jsonb) returns jsonb language plpgsql as $$
declare p castle.problems;
begin
  perform castle.auth(tok, 'guest');
  select * into p from castle.problems where id = b->>'id';
  if not found then perform castle.fail(400, '문제를 찾을 수 없습니다.'); end if;
  return jsonb_build_object('correct', castle.same(b->>'answer', p.answer), 'answer', p.answer, 'explanation', p.explanation,
                            'extra', p.extra, 'explImage', p.expl_image, 'level', p.level);
end $$;

-- 체험 모드 예시: 김송현 학생의 캐치유테스트 오답을 그대로 보여 준다 (이름은 내려주지 않음, 그 학생이 틀린 문항만 열림)
create or replace function castle.guest_sample_sid() returns text language sql stable as $$
  select s.id from castle.students s join castle.catchu_wrong w on w.sid = s.id where s.name = '김송현' order by w.round_id limit 1 $$;

create or replace function castle.r_guest_catchu(tok text) returns jsonb language plpgsql as $$
declare v_sid text := castle.guest_sample_sid();
begin
  perform castle.auth(tok, 'guest');
  return (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'title', r.title, 'date', r.date, 'grade', r.grade, 'scope', r.scope, 'total', r.total,
            'wrong', w.wrong, 'retestDate', null, 'stillWrong', null, 'have', to_jsonb(castle.catchu_have(r.id))) order by r.date desc nulls last, r.title), '[]')
          from castle.catchu_wrong w join castle.catchu_rounds r on r.id = w.round_id where w.sid = v_sid);
end $$;

create or replace function castle.r_guest_catchu_item(tok text, b jsonb) returns jsonb language plpgsql as $$
declare v_sid text := castle.guest_sample_sid(); v_no int := (b->>'no')::int; r castle.catchu_items;
begin
  perform castle.auth(tok, 'guest');
  if not exists (select 1 from castle.catchu_wrong w where w.round_id = b->>'roundId' and w.sid = v_sid and w.wrong @> to_jsonb(v_no)) then
    perform castle.fail(404, '해당 문항이 없습니다.');
  end if;
  select * into r from castle.catchu_items where round_id = b->>'roundId' and no = v_no;
  if not found then return jsonb_build_object('prob', '', 'expl', ''); end if;
  return jsonb_build_object('prob', r.prob, 'expl', r.expl);
end $$;

create or replace function castle.dispatch(p_path text, tok text, b jsonb) returns jsonb language plpgsql as $$
begin
  case p_path
    when 'login' then return castle.r_login(b);
    when 'register' then return castle.r_register(b);
    when 'guest/start' then return castle.r_guest_start(b);
    when 'guest/problem' then return castle.r_guest_problem(tok, b);
    when 'guest/pool' then return castle.r_guest_pool(tok, b);
    when 'guest/check' then return castle.r_guest_check(tok, b);
    when 'guest/catchu' then return castle.r_guest_catchu(tok);
    when 'guest/catchu_item' then return castle.r_guest_catchu_item(tok, b);
    when 'reset/request' then return castle.r_reset_request(b);
    when 'admin/resets' then return castle.r_admin_resets(tok);
    when 'logout' then return castle.r_logout(tok);
    when 'setpw' then return castle.r_setpw(tok, b);
    when 'me' then return castle.r_me(tok);
    when 'rank' then return castle.r_rank(tok);
    when 'preview' then return castle.r_preview(tok, b);
    when 'skip' then return castle.r_skip(tok);
    when 'accept' then return castle.r_accept(tok);
    when 'submit' then return castle.r_submit(tok, b);
    when 'notes' then return castle.r_notes(tok);
    when 'note/add' then return castle.r_note_add(tok, b);
    when 'note/update' then return castle.r_note_update(tok, b);
    when 'note/del' then return castle.r_note_del(tok, b);
    when 'history' then return castle.r_history(tok);
    when 'stats' then return castle.r_stats(tok);
    when 'catchu' then return castle.r_catchu(tok);
    when 'catchu/item' then return castle.r_catchu_item(tok, b);
    when 'notices' then return castle.r_notices(tok);
    when 'admin/notice/save' then return castle.r_admin_notice_save(tok, b);
    when 'admin/notice/del' then return castle.r_admin_notice_del(tok, b);
    when 'admin/students' then return castle.r_admin_students(tok);
    when 'admin/addstudents' then return castle.r_admin_addstudents(tok, b);
    when 'admin/points' then return castle.r_admin_points(tok, b);
    when 'admin/resetpw' then return castle.r_admin_resetpw(tok, b);
    when 'admin/deletestudent' then return castle.r_admin_deletestudent(tok, b);
    when 'admin/adminpw' then return castle.r_admin_adminpw(tok, b);
    when 'switch' then return castle.r_switch(tok, b);
    when 'season/info' then return castle.r_season_info(tok, b);
    when 'season/start' then return castle.r_season_start(tok, b);
    when 'team/info' then return castle.r_team_info(tok);
    when 'friend/list' then return castle.r_friend_list(tok);
    when 'friend/add' then return castle.r_friend_add(tok, b);
    when 'friend/respond' then return castle.r_friend_respond(tok, b);
    when 'friend/remove' then return castle.r_friend_remove(tok, b);
    when 'team/create' then return castle.r_team_create(tok, b);
    when 'team/invite' then return castle.r_team_invite(tok, b);
    when 'team/respond' then return castle.r_team_respond(tok, b);
    when 'team/leave' then return castle.r_team_leave(tok);
    when 'team/cancel' then return castle.r_team_cancel(tok, b);
    when 'roster' then return castle.r_roster(tok);
    when 'admin/rosters' then return castle.r_admin_rosters(tok);
    when 'admin/roster_edit' then return castle.r_admin_roster_edit(tok, b);
    when 'admin/studentmeta' then return castle.r_admin_studentmeta(tok, b);
    when 'admin/seasons' then return castle.r_admin_seasons(tok);
    when 'admin/season_save' then return castle.r_admin_season_save(tok, b);
    when 'admin/season_delete' then return castle.r_admin_season_delete(tok, b);
    when 'admin/cfg' then return castle.r_admin_cfg(tok);
    when 'admin/setcfg' then return castle.r_admin_setcfg(tok, b);
    when 'admin/problems' then return castle.r_admin_problems(tok);
    when 'admin/units' then return castle.r_admin_units(tok);
    when 'admin/setunits' then return castle.r_admin_setunits(tok, b);
    when 'admin/problem' then return castle.r_admin_problem(tok, b);
    when 'admin/import' then return castle.r_admin_import(tok, b);
    when 'admin/deleteproblem' then return castle.r_admin_deleteproblem(tok, b);
    when 'admin/deleteall' then return castle.r_admin_deleteall(tok, b);
    when 'admin/log' then return castle.r_admin_log(tok);
    when 'admin/suspects' then return castle.r_admin_suspects(tok, b);
    else perform castle.fail(404, '없는 기능입니다.');
  end case;
  return null;
end $$;

create or replace function public.castle_api(p_path text, p_token text default null, p_body jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = castle, public, extensions as $$
begin
  return castle.dispatch(p_path, p_token, coalesce(p_body, '{}'::jsonb));
end $$;

-- 내부 함수와 표는 외부(anon)가 쓸 수 없게 막습니다 (castle_api 가 소유자 권한으로 대신 부릅니다).
revoke all on schema castle from public, anon, authenticated;
revoke all on all tables in schema castle from public, anon, authenticated;
revoke all on all functions in schema castle from public, anon, authenticated;
revoke all on function public.castle_api(text, text, jsonb) from public;
grant execute on function public.castle_api(text, text, jsonb) to anon, authenticated;

-- ---------- 샘플 문제 (처음 한 번만. 관리자 화면에서 지우세요) ----------
insert into castle.problems (id, grade, text, answer, explanation, extra)
select * from (values
  ('sample01', '중1', '$x = 3$일 때, $2x + 5$의 값을 구하시오.', '11', '$x$에 $3$을 넣으면 $2 \times 3 + 5 = 11$', ''),
  ('sample02', '중2', '일차함수 $y = 2x - 1$의 그래프가 점 $(a,\ 7)$을 지날 때, $a$의 값을 구하시오.', '4',
   '$y = 7$을 대입하면 $7 = 2a - 1$, $2a = 8$ 이므로 $a = 4$', ''),
  ('sample03', '중3', '$(\sqrt{8} + \sqrt{2})^2$의 값을 구하시오.', '18',
   '$\sqrt{8} = 2\sqrt{2}$ 이므로 $\sqrt{8} + \sqrt{2} = 3\sqrt{2}$, 제곱하면 $(3\sqrt{2})^2 = 18$.',
   '[변형 풀이] 원래 문제는 $\sqrt{8} + \sqrt{2}$ 의 값($3\sqrt{2}$)을 구하는 문제였습니다. 답이 숫자만 되도록 제곱한 값을 묻는 문제로 바꾸었으며, $(3\sqrt{2})^2 = 9 \times 2 = 18$ 입니다.'),
  ('sample04', '고1', '이차방정식 $x^2 - 5x + 6 = 0$의 두 근의 합을 구하시오.', '5',
   '근과 계수의 관계에서 두 근의 합은 $-\dfrac{-5}{1} = 5$.', ''),
  ('sample05', '고2', '등차수열 $\{a_n\}$에서 $a_1 = 3$, 공차가 $4$일 때, $a_{10}$의 값을 구하시오.', '39',
   '$a_{10} = 3 + 9 \times 4 = 39$', ''),
  ('sample06', '고3', '함수 $f(x) = x^3 - 3x$의 극댓값을 구하시오.', '2',
   '$f''(x) = 3x^2 - 3 = 0$ 에서 $x = -1$ 일 때 극대이므로 $f(-1) = -1 + 3 = 2$', '')
) v (id, grade, text, answer, explanation, extra)
where not exists (select 1 from castle.problems);

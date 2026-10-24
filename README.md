# 캐슬 포인트 헌터

서버 없이 **Supabase + 정적 화면(GitHub Pages)** 으로 돌아갑니다.

## 구성
- `index.html` : 화면 전체 (학생 + 관리자)
- `config.js` : Supabase 주소와 anon 키 (공개 키라서 올려도 됩니다. service_role 키는 넣지 마세요)
- `supabase_setup.sql` : Supabase SQL Editor 에서 한 번 실행. 표·규칙 함수·샘플 문제 생성
  - 정답·비밀번호·포인트 계산은 전부 Supabase 안(castle 스키마)에 있고, 화면은 `castle_api` 함수 하나만 부를 수 있습니다.
  - 관리자 비밀번호 설정: `select castle.init_admin('원하는비밀번호');`

## 규칙 값
관리자 화면 > "규칙 값" 탭에서 바로 바꿉니다 (미리보기·풀기 포인트, 보상, 제한시간, 아침 2배 시간, N문제째부터 2배).

## 메모
- 아침 2배와 15문제 2배는 겹쳐도 2배까지만 적용됩니다.
- 10초 안에 고르지 않으면 학년 선택 화면으로 돌아갑니다(미리보기 10P는 차감).
- `_옛_Node서버/` 는 Supabase 로 바꾸기 전의 Node 서버 버전(보관용, 저장소에는 올리지 않음).
# 캐슬 포인트 헌터

## 실행
`시작.bat` 더블클릭 → http://localhost:3000
관리자 아이디 `admin` / 초기 비밀번호 `castle1234!` (관리자 화면 > 비밀번호 탭에서 변경)

## 규칙 값
관리자 화면 > "규칙 값" 탭에서 바로 바꿉니다 (미리보기·풀기 포인트, 보상, 제한시간, 아침 2배 시간, N문제 2배).

## 데이터 저장
- 기본: `data/db.json` 한 파일(학원 PC에서 돌릴 때). 이 파일만 백업하면 됩니다.
- 무료 서버(Render 등)는 재시작하면 파일이 사라지므로 Supabase 에 저장합니다.
  1. Supabase > SQL Editor 에 `supabase_setup.sql` 내용을 붙여넣고 Run (표 1개 생성)
  2. 서버 환경변수 `SUPABASE_URL`(프로젝트 주소), `SUPABASE_SERVICE_KEY`(service_role 키) 설정
  3. service_role 키는 비밀번호와 같습니다. GitHub 에 올리거나 남에게 알려주지 마세요.
- 그 밖의 환경변수: `ADMIN_PASSWORD`(처음 관리자 비밀번호), `PORT`, `DATA_DIR`.

## 배포 메모
- GitHub에 올릴 때 `.gitignore` 가 `data/`, `tools/` 를 제외합니다. `render.yaml` 로 Render 무료 웹서비스를 만들 수 있습니다.
- 무료 서버는 15분 접속이 없으면 잠듭니다. `/api/health` 를 5분마다 호출하는 무료 모니터(UptimeRobot 등)로 깨워 둘 수 있습니다.
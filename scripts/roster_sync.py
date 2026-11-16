#!/usr/bin/env python3
"""구글 시트 명단 → 헌터스 학생 계정 (catchu_sync.py 보다 먼저 돈다).

시트: 「[캐슬MA] 2026 전체인원」의 이번 달 탭(예: 2611월 = 2026년 11월). 이번 달 탭이 없으면 가장 최근 'YYMM월' 탭.
  - 반마다 3칸: 이름 | 학교+학년(예 간재울중1) | 날짜. '이름' 칸 오른쪽에 '학교+중/고+학년' 이 있는 칸만 학생으로 본다.
  - 빨간 글씨 = 퇴원 → 헌터스에서 로그인만 막음(기록은 남김). 다시 검은 글씨가 되면 풀림.
  - 헌터스 아이디 = 학교+중/고+이름(이름 끝 숫자는 뗌). 숫자를 뗐더니 같은 아이디가 되는 서로 다른 학생은 건드리지 않음.
  - 새 학생: 처음 비밀번호 0000, 첫 로그인 때 바꾸게 함.

환경 변수: GOOGLE_SA_JSON(구글 로봇 계정 키 JSON), ROSTER_SHEET_ID(시트 주소의 /d/ 와 /edit 사이), HUNTERS_URL, HUNTERS_SERVICE_KEY
로그에는 숫자만 출력한다(공개 저장소).
"""
import datetime
import json
import os
import re
import sys

import requests

sys.path.insert(0, os.path.dirname(__file__))
from catchu_sync import Supa, env  # noqa: E402

DRY = os.environ.get("DRY_RUN") == "1"
SG = re.compile(r"^([가-힣]+?)(중|고)([1-3])$")
NAME = re.compile(r"^[가-힣]{2,5}[0-9]?$")


def google_token(sa_json):
    from google.oauth2 import service_account
    from google.auth.transport.requests import Request
    cred = service_account.Credentials.from_service_account_info(
        json.loads(sa_json), scopes=["https://www.googleapis.com/auth/spreadsheets.readonly"])
    cred.refresh(Request())
    return cred.token


def pick_tab(titles, today):
    want = f"{today:%y%m}월"
    if want in titles:
        return want
    months = sorted(t for t in titles if re.fullmatch(r"\d{4}월", t))
    return months[-1] if months else None


def is_red(cell):
    c = (((cell.get("effectiveFormat") or {}).get("textFormat") or {}).get("foregroundColor") or {})
    return c.get("red", 0) >= 0.7 and c.get("green", 0) <= 0.35 and c.get("blue", 0) <= 0.35


def parse_grid(rows):
    """rows: rowData 목록 → {아이디: {name, grade, left}}"""
    seen, raw_names = {}, {}
    for r in rows:
        vals = r.get("values") or []
        for i in range(len(vals) - 1):
            name = (vals[i].get("formattedValue") or "").strip()
            sg = (vals[i + 1].get("formattedValue") or "").replace(" ", "").strip()
            m = SG.match(sg)
            if not m or not NAME.match(name):
                continue
            base = re.sub(r"[0-9]+$", "", name)
            sid = m.group(1) + m.group(2) + base
            raw_names.setdefault(sid, set()).add(name)
            cur = seen.setdefault(sid, {"id": sid, "name": base, "grade": m.group(2) + m.group(3), "left": True})
            if not is_red(vals[i]):
                cur["left"] = False  # 한 번이라도 검은 글씨면 다니는 학생 (수업 2개 듣는 학생)
                cur["grade"] = m.group(2) + m.group(3)
    ambiguous = {sid for sid, names in raw_names.items() if len(names) > 1}
    return [v for k, v in seen.items() if k not in ambiguous], len(ambiguous)


def main():
    sa = os.environ.get("GOOGLE_SA_JSON", "").strip()
    sheet = os.environ.get("ROSTER_SHEET_ID", "").strip()
    if not sa or not sheet:
        print("명단 연동: 구글 로봇 계정 키 또는 시트 ID 가 아직 없어 건너뜁니다.")
        return
    h = Supa(env("HUNTERS_URL"), env("HUNTERS_SERVICE_KEY"))
    tok = google_token(sa)
    gh = {"Authorization": f"Bearer {tok}"}
    base = f"https://sheets.googleapis.com/v4/spreadsheets/{sheet}"
    meta = requests.get(base, params={"fields": "sheets.properties.title"}, headers=gh, timeout=60)
    meta.raise_for_status()
    titles = [s["properties"]["title"] for s in meta.json().get("sheets", [])]
    today = datetime.datetime.utcnow() + datetime.timedelta(hours=9)
    tab = pick_tab(titles, today)
    if not tab:
        print("::warning::명단 시트에서 'YYMM월' 탭을 찾지 못했습니다.")
        return
    r = requests.get(base, headers=gh, timeout=120, params={
        "ranges": f"'{tab}'", "includeGridData": "true",
        "fields": "sheets.data.rowData.values(formattedValue,effectiveFormat.textFormat.foregroundColor)"})
    r.raise_for_status()
    rows = []
    for s in r.json().get("sheets", []):
        for d in s.get("data", []):
            rows += d.get("rowData", []) or []
    people, amb = parse_grid(rows)
    n_left = sum(1 for p in people if p["left"])
    print(f"명단 탭 {tab}: 학생 {len(people)}명 (퇴원 표시 {n_left}명), 같은 이름이라 건너뜀 {amb}건")
    if DRY:
        print("DRY_RUN: 헌터스 계정은 바꾸지 않았습니다.")
        return
    res = h.rpc("roster_sync", {"p": people})
    print(f"헌터스 계정: {json.dumps(res, ensure_ascii=False)}")


if __name__ == "__main__":
    main()

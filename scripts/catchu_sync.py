#!/usr/bin/env python3
"""캐치유테스트 오답 + 문항 이미지 자동 연동 (KMMS → 헌터스).

GitHub Actions 에서 매일 한 번 돈다 (.github/workflows/catchu-sync.yml).
  1. KMMS(public.records) 에서 '주차' 정기 회차, 학생, 채점 결과, 재시험 결과를 읽는다.
  2. 헌터스 학생 아이디(학교+이름)로 맞춰 catchu_import 로 넣는다 (upsert, 여러 번 돌려도 안전).
  3. 문항 이미지가 아직 없는 회차는 KMMS 비공개 보관함의 시험지 PDF 를 받아
     문항별 문제·해설 이미지(webp)를 잘라 catchu_items 에 넣는다 (이미 있는 이미지는 덮어쓰지 않음).

공개 저장소라 실행 기록(로그)이 누구에게나 보인다 → 학생 이름·문항 내용은 절대 출력하지 않고 숫자만 출력한다.

환경 변수 (GitHub → Settings → Secrets and variables → Actions):
  KMMS_URL, KMMS_SERVICE_KEY        캐치유(KMMS) Supabase 주소와 secret(service_role) 키
  HUNTERS_URL, HUNTERS_SERVICE_KEY  헌터스 Supabase 주소와 secret(service_role) 키
옵션:
  DRY_RUN=1        헌터스에 쓰지 않고 숫자만 보고
  FORCE_IMAGES=1   이미 이미지가 있는 회차도 다시 잘라서 덮어씀
  SINCE=2026-10-23 이 날짜 이후 회차만
"""
import base64
import io
import json
import os
import re
import sys

import requests

SINCE = os.environ.get("SINCE", "2026-10-23")
DRY = os.environ.get("DRY_RUN") == "1"
FORCE_IMAGES = os.environ.get("FORCE_IMAGES") == "1"
# 퇴원생 등 가져오지 않을 학생 이름 (쉼표로 구분). 공개 저장소라 이름은 코드에 쓰지 않고 비밀 값 EXCLUDED_NAMES 로만 받는다.
EXCLUDED_NAMES = {n.strip() for n in os.environ.get("EXCLUDED_NAMES", "").split(",") if n.strip()}


def env(name):
    v = os.environ.get(name, "").strip()
    if not v:
        print(f"::error::{name} 비밀 값이 없습니다. 저장소 Settings → Secrets 에 넣어 주세요.")
        sys.exit(1)
    return v.rstrip("/")


class Supa:
    def __init__(self, url, key):
        self.url, self.key = url, key
        self.h = {"apikey": key, "Authorization": f"Bearer {key}"}

    def select(self, table, params, schema="public"):
        out, start, step = [], 0, 1000
        while True:
            h = dict(self.h, **{"Accept-Profile": schema, "Range": f"{start}-{start + step - 1}"})
            r = requests.get(f"{self.url}/rest/v1/{table}", params=params, headers=h, timeout=60)
            r.raise_for_status()
            rows = r.json()
            out += rows
            if len(rows) < step:
                return out
            start += step

    def rpc(self, fn, body):
        h = dict(self.h, **{"Content-Type": "application/json"})
        r = requests.post(f"{self.url}/rest/v1/rpc/{fn}", data=json.dumps(body), headers=h, timeout=120)
        if r.status_code >= 300:
            raise RuntimeError(f"{fn} 실패 ({r.status_code}): {r.text[:300]}")
        return r.json() if r.text else None

    def download(self, bucket, path):
        r = requests.get(f"{self.url}/storage/v1/object/{bucket}/{path}", headers=self.h, timeout=120)
        r.raise_for_status()
        return r.content


# ---------------------------------------------------------------- KMMS 읽기
def hunters_sid(st):
    """KMMS 학생 → 헌터스 아이디 (학교+이름). 인수인계 10-3 규칙."""
    school = (st.get("school") or "").strip()
    grade = (st.get("grade") or "").strip()
    if not re.search(r"[고중]$", school):
        school += "중" if grade.startswith("중") else "고"
    return school + re.sub(r"[0-9]+$", "", (st.get("name") or "").strip())


def load_kmms(k):
    recs = k.select("records", {"select": "collection,id,data", "deleted": "is.false",
                                "collection": "in.(rounds,students,results,retests)"})
    by = {"rounds": [], "students": [], "results": [], "retests": []}
    for r in recs:
        d = r.get("data") or {}
        d.setdefault("id", r.get("id"))
        by[r["collection"]].append(d)

    rounds = [d for d in by["rounds"]
              if "주차" in (d.get("title") or "") and "입학" not in (d.get("title") or "")
              and (d.get("date") or "") >= SINCE]
    rids = {d["id"] for d in rounds}

    students = {}
    for s in by["students"]:
        if (s.get("class") or "") == "입학테스트" or (s.get("name") or "").strip() in EXCLUDED_NAMES:
            continue
        students[s["id"]] = s

    # 같은 헌터스 아이디로 겹치는 KMMS 학생(동명이인)은 안전하게 건너뜀 (인수인계 10-3)
    sid_count = {}
    for s in students.values():
        sid_count[hunters_sid(s)] = sid_count.get(hunters_sid(s), 0) + 1

    latest_retest = {}
    for rt in by["retests"]:
        key = (rt.get("roundId"), rt.get("studentId"))
        if key[0] in rids and (key not in latest_retest or (rt.get("date") or "") > (latest_retest[key].get("date") or "")):
            latest_retest[key] = rt

    rows, ambiguous = [], 0
    for res in by["results"]:
        if res.get("roundId") not in rids or res.get("studentId") not in students:
            continue
        sid = hunters_sid(students[res["studentId"]])
        if sid_count.get(sid, 0) > 1:
            ambiguous += 1
            continue
        rt = latest_retest.get((res["roundId"], res["studentId"]))
        rows.append({"roundId": res["roundId"], "sid": sid, "wrong": res.get("wrong") or [],
                     "retestDate": (rt or {}).get("date"), "stillWrong": (rt or {}).get("stillWrong")})

    payload = {"rounds": [{"id": d["id"], "title": d.get("title"), "date": d.get("date"), "grade": d.get("grade") or "",
                           "total": int(d.get("total") or 0)} for d in rounds],
               "rows": rows}
    return payload, rounds, ambiguous


# ---------------------------------------------------------------- PDF 자르기
DPI = 200
FOOTER_PT = 56


def _is_colored(color_int):
    r, g, b = (color_int >> 16) & 255, (color_int >> 8) & 255, color_int & 255
    return max(r, g, b) - min(r, g, b) > 40


def _spans(page):
    out = []
    for b in page.get_text("dict")["blocks"]:
        for l in b.get("lines", []):
            for s in l["spans"]:
                t = s["text"].strip()
                if t:
                    x0, y0, x1, y1 = s["bbox"]
                    out.append({"t": t, "x": x0, "x1": x1, "top": y0, "bot": y1, "size": s["size"], "color": s["color"]})
    return out


def _marks(spans, width, min_size, need_color):
    """문항 번호표: 열 왼쪽 가장자리에 있는 큰(또는 색 있는) 1~2자리 숫자."""
    half = width / 2
    near = lambda x: (14 <= x <= 70) or (half + 2 <= x <= half + 50)
    ms = []
    for s in spans:
        if not re.fullmatch(r"0?\d|[1-9]\d", s["t"]) or s["size"] < min_size or not near(s["x"]):
            continue
        if need_color and not _is_colored(s["color"]):
            continue
        ms.append(dict(s, num=int(s["t"]), col=0 if s["x"] < half else 1))
    return ms


def _regions(page, marks, spans, skip_head):
    """번호표 위치부터 같은 열의 다음 번호 직전까지. skip_head 면 문제 위 '| 유형명' 머리글을 뺀다 (retest.js 와 같은 규칙)."""
    W, H = page.rect.width, page.rect.height
    half = W / 2
    for m in marks:
        m["headTop"] = None
        if skip_head:
            pipes = [s for s in spans if s["t"].startswith("|") and abs(s["x"] - m["x"]) < 14 and s["top"] < m["top"] - 4 and m["top"] - s["top"] < 70]
            if pipes:
                m["headTop"] = min(s["top"] for s in pipes) - 2
    out = {}
    for m in marks:
        same = sorted([o for o in marks if o["col"] == m["col"] and o["top"] > m["top"] + 10], key=lambda o: o["top"])
        nxt = same[0] if same else None
        bottom = (nxt["headTop"] - 2 if nxt and nxt["headTop"] is not None else nxt["top"] - 6) if nxt else H - FOOTER_PT
        left, right = (24, half - 4) if m["col"] == 0 else (half + 4, W - 24)
        out.setdefault(m["num"], (left, max(0, m["top"] - 2), right, bottom))  # -2: 위쪽 출처 줄이 걸치지 않게
    return out


def _render(page, rect):
    import fitz
    from PIL import Image
    pix = page.get_pixmap(dpi=DPI, clip=fitz.Rect(*rect), alpha=False)
    img = Image.frombytes("RGB", (pix.width, pix.height), pix.samples)
    # 흰 여백 줄이기
    gray = img.convert("L").point(lambda v: 0 if v > 235 else 255)
    bbox = gray.getbbox()
    if bbox:
        pad = 12
        img = img.crop((max(0, bbox[0] - pad), max(0, bbox[1] - pad), min(img.width, bbox[2] + pad), min(img.height, bbox[3] + pad)))
    buf = io.BytesIO()
    img.save(buf, "WEBP", quality=82)
    return "data:image/webp;base64," + base64.b64encode(buf.getvalue()).decode()


def crop_pdf(pdf_bytes, total):
    """시험지 PDF → {번호: {'prob': dataURI, 'expl': dataURI}}"""
    import fitz
    doc = fitz.open(stream=pdf_bytes, filetype="pdf")
    probs, expls = {}, {}
    for page in doc:
        spans = _spans(page)
        texts = {s["t"].replace(" ", "") for s in spans}
        if any("빠른정답" in t for t in texts):
            continue  # 빠른정답 표 쪽 (작은 번호가 표로 늘어서 있어 잘못 잘림)
        # 해설 쪽: 단독 글자 '해설'이 있는 쪽. 문제 쪽에도 '정답률 NN%' 가 있으므로 '정답'으로 판단하면 안 됨
        is_expl = "해설" in texts
        if is_expl:
            ms = _marks(spans, page.rect.width, 15, True)
            for n, rect in _regions(page, ms, spans, False).items():
                if 1 <= n <= max(total, 1) and n not in expls:
                    expls[n] = (page.number, rect)
        else:
            ms = _marks(spans, page.rect.width, 15, False)
            for n, rect in _regions(page, ms, spans, True).items():
                if 1 <= n <= max(total, 1) and n not in probs:
                    probs[n] = (page.number, rect)
    items = {}
    for n in sorted(set(probs) | set(expls)):
        it = {}
        if n in probs:
            it["prob"] = _render(doc[probs[n][0]], probs[n][1])
        if n in expls:
            it["expl"] = _render(doc[expls[n][0]], expls[n][1])
        items[n] = it
    return items


def split_path(p):
    p = (p or "").lstrip("/")
    if p.startswith("exams/"):
        return "exams", p[len("exams/"):]
    return "exams", p


# ---------------------------------------------------------------- 실행
def main():
    k = Supa(env("KMMS_URL"), env("KMMS_SERVICE_KEY"))
    h = Supa(env("HUNTERS_URL"), env("HUNTERS_SERVICE_KEY"))

    payload, rounds, ambiguous = load_kmms(k)
    print(f"KMMS: 회차 {len(payload['rounds'])}개, 학생별 결과 {len(payload['rows'])}건, 동명이인으로 건너뜀 {ambiguous}건")

    if DRY:
        print("DRY_RUN: 헌터스에는 쓰지 않았습니다.")
    else:
        r = h.rpc("catchu_sync_import", {"j": payload})
        print(f"헌터스 반영: {json.dumps(r, ensure_ascii=False)}")
        if r and r.get("skipped"):
            print(f"::warning::헌터스에 계정이 없는 학생 {r['skipped']}건은 건너뛰었습니다 (관리자 화면에서 확인).")

    have = {} if DRY else {x["round_id"]: x for x in (h.rpc("catchu_sync_have", {}) or [])}
    made = no_pdf = failed = 0
    for rd in rounds:
        total = int(rd.get("total") or 0)
        got = have.get(rd["id"], {})
        if not FORCE_IMAGES and total and got.get("probs", 0) >= total and got.get("expls", 0) >= total:
            continue
        paths = [p for p in (rd.get("examPath"), rd.get("retestPath")) if p]
        if not paths:
            no_pdf += 1
            continue
        items = {}
        for p in paths:
            try:
                bucket, key = split_path(p)
                part = crop_pdf(k.download(bucket, key), total)
            except Exception as e:  # 회차 하나가 실패해도 나머지는 계속
                print(f"::warning::회차 {rd['id']} 시험지 처리 실패: {type(e).__name__}")
                continue
            for n, it in part.items():
                cur = items.setdefault(n, {})
                for kk, v in it.items():
                    cur.setdefault(kk, v)
        if not items:
            failed += 1
            continue
        np_, ne = sum(1 for v in items.values() if "prob" in v), sum(1 for v in items.values() if "expl" in v)
        print(f"회차 {rd['id']}: 문항 {total}개 중 문제 이미지 {np_}개, 해설 이미지 {ne}개")
        if DRY:
            continue
        rows = [{"no": n, "prob": v.get("prob", ""), "expl": v.get("expl", "")} for n, v in sorted(items.items())]
        for i in range(0, len(rows), 6):  # 요청 하나를 작게
            h.rpc("catchu_sync_items", {"p_round": rd["id"], "p_items": rows[i:i + 6], "p_overwrite": FORCE_IMAGES})
        made += 1
    print(f"이미지: 새로 만든 회차 {made}개, 시험지 PDF 없는 회차 {no_pdf}개, 문항을 못 찾은 회차 {failed}개")


if __name__ == "__main__":
    main()

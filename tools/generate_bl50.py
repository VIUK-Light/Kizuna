#!/usr/bin/env python3
"""Generate 50 BL story templates with the Gemma 4 31B API.

// このスクリプトは、アプリ内の GeneratedStoryTemplate と同じJSON形を保つ。
// APIキーは環境変数から読むだけで、ファイルには保存しない。
// 途中で止まっても、既に保存したJSONを再利用して続きから再開できる。
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import os
import re
import ssl
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

try:
    import certifi
except ImportError:  # // 実行環境にcertifiがない場合は標準の証明書ストアを使う。
    certifi = None


MODEL = "gemma-4-31b-it"
ENDPOINT = f"https://generativelanguage.googleapis.com/v1beta/models/{MODEL}:generateContent"
TLS_CONTEXT = ssl.create_default_context(cafile=certifi.where()) if certifi else ssl.create_default_context()

# // 検索で見つかった需要の高い軸を、重複しないように50テーマへ展開する。
THEMES = [
    "同級生の再会と初恋のやり直し",
    "生徒会長と無口な副会長の秘密",
    "寮のルームメイトと期間限定の同居",
    "先輩バリスタと不器用な常連客",
    "幼なじみ二人の家業再建",
    "会社の同期と社内コンペの相棒",
    "冷徹な上司と新入社員の夜間プロジェクト",
    "人気俳優と無名スタイリスト",
    "舞台俳優と代役になった脚本家",
    "配信者と匿名の古参視聴者",
    "探偵と依頼人になった元恋人",
    "刑事と記者の未解決事件",
    "美術館学芸員と盗難絵画の鑑定士",
    "書店員と毎週同じ本を買う客",
    "消防士と避難所で再会した幼なじみ",
    "医師と救急救命士の夜勤",
    "料理人と味覚を失った評論家",
    "音楽教師と路上ピアニスト",
    "写真家と被写体になった天文研究者",
    "スポーツトレーナーと怪我から復帰する選手",
    "異世界の騎士団長と召喚された外交官",
    "身代わり婚を選んだ王子と隣国の将軍",
    "魔法学校の研究者と落ちこぼれの天才",
    "竜騎士と人間の通訳官",
    "呪いを解く薬師と呪われた貴族",
    "砂漠都市の商人と護衛隊長",
    "海洋国家の王子と海賊船の航海士",
    "記憶を失った英雄と彼を知る従者",
    "聖職者と魔王軍の元参謀",
    "辺境の領主と王都から来た監査官",
    "宇宙船の船長と航法AIの人間化体",
    "月面コロニーの医療技師と地球からの調査員",
    "時間を止められる青年と時間泥棒",
    "アンドロイド整備士と廃棄予定の試作機",
    "終末世界の配達人と避難所の管理者",
    "夢を共有する研究者と被験者",
    "雪山の山小屋管理人と遭難した気象学者",
    "港町の灯台守と帰港しない船の船長",
    "旅する劇団の座長と音響技師",
    "古書に宿る精霊と修復師",
    "オフィスビルの警備員と深夜の清掃員",
    "フリーランス編集者と締切を守らない作家",
    "結婚相談所のカウンセラーと恋愛嫌いの顧客",
    "同じマンションの隣人と消えた猫探し",
    "元ライバルの共同起業と再出発",
    "偽装恋人契約を結んだ二人の本気",
    "秘密を共有する義兄弟ではない家族の再生",
    "失踪した親友を探す二人のバディ",
    "過去の手紙でつながる現代と大正の青年",
    "町の祭りを守る神職と地域おこし担当者",
]

SYSTEM_PROMPT = """
あなたはVIUK 絆のストーリー作成エンジンです。
 ガチBL向けの物語テンプレートを1つ、JSONオブジェクトだけで出力してください。
Markdown、コードフェンス、説明文は禁止です。

重要な条件:
- 登場人物は全員成人（20歳以上）。未成年、教師と生徒、近親関係、強制的な性的描写は禁止。
- 恋愛はBL（男性同士）だが、露骨な性描写は避け、感情・葛藤・信頼の形成を中心にする。
- 友情や男性キャラがいるだけの話は禁止。少なくとも2人の成人男性の間に、相互の恋愛感情・恋愛上の障害・関係が進むきっかけを必ず設定する。
- 需要の軸として、学園の青春、幼なじみ・再会、同居、オフィスラブ、芸能界、オメガバース風の階級設定、異世界・転生、主従・身分差、溺愛・執着、すれ違い・再起を適度に混ぜる。
- タイトル、舞台、関係性、導入のフックを明確にし、既存の物語と重複しにくくする。
- 2〜4人のキャラを作る。全員に imageKey を付け、画像本体は作らず後から差し替え可能にする。
- imageKey は bl-XXX-main-1 のような一意な値。各キャラの画像プロンプトは imagePrompts に入れる。

必須JSON schema:
{
  "story": {"title":"string","shortDescription":"string","genre":"school_romance | slice_of_life | detective | fantasy_rpg | sci_fi | club_activity | original_freeform","relationshipGenre":"bl","worldSetting":"string","userRole":"string","openingScene":"string","storyGoal":"string","mood":"string","tags":["string"]},
  "initialScene": {"title":"string","location":"string","timeOfDay":"string","mood":"string","sceneGoal":"string","conflict":"string","summary":"string"},
  "characters": [{"name":"string","displayName":"string","shortDescription":"string","category":"school_romance | classmate | senpai_kouhai | best_friend | detective | fantasy_rpg | sci_fi | club_activity | original_freeform","relationshipGenre":"bl","personality":"string","speakingStyle":"string","background":"string","relationshipToUser":"string","scenario":"string","firstMessage":"名前: 本文","tags":["string"],"rules":["string"],"safetyRules":["string"],"storyRole":"main | friend | mentor | rival | secondary","introductionTiming":"opening | early | middle | late | optional","activeInInitialScene":true,"importance":1.0,"storyRelationshipToUser":"string","imageKey":"string"}],
  "relationships": [{"from":"displayName","to":"displayName","relationshipType":"friend | classmate | senior_junior | rival | mentor","description":"string","trust":0.5,"tension":0.2}],
  "generationRules":["string"],
  "imagePrompts":[{"imageKey":"string","prompt":"成人男性キャラクターの立ち絵用プロンプト。服装、雰囲気、表情、色、構図を具体化。性的・暴力的な露出は禁止。"}]
}
""".strip()


def extract_json(text: str) -> dict:
    # // APIがコードフェンスを返しても、JSON本体だけを安全に取り出す。
    cleaned = re.sub(r"```(?:json)?", "", text, flags=re.IGNORECASE).replace("```", "").strip()
    start = cleaned.find("{")
    end = cleaned.rfind("}")
    if start < 0 or end <= start:
        raise ValueError("JSON object was not found in API response")
    return json.loads(cleaned[start : end + 1])


def call_api(api_key: str, theme: str, index: int, retries: int = 8) -> dict:
    user_prompt = f"""
今回のテーマ（{index:02d}/50）: {theme}

このテーマを軸に、需要のあるBL要素（再会、執着、すれ違い、身分差、仕事仲間、冒険など）を1〜2個だけ組み合わせてください。
ユーザー役は「物語の中心にいる成人の主人公」。作品ごとに職業・身分・目的を1つ決め、受け/攻めなどの固定ラベルは使わない。
userRole はユーザーが自分で演じる立場を一文で示す。relationshipToUser は相手から見たユーザーとの関係を書く。
キャラクターはユーザーの代わりに主人公にならず、ユーザーが選択・発話できる余白を残す。
キャラの名前は日本語で、説明は短く具体的に。
imagePrompts の配列は characters と同じ人数にし、imageKey を完全一致させてください。
""".strip()
    payload = {
        "system_instruction": {"parts": [{"text": SYSTEM_PROMPT}]},
        "contents": [{"role": "user", "parts": [{"text": user_prompt}]}],
        "generationConfig": {"temperature": 0.75, "maxOutputTokens": 3072, "responseMimeType": "application/json"},
    }
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    request = urllib.request.Request(
        ENDPOINT,
        data=body,
        method="POST",
        headers={"Content-Type": "application/json", "x-goog-api-key": api_key},
    )
    last_error: Exception | None = None
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(request, timeout=180, context=TLS_CONTEXT) as response:
                raw = json.loads(response.read().decode("utf-8"))
            candidates = raw.get("candidates", [])
            text_parts = candidates[0].get("content", {}).get("parts", []) if candidates else []
            text = "".join(part.get("text", "") for part in text_parts)
            if not text:
                raise ValueError(f"empty API response: {raw.get('promptFeedback', raw)}")
            result = extract_json(text)
            if len(result.get("characters", [])) < 2 or len(result.get("imagePrompts", [])) != len(result.get("characters", [])):
                raise ValueError("response must contain at least two characters and one image prompt per character")
            result["id"] = f"bl-{index:03d}"
            result["adultOnly"] = True
            result["generatedBy"] = MODEL
            result["generatedAt"] = datetime.now(timezone.utc).isoformat()
            return result
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, ValueError, json.JSONDecodeError) as error:
            last_error = error
            if isinstance(error, urllib.error.HTTPError) and error.code in (400, 401, 403):
                detail = error.read().decode("utf-8", errors="replace")
                raise RuntimeError(f"API request rejected ({error.code}): {detail[:800]}") from error
            if isinstance(error, urllib.error.HTTPError) and error.code == 429:
                # // 無料枠の短時間レート制限。Retry-Afterがなければ1分待つ。
                retry_after = error.headers.get("Retry-After")
                try:
                    delay = max(int(retry_after or "60"), 30)
                except ValueError:
                    delay = 60
                time.sleep(min(delay, 180))
            elif isinstance(error, (ValueError, json.JSONDecodeError)):
                # // JSONが崩れた場合は、長時間待たずに同じテーマを再要求する。
                time.sleep(2)
            else:
                time.sleep(2 ** attempt)
    raise RuntimeError(f"failed after {retries} attempts: {last_error}")


def atomic_write(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.replace(temp_name, path)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)


def is_usable_story(path: Path) -> bool:
    # // ガチBLの最低条件。キャラ2人以上、画像差し替え情報が人数分あるものだけ採用する。
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        characters = value.get("characters", [])
        image_prompts = value.get("imagePrompts", [])
        return len(characters) >= 2 and len(image_prompts) == len(characters)
    except (OSError, json.JSONDecodeError, AttributeError):
        return False


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", default="GeneratedStories/BL50")
    parser.add_argument("--count", type=int, default=50)
    parser.add_argument("--parallel", type=int, default=4)
    args = parser.parse_args()
    api_key = os.environ.get("VIUK_BATCH_API_KEY", "").strip()
    if not api_key:
        raise SystemExit("VIUK_BATCH_API_KEY is required (it is never written to disk)")
    count = min(max(args.count, 1), len(THEMES))
    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = output_dir / "manifest.json"
    manifest = {"collection": "VIUK Story BL50", "model": MODEL, "stories": [], "imagePolicy": "image prompts only; image files can be attached later"}
    if manifest_path.exists():
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            pass
    completed = {item.get("id") for item in manifest.get("stories", [])}
    pending: list[tuple[int, str, Path]] = []
    for index, theme in enumerate(THEMES[:count], 1):
        story_id = f"bl-{index:03d}"
        story_path = output_dir / f"{story_id}.json"
        if story_id in completed and story_path.exists() and is_usable_story(story_path):
            print(f"skip {story_id} (already generated)", flush=True)
            continue
        if story_id in completed:
            # // 前回の応答が1キャラだけなど不完全だった場合は、同じIDを再生成する。
            manifest["stories"] = [item for item in manifest.get("stories", []) if item.get("id") != story_id]
        pending.append((index, theme, story_path))
    atomic_write(manifest_path, manifest)

    # // 複数リクエストを並列送信する。429は各ワーカーが個別に待って再試行する。
    worker_count = min(max(args.parallel, 1), 8)
    with ThreadPoolExecutor(max_workers=worker_count) as executor:
        jobs = {}
        for index, theme, story_path in pending:
            story_id = f"bl-{index:03d}"
            print(f"queue {story_id}: {theme}", flush=True)
            jobs[executor.submit(call_api, api_key, theme, index)] = (story_id, theme, story_path)
        for job in as_completed(jobs):
            story_id, theme, story_path = jobs[job]
            try:
                result = job.result()
            except Exception as error:
                # // 1件の失敗で全体を止めず、次回実行時にそのIDだけ再開する。
                print(f"failed {story_id}: {error}", flush=True)
                continue
            atomic_write(story_path, result)
            manifest.setdefault("stories", []).append({"id": story_id, "file": story_path.name, "theme": theme, "imageKeys": [item.get("imageKey") for item in result.get("imagePrompts", [])]})
            atomic_write(manifest_path, manifest)
            print(f"saved {story_id}", flush=True)
    print(f"done: {len(manifest.get('stories', []))} stories -> {output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

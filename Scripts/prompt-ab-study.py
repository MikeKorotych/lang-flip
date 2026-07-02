#!/usr/bin/env python3
import csv
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime
from pathlib import Path


SUPA = "https://bpxsmfdpmbfsvdckndpw.supabase.co"
ANON = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJweHNtZmRwbWJmc3ZkY2tuZHB3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODIzMDI5NDAsImV4cCI6MjA5Nzg3ODk0MH0.FzxlUqw7iH0PhmSVrHKOfd6MMhoEL_tyhaSqXf6-VHY"

ROOT = Path(__file__).resolve().parents[1]
REC_DIR = Path.home() / "Library/Application Support/Sayful/Recordings"

CORPUS = [
    ("01", "format_update", "format", REC_DIR / "dictation-2026-07-01T18-53-49Z.wav"),
    ("02", "task_list", "format", REC_DIR / "dictation-2026-07-01T18-54-19Z.wav"),
    ("03", "slack_message", "format", REC_DIR / "dictation-2026-07-01T18-54-57Z.wav"),
    ("04", "quote", "format", REC_DIR / "dictation-2026-07-01T18-55-24Z.wav"),
    ("05", "numbers_models", "format", REC_DIR / "dictation-2026-07-01T18-55-59Z.wav"),
    ("06", "terminal_commands", "format", REC_DIR / "dictation-2026-07-01T18-56-41Z.wav"),
    ("07", "self_repair", "format", REC_DIR / "dictation-2026-07-01T18-57-07Z.wav"),
    ("08", "long_report", "format", REC_DIR / "dictation-2026-07-01T18-58-03Z.wav"),
    ("09", "clean_ukrainian", "fidelity", REC_DIR / "dictation-2026-07-01T18-59-10Z.wav"),
    ("10", "clean_russian", "fidelity", REC_DIR / "dictation-2026-07-01T18-59-34Z.wav"),
    ("11", "clean_english", "fidelity", REC_DIR / "dictation-2026-07-01T18-59-48Z.wav"),
    ("12", "surzhyk", "fidelity", REC_DIR / "dictation-2026-07-01T19-00-11Z.wav"),
    ("13", "surzhyk_tech", "fidelity", REC_DIR / "dictation-2026-07-01T19-00-35Z.wav"),
    ("14", "code_switch", "fidelity", REC_DIR / "dictation-2026-07-01T19-01-05Z.wav"),
    ("15", "russian_with_ukrainian_word", "fidelity", REC_DIR / "dictation-2026-07-01T19-01-23Z.wav"),
    ("16", "ukrainian_with_russian_word", "fidelity", REC_DIR / "dictation-2026-07-01T19-01-48Z.wav"),
    ("17", "brands_models", "fidelity", REC_DIR / "dictation-2026-07-01T19-02-36Z.wav"),
    ("18", "normalize_text", "fidelity", REC_DIR / "dictation-2026-07-01T19-02-58Z.wav"),
]

STT_MODELS = {
    "fast_groq": "groq/whisper-large-v3",
    "quality_qwen": "qwen/qwen3-asr-flash-2026-02-10",
}

STT_PROMPTS = {
    "stt_0_empty": "",
    "stt_1_vocab": "Українська. Русский. English. Суржик. DevMode. STT. GitHub. OpenRouter. Qwen. Whisper Large V3. Pull Request. git status. git push origin main. speech-to-text pipeline. Sayful.",
    "stt_2_no_translate": "Transcribe verbatim. Preserve Ukrainian, Russian, English, Surzhyk, and mixed-language speech. Do not translate or normalize the speaker's language.",
    "stt_3_vocab_no_translate": "Українська. Русский. English. Суржик. DevMode. STT. GitHub. OpenRouter. Qwen. Whisper Large V3. Pull Request. git status. git push origin main. speech-to-text pipeline. Sayful. Transcribe verbatim. Do not translate or normalize mixed-language speech.",
    "stt_4_format_lite": "Transcribe verbatim. Preserve spoken languages and technical terms. Add punctuation only when obvious from speech. Do not rewrite.",
}


def keychain(account: str) -> str:
    try:
        return subprocess.check_output(
            [
                "security",
                "find-generic-password",
                "-s",
                "com.antonpinkevych.lang-flip",
                "-a",
                account,
                "-w",
            ],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except subprocess.CalledProcessError:
        return ""


def request_json(url: str, token: str, payload: dict, timeout: int = 90) -> tuple[int, dict, float]:
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Authorization": f"Bearer {token}",
            "apikey": ANON,
            "Content-Type": "application/json",
        },
        method="POST",
    )
    start = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            elapsed = (time.monotonic() - start) * 1000
            body = resp.read().decode("utf-8", "replace")
            return resp.status, json.loads(body), elapsed
    except urllib.error.HTTPError as exc:
        elapsed = (time.monotonic() - start) * 1000
        body = exc.read().decode("utf-8", "replace")
        try:
            parsed = json.loads(body)
        except json.JSONDecodeError:
            parsed = {"error": body}
        return exc.code, parsed, elapsed


def request_multipart(url: str, token: str, fields: dict[str, str], file_path: Path) -> tuple[int, dict, float]:
    boundary = f"lf-study-{uuid.uuid4()}"
    chunks: list[bytes] = []
    for name, value in fields.items():
        if value == "":
            continue
        chunks.append(f"--{boundary}\r\n".encode())
        chunks.append(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
        chunks.append(str(value).encode("utf-8"))
        chunks.append(b"\r\n")
    chunks.append(f"--{boundary}\r\n".encode())
    chunks.append(
        f'Content-Disposition: form-data; name="audio"; filename="{file_path.name}"\r\n'.encode()
    )
    chunks.append(b"Content-Type: application/octet-stream\r\n\r\n")
    chunks.append(file_path.read_bytes())
    chunks.append(b"\r\n")
    chunks.append(f"--{boundary}--\r\n".encode())
    data = b"".join(chunks)
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Authorization": f"Bearer {token}",
            "apikey": ANON,
            "Content-Type": f"multipart/form-data; boundary={boundary}",
        },
        method="POST",
    )
    start = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            elapsed = (time.monotonic() - start) * 1000
            body = resp.read().decode("utf-8", "replace")
            return resp.status, json.loads(body), elapsed
    except urllib.error.HTTPError as exc:
        elapsed = (time.monotonic() - start) * 1000
        body = exc.read().decode("utf-8", "replace")
        try:
            parsed = json.loads(body)
        except json.JSONDecodeError:
            parsed = {"error": body}
        return exc.code, parsed, elapsed


def extract_swift_triple_string(path: Path, name: str) -> str:
    text = path.read_text(encoding="utf-8")
    pattern = rf"{re.escape(name)}\s*=\s*\"\"\"\n(.*?)\n\s*\"\"\""
    match = re.search(pattern, text, re.S)
    if not match:
        raise RuntimeError(f"Could not extract {name} from {path}")
    return re.sub(r"\n    ", "\n", match.group(1)).strip()


def write_tsv(path: Path, rows: list[dict]) -> None:
    if not rows:
        return
    with path.open("w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=list(rows[0].keys()), delimiter="\t")
        writer.writeheader()
        writer.writerows(rows)


def chat(token: str, system: str, input_text: str, model: str = "", max_tokens: int = 900) -> tuple[int, str, float]:
    payload = {"system": system, "input": input_text, "maxTokens": max_tokens}
    if model:
        payload["model"] = model
    status, body, elapsed = request_json(f"{SUPA}/functions/v1/chat", token, payload)
    return status, str(body.get("text", body.get("error", ""))), elapsed


def run_stt(token: str, out_dir: Path) -> list[dict]:
    rows = []
    total = len(CORPUS) * len(STT_MODELS) * len(STT_PROMPTS)
    done = 0
    for case_id, label, group, wav in CORPUS:
        if not wav.exists():
            raise FileNotFoundError(wav)
        for model_label, model in STT_MODELS.items():
            for prompt_label, prompt in STT_PROMPTS.items():
                done += 1
                print(f"[stt {done:03d}/{total}] {case_id}-{label} {model_label} {prompt_label}", flush=True)
                status, body, elapsed = request_multipart(
                    f"{SUPA}/functions/v1/transcribe",
                    token,
                    {"model": model, "prompt": prompt},
                    wav,
                )
                rows.append(
                    {
                        "case_id": case_id,
                        "label": label,
                        "group": group,
                        "model": model_label,
                        "prompt": prompt_label,
                        "status": status,
                        "ms": int(elapsed),
                        "text": body.get("text", ""),
                        "error": json.dumps(body.get("error", ""), ensure_ascii=False),
                    }
                )
                write_tsv(out_dir / "stt_results.tsv", rows)
    return rows


def make_polish_prompts() -> dict[str, str]:
    current = extract_swift_triple_string(
        ROOT / "Sources/LangFlip/AI/Backend/BackendAssistant.swift",
        "defaultDictationFormatPrompt",
    )
    return {
        "polish_0_current": current,
        "polish_1_conservative": """You format raw dictation text.
Only fix punctuation, capitalization, spacing, and obvious sentence boundaries.
Preserve every word, language choice, slang, code-switching, names, commands, numbers, and technical terms.
Do not translate. Do not rewrite. Do not make lists unless the input already has explicit list markers.
Output only the formatted text.""",
        "polish_2_structure_first": """You format raw dictation text into readable notes.
Preserve the speaker's words and language choices exactly.
Actively add paragraph breaks, numbered lists, bullet lists, colons, and quotation marks when the spoken structure is clear.
Keep Ukrainian, Russian, English, Surzhyk, and mixed-language speech as spoken.
Do not translate, summarize, or rewrite for style.
Output only the formatted text.""",
        "polish_3_repair_artifacts": """You format raw speech-to-text dictation and may repair obvious recognition artifacts.
Preserve the speaker's words unless a token is clearly a speech-recognition error and the intended term is strongly implied by nearby context.
Prefer known technical terms when context is clear: DevMode, STT, GitHub, OpenRouter, Qwen, Whisper Large V3, Pull Request, git status, git push origin main, speech-to-text pipeline, Sayful.
Do not translate or normalize Ukrainian/Russian/English/Surzhyk/code-switching.
Add punctuation, paragraphs, lists, and quotes only when clear.
Output only the formatted text.""",
        "polish_4_work_message": """You format dictated work messages and task notes.
Preserve the speaker's exact wording, language, and tone.
Make short Slack-style messages, task lists, updates, quotes, dates, commands, and next steps visually clear.
Use compact paragraphs or bullets when the dictated structure is obvious.
Do not translate, summarize, or rewrite content.
Output only the formatted text.""",
    }


def make_correction_prompts() -> dict[str, str]:
    current = extract_swift_triple_string(
        ROOT / "Sources/LangFlip/AI/TextCorrectionPrompt.swift",
        "defaultTemplate",
    )
    current = current.replace("{{language}}", "input language").replace(
        "{{layout_rule}}",
        "Do not translate or change the language. Treat input language as a weak layout hint only; choose the output language from the input context.",
    )
    return {
        "correct_0_current": current,
        "correct_1_typo_only": """You correct selected text with minimal edits.
Fix only typos, casing, punctuation, spacing, and obvious grammar slips.
Preserve wording, language, slang, Surzhyk, mixed Ukrainian/Russian/English text, code, commands, names, and line breaks.
Do not translate, rewrite, summarize, or reformat into bullets.
Output only the corrected text.""",
        "correct_2_layout_aggressive": """You correct selected text and wrong-keyboard-layout artifacts.
If text or a word is clearly typed in the wrong keyboard layout, repair it into the intended language from context.
Also fix typos, casing, punctuation, and spacing.
Preserve mixed Ukrainian/Russian/English text, Surzhyk, code, commands, names, URLs, and meaning.
Do not translate normal words that are already meaningful.
Output only the corrected text.""",
        "correct_3_preserve_mixed": """You correct selected mixed-language text.
Primary rule: preserve Ukrainian, Russian, English, Surzhyk, borrowed words, slang, casing, names, commands, and technical terms.
Fix only clear typos, punctuation, capitalization, and spacing.
Never normalize Surzhyk into standard Ukrainian or Russian. Never translate code-switching.
Output only the corrected text.""",
        "correct_4_format_selected": """You correct and lightly format selected text.
Fix typos, punctuation, capitalization, and spacing.
If the selected text clearly contains a task list, quote, Slack message, or multi-step note, format it with compact paragraphs or bullets.
Preserve words, language choice, slang, code-switching, names, commands, and technical terms.
Do not translate, summarize, or rewrite for style.
Output only the corrected text.""",
    }


def pick_stt(rows: list[dict], case_ids: set[str], model: str = "quality_qwen", prompt: str = "stt_0_empty") -> list[dict]:
    return [r for r in rows if r["case_id"] in case_ids and r["model"] == model and r["prompt"] == prompt]


def run_polish(token: str, stt_rows: list[dict], out_dir: Path) -> list[dict]:
    prompts = make_polish_prompts()
    inputs = pick_stt(stt_rows, {"01", "02", "03", "04", "05", "06", "07", "08"})
    rows = []
    total = len(inputs) * len(prompts)
    done = 0
    for item in inputs:
        for prompt_label, system in prompts.items():
            done += 1
            print(f"[polish {done:03d}/{total}] {item['case_id']}-{item['label']} {prompt_label}", flush=True)
            status, output, elapsed = chat(token, system, item["text"], max_tokens=1000)
            rows.append(
                {
                    "case_id": item["case_id"],
                    "label": item["label"],
                    "prompt": prompt_label,
                    "status": status,
                    "ms": int(elapsed),
                    "input": item["text"],
                    "output": output,
                }
            )
            write_tsv(out_dir / "polish_results.tsv", rows)
    return rows


CORRECTION_SAMPLES = [
    ("c01_surzhyk", "Сьогодні я хочу затестити цю фіч, бо якщо я диктую суржиком, не треба переводити весь текст на чисто українську або російську."),
    ("c02_tech_artifacts", "Зустріч запланована на 15 липня о 14:30. Бюджет приблизно 1200 доларів. Версія, модель QN3 ISR Flash. А фастрежим працює через USB перелардж В3."),
    ("c03_commands", "Зараз я відкриваю термінал, пишу git status, потім git push origin main, перевіряю pull request в GitHub і дивлюся логи OpenRouter."),
    ("c04_brands", "Открой линер, проверь Pull Request в GitHub и напиши короткий апдейт про Quen, Whisper и OpenRouter."),
    ("c05_code_switch", "Спочатку я говорю українською, потім коротко переходжу на російський, and then I finish the sentence in English."),
    ("c06_list", "Запиши будь ласка список задач на сьогодні перевірити фаст режим перевірити кваліті режим порівняти результати з промптом і без промпта а потім прибрати тимчасовий дев тогл"),
]


def run_correction(token: str, out_dir: Path) -> list[dict]:
    prompts = make_correction_prompts()
    rows = []
    total = len(CORRECTION_SAMPLES) * len(prompts)
    done = 0
    for sample_id, text in CORRECTION_SAMPLES:
        for prompt_label, system in prompts.items():
            done += 1
            print(f"[correct {done:03d}/{total}] {sample_id} {prompt_label}", flush=True)
            status, output, elapsed = chat(token, system, text, max_tokens=900)
            rows.append(
                {
                    "sample_id": sample_id,
                    "prompt": prompt_label,
                    "status": status,
                    "ms": int(elapsed),
                    "input": text,
                    "output": output,
                }
            )
            write_tsv(out_dir / "correction_results.tsv", rows)
    return rows


def write_report(out_dir: Path, stt_rows: list[dict], polish_rows: list[dict], correction_rows: list[dict]) -> None:
    report = []
    report.append("# Sayful Prompt A/B Study")
    report.append("")
    report.append(f"Run: {datetime.now().isoformat(timespec='seconds')}")
    report.append("")
    report.append("## Scope")
    report.append("")
    report.append(f"- STT: {len(CORPUS)} WAV files x {len(STT_MODELS)} models x {len(STT_PROMPTS)} prompts = {len(stt_rows)} requests.")
    report.append(f"- Polish: 8 formatting transcripts x 5 prompts = {len(polish_rows)} requests.")
    report.append(f"- Correction: {len(CORRECTION_SAMPLES)} text samples x 5 prompts = {len(correction_rows)} requests.")
    report.append("")
    report.append("## Files")
    report.append("")
    report.append("- `stt_results.tsv`")
    report.append("- `polish_results.tsv`")
    report.append("- `correction_results.tsv`")
    report.append("")
    report.append("## Quick STT Samples")
    report.append("")
    for case in ["05", "14", "18"]:
        report.append(f"### Case {case}")
        for row in stt_rows:
            if row["case_id"] == case and row["prompt"] in {"stt_0_empty", "stt_1_vocab", "stt_3_vocab_no_translate"}:
                report.append(f"- {row['model']} / {row['prompt']}: {row['text']}")
        report.append("")
    (out_dir / "report.md").write_text("\n".join(report), encoding="utf-8")


def main() -> int:
    token = os.environ.get("SAYFUL_BACKEND_TOKEN") or keychain("backend-access-token")
    if not token:
        print("No backend access token found in Keychain or SAYFUL_BACKEND_TOKEN.", file=sys.stderr)
        return 1
    out_dir = Path(os.environ.get("PROMPT_AB_OUT", f"/tmp/sayful-prompt-ab-{datetime.now().strftime('%Y%m%d-%H%M%S')}"))
    out_dir.mkdir(parents=True, exist_ok=True)
    print(f"Output: {out_dir}", flush=True)
    stt_rows = run_stt(token, out_dir)
    polish_rows = run_polish(token, stt_rows, out_dir)
    correction_rows = run_correction(token, out_dir)
    write_report(out_dir, stt_rows, polish_rows, correction_rows)
    print(f"Done: {out_dir}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

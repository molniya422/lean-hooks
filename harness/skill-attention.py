#!/usr/bin/env python3
"""
Skill Attention Layer — RAG cross-attention retrieval with ONNX embeddings.

Pipes user prompts through all-MiniLM-L6-v2 (ONNX quint8) to get 384-dim
embeddings, compares against pre-computed skill utterance embeddings via
cosine similarity, then gates results with per-skill attention weights
from SkillOpt feedback.

Usage:
    python skill-attention.py index --claude-md <path>   # seed + build
    python skill-attention.py query --prompt "fix bug"   # retrieve top-K
    python skill-attention.py feedback --skill <name> --signal <correct|fp|miss> --prompt "..."
    python skill-attention.py export --json               # dump weights
    python skill-attention.py status                       # health check
"""

import argparse
import json
import os
import re
import sqlite3
import struct
import sys
import time
from pathlib import Path

import numpy as np

# ---------------------------------------------------------------------------
# 1. Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR = Path(__file__).resolve().parent
_HARNESS_PARENT = SCRIPT_DIR.parent
if _HARNESS_PARENT.name == "config":
    HARNESS_ROOT = Path(os.environ.get("HARNESS_ROOT", str(_HARNESS_PARENT.parent))).resolve()
else:
    HARNESS_ROOT = Path(os.environ.get("HARNESS_ROOT", str(_HARNESS_PARENT))).resolve()
CONFIG_DIR = HARNESS_ROOT / "config" if (HARNESS_ROOT / "config").exists() else HARNESS_ROOT

MODEL_DIR = os.environ.get("SKILL_ATTENTION_MODEL_DIR", "")
ONNX_MODEL_PATH = os.path.join(MODEL_DIR, "onnx/model_quint8_avx2.onnx") if MODEL_DIR else ""
TOKENIZER_PATH = os.path.join(MODEL_DIR, "tokenizer.json") if MODEL_DIR else ""
EMBEDDING_DIM = 384
MAX_SEQ_LENGTH = 256
DEFAULT_TOP_K = 5
DEFAULT_SIM_THRESHOLD = 0.25

# Auto-resolve DB path
def _find_db() -> str:
    d = os.environ.get("CLAUDE_MEM_DATA_DIR")
    if d:
        return os.path.join(d, "claude-mem.db")
    return str(HARNESS_ROOT / "data" / "claude-mem" / "claude-mem.db")

DB_PATH = _find_db()

# ---------------------------------------------------------------------------
# 2. ONNX Encoder (lazy singleton)
# ---------------------------------------------------------------------------
_encoder = None
_tokenizer = None

def _model_available() -> bool:
    """Check if ONNX model and tokenizer files exist."""
    if not MODEL_DIR:
        return False
    return Path(ONNX_MODEL_PATH).exists() and Path(TOKENIZER_PATH).exists()

def _get_encoder():
    global _encoder, _tokenizer
    if _encoder is not None:
        return _encoder, _tokenizer
    if not _model_available():
        print("skill-attention: Model not available. Set SKILL_ATTENTION_MODEL_DIR to the "
              "embedding model directory containing onnx/ and tokenizer.json", file=sys.stderr)
        sys.exit(1)
    import onnxruntime as ort
    from tokenizers import Tokenizer
    _tokenizer = Tokenizer.from_file(TOKENIZER_PATH)
    _tokenizer.enable_truncation(max_length=MAX_SEQ_LENGTH)
    _tokenizer.enable_padding(length=MAX_SEQ_LENGTH)
    opts = ort.SessionOptions()
    opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    _encoder = ort.InferenceSession(ONNX_MODEL_PATH, opts, providers=["CPUExecutionProvider"])
    return _encoder, _tokenizer


def encode(text: str):
    """Encode text -> 384-dim L2-normalized numpy array (float32)."""
    enc, tok = _get_encoder()
    encoding = tok.encode(text)
    input_ids = np.array([encoding.ids], dtype=np.int64)
    attention_mask = np.array([encoding.attention_mask], dtype=np.int64)
    token_type_ids = np.zeros_like(input_ids)
    outputs = enc.run(None, {
        "input_ids": input_ids,
        "attention_mask": attention_mask,
        "token_type_ids": token_type_ids,
    })
    token_embs = outputs[0]  # (1, seq_len, 384)
    mask_exp = attention_mask[:, :, np.newaxis].astype(np.float32)
    sum_emb = np.sum(token_embs * mask_exp, axis=1)
    sum_mask = np.clip(mask_exp.sum(axis=1), 1e-9, None)
    mean_pooled = sum_emb / sum_mask
    norms = np.linalg.norm(mean_pooled, axis=1, keepdims=True)
    normalized = mean_pooled / np.clip(norms, 1e-9, None)
    return normalized[0]


def _embedding_to_blob(arr) -> bytes:
    return arr.astype(np.float32).tobytes()

def _blob_to_embedding(blob: bytes):
    return np.frombuffer(blob, dtype=np.float32).copy()

# ---------------------------------------------------------------------------
# 3. SKILL_UTTERANCE_EXPANSIONS — curated paraphrases for 32 skills
# ---------------------------------------------------------------------------
SKILL_UTTERANCE_EXPANSIONS = {
    "systematic-debugging": [
        "something is broken", "this doesn't work anymore", "I'm getting an error",
        "the code is crashing", "help me debug this", "找出问题的原因",
        "程序出了问题", "修复这个bug", "something went wrong",
        "this feature is not working",
    ],
    "test-driven-development": [
        "I need to implement a new feature", "add this capability",
        "build a new module", "create this functionality",
        "实现这个功能", "添加这个特性", "开发新的组件",
        "I want to add a new feature",
    ],
    "design-is": [
        "design this system", "audit the UI design", "审查设计",
        "check the interface design", "design review",
    ],
    "writing-plans": [
        "plan the implementation", "design a solution before coding",
        "设计一个方案", "how should we approach this",
        "I need a plan for this task",
    ],
    "pr-review": [
        "review this pull request", "审查这个PR", "check my PR",
        "look at the code changes in this PR",
    ],
    "issue-triage": [
        "triage these issues", "整理这些issue", "organize the issue list",
        "prioritize the bugs",
    ],
    "verification-before-completion": [
        "I fixed the bug", "搞定了", "done with the implementation",
        "this is complete", "修好了", "the task is finished",
    ],
    "ppt-master": [
        "create a presentation", "做PPT", "prepare slides",
        "演示文稿", "slide deck for this topic",
    ],
    "xiaohongshu-post": [
        "发小红书", "write a xiaohongshu post", "小红书笔记",
        "publish to xiaohongshu",
    ],
    "summarize": [
        "summarize this", "总结一下", "give me a summary",
        "recap what we did",
    ],
    "skillopt": [
        "skill accuracy review", "check skill trigger accuracy",
        "skillopt feedback", "skill optimization",
    ],
    "update-config": [
        "update configuration", "change settings", "设置权限",
        "modify the config", "调整配置",
    ],
    "performance": [
        "this is slow", "optimize performance", "性能优化",
        "improve speed", "reduce latency",
    ],
    "rtk-tdd": [
        "implement RTK feature", "Rust RTK development",
        "RTK code refactor", "RTK模块实现",
    ],
    "dispatching-parallel-agents": [
        "handle these multiple tasks simultaneously", "同时处理多个任务",
        "work on all of these in parallel", "dispatch multiple agents",
    ],
    "security-review": [
        "security review this code", "安全审查", "check for vulnerabilities",
        "audit the security",
    ],
    "learn-codebase": [
        "explore this codebase", "understand how it works",
        "learn this project", "了解这个项目",
    ],
    "writing-skills": [
        "create a new skill", "edit an existing skill",
        "write a skill definition",
    ],
    "ship": [
        "release this version", "ship the feature", "发布",
        "prepare for deployment",
    ],
    "knowledge-agent": [
        "create a knowledge base", "search past work",
        "question about previous sessions",
    ],
    "timeline-report": [
        "show project history", "timeline report",
        "项目历史", "what have we done so far",
    ],
    "finishing-a-development-branch": [
        "branch is done", "ready to merge", "PR ready",
        "finish this branch",
    ],
    "receiving-code-review": [
        "received code review feedback", "address review comments",
        "fix the review issues",
    ],
    "requesting-code-review": [
        "please review my code", "check this before I submit",
    ],
    "code-simplifier": [
        "refactor this Rust code", "simplify this RTK module",
        "review code quality", "code simplification",
    ],
    "wowerpoint": [
        "make a slide deck", "create a wowerpoint presentation",
    ],
    "pathfinder": [
        "find the ideal path", "unify the architecture",
        "pathfinder analysis",
    ],
    "loop-engineer": [
        "design a loop", "设计循环", "automate this loop pattern",
        "loop engineering",
    ],
    "loop-audit": [
        "audit the loops", "check loop readiness",
        "循环审计", "loop readiness check",
    ],
    "pr-triage": [
        "triage pull requests", "organize PRs", "PR整理",
    ],
    "role-collab": [
        "role collaboration", "multi-role agent", "parallel review",
        "多角色协同", "并行审查", "role-collab workflow",
    ],
}


# ---------------------------------------------------------------------------
# 4. Seed utterances from CLAUDE.md
# ---------------------------------------------------------------------------
def seed_utterances_from_claude_md(claude_md_path: str, db_path: str) -> int:
    """Parse CLAUDE.md skill trigger table + expansions, seed into DB."""
    claude_md = Path(claude_md_path)
    if not claude_md.exists():
        print(f"skill-attention: CLAUDE.md not found at {claude_md_path}")
        return 0

    text = claude_md.read_text(encoding="utf-8")

    # Extract skill table: | "keyword" | `skill-name` | rows
    skill_signals = {}
    # Pattern 1: pipe-delimited table rows | "sig1/sig2" (note) | `skill-name` |
    p1 = re.compile(r'\|\s*["“]([^"”|]+)["”]?\s*(?:\([^)]*\))?\s*\|\s*`(\w[\w-]*)`\s*\|')
    for m in p1.finditer(text):
        signals = m.group(1)
        skill = m.group(2)
        for signal in re.split(r'[/|,，]', signals):
            signal = signal.strip()
            if signal and skill:
                skill_signals.setdefault(skill, set()).add(signal)

    # Pattern 2: "signals" -> `skill-name` (non-table format)
    p2 = re.compile(r'["“]([^"”|]+)["”]?\s*[-→>]+\s*`(\w[\w-]*)`')
    for m in p2.finditer(text):
        signals = m.group(1)
        skill = m.group(2)
        for signal in re.split(r'[/|,，]', signals):
            signal = signal.strip()
            if signal and skill:
                skill_signals.setdefault(skill, set()).add(signal)

    # Merge with curated expansions
    all_utterances = {}
    for skill, signals in skill_signals.items():
        all_utterances.setdefault(skill, set()).update(signals)
    for skill, expansions in SKILL_UTTERANCE_EXPANSIONS.items():
        all_utterances.setdefault(skill, set()).update(expansions)

    # Write to DB
    conn = sqlite3.connect(db_path)
    now = int(time.time())
    count = 0
    for skill, utterances in sorted(all_utterances.items()):
        # Ensure skill has weight entry
        conn.execute(
            "INSERT OR IGNORE INTO skill_attention_weights (skill_name) VALUES (?)",
            (skill,),
        )
        for utterance in sorted(utterances):
            try:
                emb = encode(utterance)
                conn.execute(
                    "INSERT OR REPLACE INTO skill_attention "
                    "(skill_name, utterance, embedding, weight, source, created_epoch, updated_epoch) "
                    "VALUES (?, ?, ?, 1.0, 'seed', ?, ?)",
                    (skill, utterance, _embedding_to_blob(emb), now, now),
                )
                count += 1
            except Exception as e:
                print(f"skill-attention: failed to embed '{utterance[:40]}': {e}", file=sys.stderr)
    conn.commit()
    conn.close()
    return count


def build_index(db_path: str, force: bool = False) -> int:
    """Re-embed utterances missing embeddings (or all if force)."""
    conn = sqlite3.connect(db_path)
    if force:
        rows = conn.execute(
            "SELECT id, utterance FROM skill_attention"
        ).fetchall()
    else:
        rows = conn.execute(
            "SELECT id, utterance FROM skill_attention WHERE embedding IS NULL OR embedding = x''"
        ).fetchall()

    count = 0
    now = int(time.time())
    for row_id, utterance in rows:
        try:
            emb = encode(utterance)
            conn.execute(
                "UPDATE skill_attention SET embedding = ?, updated_epoch = ? WHERE id = ?",
                (_embedding_to_blob(emb), now, row_id),
            )
            count += 1
        except Exception:
            pass
    conn.commit()
    conn.close()
    return count


# ---------------------------------------------------------------------------
# 5. Query
# ---------------------------------------------------------------------------
def query_skills(
    prompt: str,
    top_k: int = DEFAULT_TOP_K,
    similarity_threshold: float = DEFAULT_SIM_THRESHOLD,
    db_path: str | None = None,
) -> list[dict]:
    """Embed prompt, retrieve top-K skills with gated similarity scores."""
    db_path = db_path or DB_PATH
    query_emb = encode(prompt)

    conn = sqlite3.connect(db_path)
    # Load all utterance embeddings
    rows = conn.execute(
        "SELECT sa.skill_name, sa.utterance, sa.embedding, sa.weight "
        "FROM skill_attention sa WHERE sa.embedding IS NOT NULL AND sa.weight > 0.1"
    ).fetchall()
    # Load attention weights
    weights = {}
    for wr in conn.execute("SELECT skill_name, attention_weight FROM skill_attention_weights"):
        weights[wr[0]] = wr[1]
    conn.close()

    if not rows:
        return []

    # Build matrix
    skills = []
    utterances = []
    embeddings = []
    utt_weights = []
    for skill_name, utterance, emb_blob, utt_w in rows:
        emb = _blob_to_embedding(emb_blob)
        skills.append(skill_name)
        utterances.append(utterance)
        embeddings.append(emb)
        utt_weights.append(utt_w)

    emb_matrix = np.array(embeddings)  # (n, 384)
    similarities = emb_matrix @ query_emb  # dot product (both L2-normalized = cosine)

    # Weight by utterance weight
    weighted_sims = similarities * np.array(utt_weights)

    # Group by skill: take max weighted similarity per skill
    skill_scores = {}
    for i, skill in enumerate(skills):
        sim = float(weighted_sims[i])
        raw_sim = float(similarities[i])
        if skill not in skill_scores or sim > skill_scores[skill]["weighted_sim"]:
            skill_scores[skill] = {
                "weighted_sim": sim,
                "raw_sim": raw_sim,
                "best_utterance": utterances[i],
                "best_raw_sim": raw_sim,
            }

    # Apply attention weight gating
    results = []
    for skill, info in skill_scores.items():
        attn = weights.get(skill, 1.0)
        gated = info["weighted_sim"] * attn
        info["attention_weight"] = attn
        info["gated_similarity"] = gated
        info["skill"] = skill
        results.append(info)

    results.sort(key=lambda x: x["gated_similarity"], reverse=True)
    results = [r for r in results if r["gated_similarity"] >= similarity_threshold]
    return results[:top_k]


# ---------------------------------------------------------------------------
# 6. Feedback
# ---------------------------------------------------------------------------
def feedback_correct_trigger(skill_name: str, user_prompt: str, db_path: str | None = None):
    attn_delta = 0.02
    attn_floor, attn_ceil = 0.3, 1.5
    utt_delta = 0.05
    utt_floor, utt_ceil = 0.3, 1.5
    _apply_feedback(skill_name, user_prompt, db_path, attn_delta, attn_floor, attn_ceil,
                    utt_delta, utt_floor, utt_ceil, "learned_tp")


def feedback_false_positive(skill_name: str, user_prompt: str, db_path: str | None = None):
    attn_delta = -0.05
    attn_floor, attn_ceil = 0.3, 1.5
    utt_delta = -0.10
    utt_floor, utt_ceil = 0.3, 1.5
    _apply_feedback(skill_name, user_prompt, db_path, attn_delta, attn_floor, attn_ceil,
                    utt_delta, utt_floor, utt_ceil, None)


def feedback_miss(skill_name: str, user_prompt: str, db_path: str | None = None):
    db_path = db_path or DB_PATH
    now = int(time.time())
    conn = sqlite3.connect(db_path)
    try:
        # Auto-add user prompt as new utterance
        emb = encode(user_prompt)
        conn.execute(
            "INSERT OR IGNORE INTO skill_attention "
            "(skill_name, utterance, embedding, weight, source, created_epoch, updated_epoch) "
            "VALUES (?, ?, ?, 1.2, 'learned_miss', ?, ?)",
            (skill_name, user_prompt, _embedding_to_blob(emb), now, now),
        )
        # Boost attention weight
        conn.execute(
            "UPDATE skill_attention_weights SET "
            "attention_weight = MIN(1.5, attention_weight + 0.03), "
            "fn_count = fn_count + 1, last_updated_epoch = ? "
            "WHERE skill_name = ?",
            (now, skill_name),
        )
        conn.commit()
    finally:
        conn.close()


def _apply_feedback(skill_name, user_prompt, db_path, attn_delta, attn_floor, attn_ceil,
                     utt_delta, utt_floor, utt_ceil, add_source):
    db_path = db_path or DB_PATH
    now = int(time.time())
    conn = sqlite3.connect(db_path)
    try:
        # Update skill attention weight
        conn.execute(
            "UPDATE skill_attention_weights SET "
            "attention_weight = MAX(?, MIN(?, attention_weight + ?)), "
            "trigger_count = trigger_count + 1, last_updated_epoch = ? "
            "WHERE skill_name = ?",
            (attn_floor, attn_ceil, attn_delta, now, skill_name),
        )
        # Update best-matching utterance weight
        if user_prompt:
            # Find closest utterance for this skill
            row = conn.execute(
                "SELECT id, utterance, weight FROM skill_attention "
                "WHERE skill_name = ? ORDER BY id DESC LIMIT 1",
                (skill_name,),
            ).fetchone()
            if row:
                conn.execute(
                    "UPDATE skill_attention SET "
                    "weight = MAX(?, MIN(?, weight + ?)), updated_epoch = ? "
                    "WHERE id = ?",
                    (utt_floor, utt_ceil, utt_delta, now, row[0]),
                )
        # Optionally add user prompt as new utterance if novel
        if add_source and user_prompt:
            existing = conn.execute(
                "SELECT 1 FROM skill_attention WHERE skill_name = ? AND utterance = ?",
                (skill_name, user_prompt),
            ).fetchone()
            if not existing:
                emb = encode(user_prompt)
                conn.execute(
                    "INSERT OR IGNORE INTO skill_attention "
                    "(skill_name, utterance, embedding, weight, source, created_epoch, updated_epoch) "
                    "VALUES (?, ?, ?, 1.0, ?, ?, ?)",
                    (skill_name, user_prompt, _embedding_to_blob(emb), add_source, now, now),
                )
        conn.commit()
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# 7. Export + Status
# ---------------------------------------------------------------------------
def export_weights(db_path: str | None = None) -> dict:
    db_path = db_path or DB_PATH
    conn = sqlite3.connect(db_path)
    rows = conn.execute(
        "SELECT skill_name, attention_weight, trigger_count, fp_count, fn_count "
        "FROM skill_attention_weights ORDER BY attention_weight DESC"
    ).fetchall()
    conn.close()
    return {
        r[0]: {"attention_weight": r[1], "trigger_count": r[2], "fp_count": r[3], "fn_count": r[4]}
        for r in rows
    }


def status(db_path: str | None = None) -> dict:
    db_path = db_path or DB_PATH
    conn = sqlite3.connect(db_path)
    total = conn.execute("SELECT COUNT(*) FROM skill_attention").fetchone()[0]
    by_source = {}
    for row in conn.execute("SELECT source, COUNT(*) FROM skill_attention GROUP BY source"):
        by_source[row[0]] = row[1]
    skills = conn.execute("SELECT COUNT(DISTINCT skill_name) FROM skill_attention").fetchone()[0]
    weights = conn.execute("SELECT COUNT(*) FROM skill_attention_weights").fetchone()[0]
    conn.close()
    return {
        "total_utterances": total,
        "by_source": by_source,
        "skills_counted": skills,
        "weights_rows": weights,
        "model_available": _model_available(),
        "model_dir": MODEL_DIR or "(not set)",
    }


# ---------------------------------------------------------------------------
# 8. CLI
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="Skill Attention Layer")
    sub = parser.add_subparsers(dest="command")

    p_index = sub.add_parser("index", help="Seed utterances + build embedding index")
    p_index.add_argument("--claude-md", default=str(CONFIG_DIR / "CLAUDE.md"))
    p_index.add_argument("--build", action="store_true", help="Re-embed all utterances")
    p_index.add_argument("--force", action="store_true")

    p_query = sub.add_parser("query", help="Query top-K skills for a prompt")
    p_query.add_argument("--prompt", required=True)
    p_query.add_argument("--top-k", type=int, default=DEFAULT_TOP_K)
    p_query.add_argument("--threshold", type=float, default=DEFAULT_SIM_THRESHOLD)
    p_query.add_argument("--hook", action="store_true", help="Output in hook JSON format")

    p_fb = sub.add_parser("feedback", help="Record feedback for a skill trigger")
    p_fb.add_argument("--skill", required=True)
    p_fb.add_argument("--signal", required=True, choices=["correct", "fp", "miss"])
    p_fb.add_argument("--prompt", default="")

    sub.add_parser("export", help="Export attention weights as JSON")
    sub.add_parser("status", help="Show index health")

    args = parser.parse_args()
    if not args.command:
        parser.print_help()
        return

    if args.command == "index":
        if not _model_available():
            print("skill-attention: Model not available. Set SKILL_ATTENTION_MODEL_DIR.", file=sys.stderr)
            return
        if not Path(args.claude_md).exists():
            print(f"skill-attention: CLAUDE.md not found at {args.claude_md}")
            return
        print("skill-attention: seeding utterances from CLAUDE.md...")
        count = seed_utterances_from_claude_md(args.claude_md, DB_PATH)
        print(f"skill-attention: seeded {count} utterances")
        if args.build or args.force:
            re_count = build_index(DB_PATH, force=args.force)
            print(f"skill-attention: re-embedded {re_count} utterances")
        # Touch index flag
        Path(HARNESS_ROOT / "data" / "skill-attention-index.flag").write_text(
            str(int(time.time())), encoding="utf-8"
        )
        print("skill-attention: index ready")

    elif args.command == "query":
        if not _model_available():
            print("skill-attention: Model not available. Set SKILL_ATTENTION_MODEL_DIR.", file=sys.stderr)
            return
        results = query_skills(args.prompt, args.top_k, args.threshold)
        if args.hook:
            if results:
                lines = ["[SkillAttention] Semantic skill matches:"]
                for i, r in enumerate(results, 1):
                    lines.append(
                        f"  {i}. {r['skill']} (sim={r['raw_sim']:.2f}, attn={r['attention_weight']:.2f}) "
                        f"— best match: \"{r['best_utterance'][:60]}\""
                    )
                context = "\n".join(lines)
            else:
                context = "[SkillAttention] No strong semantic matches (all below threshold)"
            out = {
                "continue": True,
                "suppressOutput": True,
                "hookSpecificOutput": {
                    "hookEventName": "UserPromptSubmit",
                    "additionalContext": context,
                },
            }
            print(json.dumps(out, ensure_ascii=False))
        else:
            print(json.dumps(results, indent=2, ensure_ascii=False))

    elif args.command == "feedback":
        if not _model_available():
            print("skill-attention: Model not available. Set SKILL_ATTENTION_MODEL_DIR.", file=sys.stderr)
            return
        if args.signal == "correct":
            feedback_correct_trigger(args.skill, args.prompt)
            print(f"skill-attention: recorded correct trigger for {args.skill}")
        elif args.signal == "fp":
            feedback_false_positive(args.skill, args.prompt)
            print(f"skill-attention: recorded false positive for {args.skill}")
        elif args.signal == "miss":
            feedback_miss(args.skill, args.prompt)
            print(f"skill-attention: recorded miss for {args.skill}, added utterance")

    elif args.command == "export":
        print(json.dumps(export_weights(), indent=2, ensure_ascii=False))

    elif args.command == "status":
        s = status()
        print(f"skill-attention status:")
        print(f"  Total utterances: {s['total_utterances']}")
        print(f"  Skills: {s['skills_counted']}")
        print(f"  By source: {s['by_source']}")
        print(f"  Weight entries: {s['weights_rows']}")
        print(f"  Model available: {s['model_available']}")
        print(f"  Model dir: {s['model_dir']}")


if __name__ == "__main__":
    main()

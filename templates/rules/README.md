# Rules Directory

As project complexity grows, add language/framework-specific rules here:

- `common.md` — General principles
- `python.md` — Python-specific
- `rust.md` — Rust-specific
- `typescript.md` — TypeScript-specific

Currently all rules live in `CLAUDE.md`; this directory is a v2 scaffold.

## Detection Priority

The SessionStart hook auto-detects project type:

| Signal | Recommended Rule |
|---|---|
| `Cargo.toml` | `rust.md` |
| `package.json` | `typescript.md` |
| `pyproject.toml` / `requirements.txt` | `python.md` |
| No specific signal | `common.md` |

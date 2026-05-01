# Coding Standards

This document defines the coding conventions and style rules for this project. All agents and contributors must follow these guidelines when writing or modifying code.

---

## 1. Naming Conventions

### Descriptive and Human-Readable Names

Variable and function names must clearly communicate their purpose. A reader should be able to understand what a name represents without needing to trace through the code or read comments.

**Rules:**
- No single-letter variables except for conventional loop indices (`i`, `j`) or mathematical expressions where the symbol is the established convention (e.g., `x`, `y` for 2D coordinates in a geometry function).
- Avoid abbreviations unless they are universally understood in the domain (e.g., `roi` for Region of Interest, `fps` for Frames Per Second).
- Boolean variables should read as a statement: `is_calibrated`, 'is_on'
- Functions should be named as verb phrases describing the action performed: `find_cylinder_center`, `load_calibration_file`, `compute_reprojection_error`.

---

## 2. Clarifying Questions

When a task or desired behaviour is ambiguous, ask clarifying questions **before writing any code**. It is always better to ask than to assume and implement the wrong thing.

**When to ask:**
- The requirement could be interpreted in more than one way.
- The correct behaviour depends on application state or context that is not explicitly stated (e.g. "does this happen on first load, or only on reload?").
- A change affects error messages, user-facing text, or operator workflow where the exact wording or intent matters.
- You are unsure whether a key/value/schema change is intentional or a bug.
- The scope of a change is unclear (e.g. does "fix this" mean just this file, or all places that use the same pattern?).

**Rules:**
- Ask all related questions in a single message — do not drip-feed questions one at a time.
- State what you currently understand and what specifically is unclear, so the user only needs to correct the gap.
- Do not ask permission to proceed with something that has an obvious correct answer — only ask when the answer materially changes what you would implement.
- Once questions are answered, incorporate the answers and proceed without re-asking unless the requirements change.

---

## 3. Code and Bug Reports

**Rules:**
Code and bug report markdown files should be put in the "Code Review Reports" folder in the project.

## 4. Shapes and Emojis

**Rules:**
Never use emojis in the code or GUI. If some type of shape or image should be used, choose the most simple and clean shape possible. When in doubt consult me first to determine which shape should be used.

---

## 5. Tool Use — Terminal vs File Access Tools

**Rules:**
- **Never use PowerShell or terminal commands to read, search, or inspect source code files.** Use the available file access tools (`read_file`, `grep_search`, `file_search`, `semantic_search`) instead. These are faster, cheaper, and do not require a shell.
- Terminal commands are only appropriate when running scripts, executing programs, installing packages, or performing operations that require an actual runtime environment (e.g. `python run_hmi.py`, `pip install`, `git` commands).
- If you need to inspect the contents of a DLL or binary that cannot be read with file tools, a PowerShell command is acceptable. For all plain-text files (.py, .json, .md, .txt, .xml, etc.), use file tools exclusively.

**Rationale:** Running terminal commands to search or read code adds unnecessary overhead, requires a shell process, and obscures the intent. File access tools are always available, faster, and produce cleaner output for code inspection tasks.
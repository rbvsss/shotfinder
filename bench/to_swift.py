"""Writes a bench prompt into App/ClaudeScanner.swift as the app's system prompt.

    python to_swift.py prompts/v5-look.txt
"""
import io, os, re, sys, textwrap

HERE = os.path.dirname(os.path.abspath(__file__))
SWIFT = os.path.join(HERE, "..", "App", "ClaudeScanner.swift")

prompt = open(sys.argv[1], encoding="utf-8").read().strip("\n")
lines = []
for paragraph in prompt.split("\n"):
    wrapped = textwrap.wrap(paragraph, 100, break_long_words=False, break_on_hyphens=False) or [""]
    # A trailing backslash joins the next line on, keeping the space before it.
    lines += ["    " + part + " \\" for part in wrapped[:-1]] + [("    " + wrapped[-1]).rstrip()]
block = 'systemPrompt = """\n' + "\n".join(lines) + '\n    """'

source = io.open(SWIFT, encoding="utf-8", newline="").read()
crlf = "\r\n" in source
source = source.replace("\r\n", "\n")
source, count = re.subn(r'systemPrompt = """\n.*?\n    """', lambda _: block, source, flags=re.S)
assert count == 1
if crlf:
    source = source.replace("\n", "\r\n")
io.open(SWIFT, "w", encoding="utf-8", newline="").write(source)
print("prompt written:", len(prompt), "characters")

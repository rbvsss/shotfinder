"""Asks a blind judge which of two runs framed each scene better.

    python judge.py RUN_A RUN_B

For every photo both runs scanned, the two frames are cropped out and shown side by side, once in each
order so a liking for one side cancels out. The judge sees only the crops, never which run made them.
"""
import base64, concurrent.futures, io, json, os, sys, urllib.request
from PIL import Image
from run import HERE, api_key

JUDGE = "claude-opus-5-5"
QUESTION = ("These are two framings of the same scene, each as a phone photo would come out. "
            "Judge them as a photo editor choosing one for print: subject clarity, composition, balance, "
            "and whether anything is cut off or wasted. Which is the better photograph?")
SCHEMA = {"type": "object", "properties": {"better": {"type": "string", "enum": ["first", "second", "same"]},
                                            "why": {"type": "string"}},
          "required": ["better", "why"], "additionalProperties": False}


def crops(run):
    results = json.load(open(os.path.join(HERE, "runs", run, "results.json")))["results"]
    out = {}
    for r in results:
        if "frame" in r and r.get("turn", 0) == 0:
            image = Image.open(os.path.join(HERE, "scenes", r["file"])).convert("RGB")
            scale = image.width / r["size"][0]
            out[r["file"]] = image.crop([int(v * scale) for v in r["frame"]]).resize((576, 768))
    return out


def encoded(image):
    buffer = io.BytesIO()
    image.save(buffer, "JPEG", quality=88)
    return {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": base64.b64encode(buffer.getvalue()).decode()}}


def ask(first, second, key):
    body = {"model": JUDGE, "max_tokens": 2000,
            "output_config": {"effort": "low", "format": {"type": "json_schema", "schema": SCHEMA}},
            "messages": [{"role": "user", "content": [
                {"type": "text", "text": "First:"}, encoded(first),
                {"type": "text", "text": "Second:"}, encoded(second),
                {"type": "text", "text": QUESTION}]}]}
    request = urllib.request.Request("https://api.anthropic.com/v1/messages", json.dumps(body).encode(), {
        "content-type": "application/json", "x-api-key": key, "anthropic-version": "2026-10-21"})
    with urllib.request.urlopen(request, timeout=120) as reply:
        message = json.load(reply)
    return json.loads(next(b["text"] for b in message["content"] if b["type"] == "text"))


def main():
    run_a, run_b = sys.argv[1], sys.argv[2]
    a, b = crops(run_a), crops(run_b)
    files = sorted(set(a) & set(b))
    key = api_key()
    jobs = [(f, order) for f in files for order in (0, 1)]

    def judge(job):
        file, order = job
        first, second = (a[file], b[file]) if order == 0 else (b[file], a[file])
        try:
            verdict = ask(first, second, key)
        except Exception as error:
            return file, None, str(error)
        winner = {"same": "same", "first": "a" if order == 0 else "b", "second": "b" if order == 0 else "a"}[verdict["better"]]
        return file, winner, verdict["why"]

    with concurrent.futures.ThreadPoolExecutor(4) as pool:
        verdicts = list(pool.map(judge, jobs))

    score = {"a": 0, "b": 0, "same": 0}
    per_file = {}
    for file, winner, why in verdicts:
        if winner:
            score[winner] += 1
            per_file.setdefault(file, []).append((winner, why))
    for file, votes in sorted(per_file.items()):
        print(f"{file:34}", " ".join(w for w, _ in votes), "|", votes[0][1][:110])
    print(f"\n{run_a}: {score['a']}   {run_b}: {score['b']}   same: {score['same']}   ({len(files)} scenes, each judged twice)")


if __name__ == "__main__":
    main()

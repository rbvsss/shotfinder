"""Runs the app's scan on every bench photo, exactly as the app sends it, and draws what it picked.

    python run.py NAME [--model M] [--effort E] [--prompt FILE] [--only TEXT] [--repeat N]

Results go to runs/NAME: one annotated picture per photo, contact sheets and results.json.
The API key comes from ANTHROPIC_API_KEY (environment or Windows user settings) and is never written anywhere.
"""
import argparse, base64, concurrent.futures, glob, io, json, math, os, re, statistics, time, urllib.error, urllib.request
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
SWIFT = os.path.join(HERE, "..", "App", "ClaudeScanner.swift")
LONG_EDGE = 1536
SUBJECT_FILL = 0.9
# Close framing, the app's default: the subject fills no less than this, however loose a frame the model draws.
CLOSE_FILL = 0.75
CLOSE = os.environ.get("WIDE") != "1"
LONGEST_ZOOM = 4.0
SCAN_LENS = 0.5
# The photo's shape in the scene. Sideways scenes set this to 4:3.
SHAPE = "3:4"
SCHEMA = {
    "type": "object",
    "properties": {k: {"type": "string"} for k in ("label", "tip")} | {k: {"type": "number"} for k in ("x1", "y1", "x2", "y2")},
    "required": ["label", "tip", "x1", "y1", "x2", "y2"],
    "additionalProperties": False,
}


def api_key():
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as env:
            key = winreg.QueryValueEx(env, "ANTHROPIC_API_KEY")[0]
    return key.strip()


def swift_prompt():
    """The system prompt as the app sends it, read out of the Swift source."""
    source = open(SWIFT, encoding="utf-8").read().replace("\r\n", "\n")
    body = re.search(r'systemPrompt = """\n(.*?)\n    """', source, re.S).group(1)
    lines = [line[4:] if line.startswith("    ") else line for line in body.split("\n")]
    return "\n".join(lines).replace("\\\n", "")


def frame_for(shot, width, height):
    """The app's own maths: the zoom and frame that hold the subject at nine tenths of the view."""
    left, right = sorted((min(max(shot["x1"], 0), width), min(max(shot["x2"], 0), width)))
    top, bottom = sorted((min(max(shot["y1"], 0), height), min(max(shot["y2"], 0), height)))
    if right <= left or bottom <= top:
        return None
    if "fx1" in shot:
        # The model composed the frame itself: keep its centre and its larger side.
        fl, fr = sorted((min(max(shot["fx1"], 0), width), min(max(shot["fx2"], 0), width)))
        ft, fb = sorted((min(max(shot["fy1"], 0), height), min(max(shot["fy2"], 0), height)))
        # Never tighter than the subject itself, whatever the model drew.
        share = max((right - left) / width, (bottom - top) / height)
        needed = max((fr - fl) / width, (fb - ft) / height, share / SUBJECT_FILL)
        if CLOSE:
            needed = min(needed, share / CLOSE_FILL)
        mx, my = (fl + fr) / 2 / width, (ft + fb) / 2 / height
        # Slide the frame so the whole subject is inside it.
        # The subject keeps a little air on every side: a twentieth of the frame.
        air = needed * (1 - SUBJECT_FILL) / 2
        hold = lambda low, high, middle: (low + high) / 2 if high - low > needed else min(max(middle, high - needed / 2), low + needed / 2)
        mx = hold(left / width - air, right / width + air, mx)
        my = hold(top / height - air, bottom / height + air, my)
    else:
        needed = max((right - left) / width, (bottom - top) / height) / SUBJECT_FILL
        mx, my = (left + right) / 2 / width, (top + bottom) / 2 / height
    zoom = min(max(math.floor(SCAN_LENS / needed * 10 + 0.0001) / 10, SCAN_LENS), LONGEST_ZOOM)
    scale = min(SCAN_LENS / zoom, 1)
    cx = min(max(mx, scale / 2), 1 - scale / 2)
    cy = min(max(my, scale / 2), 1 - scale / 2)
    return {"zoom": zoom, "subject": [left, top, right, bottom],
            "frame": [(cx - scale / 2) * width, (cy - scale / 2) * height, (cx + scale / 2) * width, (cy + scale / 2) * height]}


def scan(path, args, prompt, key):
    image = Image.open(path).convert("RGB")
    image.thumbnail((LONG_EDGE, LONG_EDGE))
    buffer = io.BytesIO()
    image.save(buffer, "JPEG", quality=80)
    schema = SCHEMA
    if "fx1" in prompt:
        extra = ("fx1", "fy1", "fx2", "fy2")
        schema = SCHEMA | {"properties": SCHEMA["properties"] | {k: {"type": "number"} for k in extra}, "required": SCHEMA["required"] + list(extra)}
    if "- look:" in prompt:
        looks = ["natural", "kiln", "amber", "fjord", "moss", "cinder", "neon", "salt", "graphite"]
        schema = schema | {"properties": schema["properties"] | {"look": {"type": "string", "enum": looks}}, "required": schema["required"] + ["look"]}
    output = {"format": {"type": "json_schema", "schema": schema}}
    if args.effort != "none":
        output["effort"] = args.effort
    body = {
        "model": args.model, "max_tokens": 6000, "output_config": output, "system": prompt,
        "messages": [{"role": "user", "content": [
            {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": base64.b64encode(buffer.getvalue()).decode()}},
            {"type": "text", "text": f"This image is {image.width}x{image.height} pixels. The frame is {SHAPE}, width to height."},
        ]}],
    }
    request = urllib.request.Request("https://api.anthropic.com/v1/messages", json.dumps(body).encode(), {
        "content-type": "application/json", "x-api-key": key, "anthropic-version": "2026-10-21"})
    started = time.time()
    try:
        with urllib.request.urlopen(request, timeout=90) as reply:
            message = json.load(reply)
    except urllib.error.HTTPError as error:
        return {"file": os.path.basename(path), "error": f"{error.code} {error.read()[:300].decode(errors='replace')}"}
    except Exception as error:
        return {"file": os.path.basename(path), "error": str(error)}
    seconds = time.time() - started
    text = next((block["text"] for block in message["content"] if block["type"] == "text"), None)
    result = {"file": os.path.basename(path), "seconds": round(seconds, 2), "usage": message.get("usage"), "size": image.size}
    try:
        result["shot"] = json.loads(text)
        result.update(frame_for(result["shot"], *image.size) or {"error": "empty box"})
    except Exception:
        result["error"] = f"bad answer: {str(text)[:200]}"
    return result


def draw(path, result, out):
    image = Image.open(path).convert("RGB")
    image.thumbnail((LONG_EDGE, LONG_EDGE))
    pen = ImageDraw.Draw(image)
    font = ImageFont.truetype("arial.ttf", 34)
    if "frame" in result:
        pen.rectangle(result["subject"], outline=(0, 220, 255), width=4)
        pen.rounded_rectangle(result["frame"], radius=14, outline=(247, 216, 73), width=8)
        caption = f'{result["shot"]["label"]} | {result["zoom"]}x | {result["seconds"]}s\n{result["shot"]["tip"]}'
    else:
        caption = "ERROR " + result.get("error", "")[:80]
    pen.rectangle([0, 0, image.width, 96], fill=(0, 0, 0))
    pen.text((12, 8), caption, fill=(255, 255, 255), font=font)
    image.save(out, quality=85)
    return image


def sheet(images, out, columns=4, width=480):
    tiles = [im.resize((width, int(im.height * width / im.width))) for im in images]
    if not tiles:
        return
    height = max(t.height for t in tiles)
    rows = (len(tiles) + columns - 1) // columns
    canvas = Image.new("RGB", (columns * width, rows * height), (20, 20, 20))
    for index, tile in enumerate(tiles):
        canvas.paste(tile, ((index % columns) * width, (index // columns) * height))
    canvas.save(out, quality=80)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("name")
    parser.add_argument("--model", default="claude-sonnet-5-5")
    parser.add_argument("--effort", default="low")
    parser.add_argument("--prompt")
    parser.add_argument("--only", default="")
    parser.add_argument("--repeat", type=int, default=1)
    args = parser.parse_args()

    prompt = open(args.prompt, encoding="utf-8").read() if args.prompt else swift_prompt()
    key = api_key()
    photos = sorted(p for p in glob.glob(os.path.join(HERE, "scenes", "*.jpg")) if args.only in os.path.basename(p))
    out = os.path.join(HERE, "runs", args.name)
    os.makedirs(out, exist_ok=True)

    jobs = [(photo, turn) for photo in photos for turn in range(args.repeat)]
    with concurrent.futures.ThreadPoolExecutor(4) as pool:
        results = list(pool.map(lambda job: scan(job[0], args, prompt, key) | {"turn": job[1]}, jobs))

    images = []
    for (photo, turn), result in zip(jobs, results):
        stem = os.path.splitext(result["file"])[0] + (f"-{turn}" if args.repeat > 1 else "")
        images.append(draw(photo, result, os.path.join(out, stem + ".jpg")))
    for start in range(0, len(images), 12):
        sheet(images[start:start + 12], os.path.join(out, f"sheet{start // 12 + 1}.jpg"))
    json.dump({"model": args.model, "effort": args.effort, "prompt": prompt, "results": results},
              open(os.path.join(out, "results.json"), "w"), indent=1)

    times = [r["seconds"] for r in results if "seconds" in r]
    errors = [r for r in results if "error" in r]
    for r in results:
        print(r["file"], r.get("seconds"), r.get("zoom"), r.get("shot", {}).get("look", ""), r.get("shot", {}).get("label"), "|", r.get("shot", {}).get("tip"), r.get("error", ""))
    if times:
        print(f"\n{len(times)} scans: median {statistics.median(times):.1f}s, slowest {max(times):.1f}s, errors {len(errors)}")
        spent = [r["usage"] for r in results if r.get("usage")]
        print("tokens in/out per scan:", sum(u["input_tokens"] for u in spent) // len(spent), sum(u["output_tokens"] for u in spent) // len(spent))


if __name__ == "__main__":
    main()

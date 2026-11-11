"""Downloads Creative Commons photos of everyday scenes (Openverse search) and crops them to the 3:4 viewfinder."""
import io, json, time, urllib.error, urllib.parse, urllib.request
from PIL import Image

TOPICS = ["home office desk", "cafe interior", "city street people", "kitchen", "living room", "street market",
          "park bench", "street at night", "harbour boats", "train station platform", "bedroom", "bar interior",
          "beach people", "library interior", "old town alley", "workshop tools", "garden house", "town square",
          "classroom", "mountain village", "restaurant table", "bookshop", "stadium crowd", "office people"]
PER_TOPIC = 2
AGENT = {"User-Agent": "Mozilla/5.0 scene-bench"}

def fetch(url, tries=4):
    for attempt in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=AGENT), timeout=45) as reply:
                return reply.read()
        except Exception as error:
            last = error
            time.sleep(3 + attempt * 4)
    raise last

import os
credits = json.load(open('scenes/credits.json')) if os.path.exists('scenes/credits.json') else {}
for topic in TOPICS:
    if os.path.exists(f"scenes/{topic.replace(' ', '-')}-1.jpg"):
        continue
    query = urllib.parse.urlencode({"q": topic, "page_size": 12, "size": "large", "category": "photograph"})
    try:
        results = json.loads(fetch("https://api.openverse.org/v1/images/?" + query)).get("results", [])
    except Exception as error:
        print("search failed", topic, error)
        continue
    kept = 0
    for item in results:
        if (item.get("width") or 0) < 1500 or (item.get("height") or 0) < 1100:
            continue
        try:
            image = Image.open(io.BytesIO(fetch(item["url"], tries=2))).convert("RGB")
        except Exception as error:
            continue
        width, height = image.size
        # The viewfinder is 3:4 upright, so take the middle of a wide photo.
        if width / height > 0.75:
            crop = int(height * 0.75)
            image = image.crop(((width - crop) // 2, 0, (width + crop) // 2, height))
        else:
            crop = int(width / 0.75)
            image = image.crop((0, (height - crop) // 2, width, (height + crop) // 2))
        kept += 1
        file = f"{topic.replace(' ', '-')}-{kept}.jpg"
        image.resize((1152, 1536), Image.LANCZOS).save("scenes/" + file, quality=88)
        credits[file] = {"title": item.get("title"), "creator": item.get("creator"),
                         "license": item.get("license"), "page": item.get("foreign_landing_url")}
        print(file, flush=True)
        json.dump(credits, open('scenes/credits.json', 'w'), indent=1)
        if kept == PER_TOPIC:
            break
    time.sleep(1)
json.dump(credits, open("scenes/credits.json", "w"), indent=1)

import os
import yaml
from openai import OpenAI  # or your local client wrapper

# Load config
with open("llm_config.yaml") as f:
    cfg = yaml.safe_load(f)

client = OpenAI(base_url=cfg["base_url"], api_key=cfg["api_key"])

SOURCE_DIR = "data/group2_source"
OUT_DIR = "output/foreground"
os.makedirs(OUT_DIR, exist_ok=True)

prompt_template = """
You are a hypnotic writing assistant. Rewrite or divide the following text into
{count} short, self-contained files (2–6 sentences each). Maintain calm rhythm and thematic independence.
Return results as JSON list of objects with "title" and "body".

TEXT:
{source}
"""

for filename in os.listdir(SOURCE_DIR):
    if not filename.endswith(".txt"):
        continue
    with open(os.path.join(SOURCE_DIR, filename)) as f:
        text = f.read()

    prompt = prompt_template.format(count=7, source=text)

    response = client.chat.completions.create(
        model=cfg["model"],
        messages=[{"role": "user", "content": prompt}],
        temperature=0.8,
        max_tokens=1500,
    )

    outputs = eval(response.choices[0].message.content)
    for i, piece in enumerate(outputs, start=1):
        fname = f"{i:03d}_{piece['title'].replace(' ', '_')}.txt"
        with open(os.path.join(OUT_DIR, fname), "w") as out:
            out.write(piece["body"].strip() + "\n")

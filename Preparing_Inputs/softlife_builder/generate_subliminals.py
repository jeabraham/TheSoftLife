import os
import yaml
from openai import OpenAI  # or your local client wrapper

# Load config
with open("llm_config.yaml") as f:
    cfg = yaml.safe_load(f)

client = OpenAI(base_url=cfg["base_url"], api_key=cfg["api_key"])

SOURCE_DIR = "data/group2_source"
OUT_DIR = "output/subliminals"
os.makedirs(OUT_DIR, exist_ok=True)

prompt_template = prompt = """
Extract 20 short, punchy affirmations (3–12 words each) from this text.
Each should be independent and emotionally charged.
Return as one line per affirmation, do not number the lines

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

    outputs = response.choices[0].message.content.splitlines()
    fname = f"{os.path.splitext(filename)[0]}_subliminals.txt"
    with open(os.path.join(OUT_DIR, fname), "a") as out:
        for line in outputs:
            # Ollama / Mistral really wants to number the affirmations. So, we remove the numbers.
            out.write(''.join(char for char in line.strip() if not (char.isdigit() or (char == '.' and any(
                c.isdigit() for c in line[max(0, line.index(char) - 1):line.index(char)])))) + "\n")

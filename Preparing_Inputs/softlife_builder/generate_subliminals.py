import os
from io import TextIOWrapper
from typing import Any

import yaml
import argparse
from openai import OpenAI  # or your local client wrapper

from generate_foregrounds import chunk_text

prompt_template = """
Extract 10 short, punchy affirmations (3–12 words each) from this text.
Each should be independent and emotionally charged.
Return as one line per affirmation, do not number the lines

TEXT:
{source}
"""

def parse_args():
    parser = argparse.ArgumentParser(description="Generate subliminal files from source texts.")
    parser.add_argument("--source-dir", default="data/group2_source", help="Source directory containing input files")
    parser.add_argument("--out-dir", default="output/subliminals", help="Output directory for generated files")
    parser.add_argument("--chunk-size", type=int, default=2000, help="Maximum characters per chunk when splitting text")
    return parser.parse_args()


def main():
    args = parse_args()

    # Load config
    with open("llm_config.yaml") as f:
        cfg = yaml.safe_load(f)

    client = OpenAI(base_url=cfg["base_url"], api_key=cfg["api_key"])
    os.makedirs(args.out_dir, exist_ok=True)

    for filename in os.listdir(args.source_dir):
        if not filename.endswith(".txt"):
            continue
        with open(os.path.join(args.source_dir, filename)) as f:
            text = f.read()

        text_chunks = chunk_text(text, args.chunk_size)
        for chunk in text_chunks:
    
            outputs = generate_lines(cfg, chunk, client)
            fname = f"{os.path.splitext(filename)[0]}_subliminals_{text_chunks.index(chunk):03d}.txt"
            with open(os.path.join(args.out_dir, fname), "a") as out:
                write_lines(out, outputs)


def write_lines(out: TextIOWrapper, outputs):
    for line in outputs:
        # Ollama / Mistral really wants to number the affirmations. So, we remove the numbers.
        out.write(''.join(char for char in line.strip() if not (char.isdigit() or (char == '.' and any(
            c.isdigit() for c in line[max(0, line.index(char) - 1):line.index(char)])))) + "\n")


def generate_lines(cfg, chunk, client) -> Any:
    prompt = prompt_template.format(count=7, source=chunk)

    response = client.chat.completions.create(
        model=cfg["model"],
        messages=[{"role": "user", "content": prompt}],
        temperature=0.8,
        max_tokens=1500,
    )

    outputs = response.choices[0].message.content.splitlines()
    return outputs


if __name__ == "__main__":
    main()

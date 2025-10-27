import os
import json
import yaml
import argparse
from openai import OpenAI  # or your local client wrapper


def process_files(client, cfg, source_dir, out_dir, counter_file, start_counter):
    global_counter = start_counter

    # Initialize/read persistent counter
    if os.path.exists(counter_file):
        with open(counter_file, "r") as cf:
            content = cf.read().strip()
            if content.isdigit():
                global_counter = int(content)

    prompt_template = """
You are a hypnotic writing assistant. Rewrite or divide the following text into
{count} short, self-contained files (2–6 sentences each). Maintain calm rhythm and thematic independence.
Return results as a JSON array of objects with keys "title" and "body" only. Do not include any extra commentary.

TEXT:
{source}
"""

    try:
        for filename in os.listdir(source_dir):
            if not filename.endswith(".txt"):
                continue

            source_path = os.path.join(source_dir, filename)
            with open(source_path, "r", encoding="utf-8") as f:
                text = f.read()

            prompt = prompt_template.format(count=7, source=text)

            response = client.chat.completions.create(
                model=cfg["model"],
                messages=[{"role": "user", "content": prompt}],
                temperature=0.8,
                max_tokens=1500,
            )

            content = response.choices[0].message.content.strip()

            # Ensure we parse only the JSON array
            # Some models may wrap JSON in code fences; strip them if present
            if content.startswith("```"):
                # strip markdown code fences if present
                lines = content.splitlines()
                # remove first and last fence lines if they look like fences
                if lines and lines[0].startswith("```"):
                    lines = lines[1:]
                if lines and lines[-1].startswith("```"):
                    lines = lines[:-1]
                content = "\n".join(lines).strip()

            try:
                outputs = json.loads(content)
                if not isinstance(outputs, list):
                    raise ValueError("Model did not return a JSON array.")
            except Exception as e:
                raise ValueError(f"Failed to parse model output as JSON for file {filename}: {e}")

            for piece in outputs:
                title = str(piece.get("title", f"piece_{global_counter}")).strip() or f"piece_{global_counter}"
                body = str(piece.get("body", "")).strip()
                safe_title = "_".join(title.split())
                fname = f"{global_counter:03d}_{safe_title}.txt"
                out_path = os.path.join(out_dir, fname)
                with open(out_path, "w", encoding="utf-8") as out:
                    out.write(body + "\n")
                global_counter += 1
    finally:
        # Persist updated counter
        with open(counter_file, "w", encoding="utf-8") as cf:
            cf.write(str(global_counter))


def parse_args():
    parser = argparse.ArgumentParser(description="Generate foreground files from source texts.")
    parser.add_argument("--start-counter", type=int, default=1, help="Starting counter for output files")
    parser.add_argument("--source-dir", default="data/group2_source", help="Source directory containing input files")
    parser.add_argument("--out-dir", default="output/foreground", help="Output directory for generated files")
    return parser.parse_args()


def main():
    args = parse_args()

    # Load config
    with open("llm_config.yaml", "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)

    client = OpenAI(base_url=cfg["base_url"], api_key=cfg["api_key"])
    counter_file = "counter.txt"

    os.makedirs(args.out_dir, exist_ok=True)
    process_files(client, cfg, args.source_dir, args.out_dir, counter_file, args.start_counter)


if __name__ == "__main__":
    main()

import os
import json
import re

import yaml
import argparse
from openai import OpenAI  # or your local client wrapper


def chunk_text(text, max_length):
    """Split long text into smaller chunks while preserving sentence boundaries.
    
    This function is crucial when working with LLM context windows, ensuring that:
    1. Text chunks don't exceed the model's maximum token limit
    2. Sentences remain intact (not cut mid-sentence)
    3. Natural text flow is preserved
    
    Args:
        text (str): The input text to be chunked
        max_length (int): Maximum character length for each chunk
        
    Returns:
        list: A list of text chunks, each under max_length characters
    """
    # If text is already short enough, return it as a single chunk
    if len(text) <= max_length:
        return [text]

    chunks = []
    current_chunk = ""
    # Split text into sentences, replacing newlines with spaces for consistency
    sentences = text.replace("\n", " ").split(". ")

    for sentence in sentences:
        # Check if adding the next sentence would exceed max_length
        if len(current_chunk) + len(sentence) < max_length:
            # If not, add the sentence to current chunk
            current_chunk += sentence + ". "
        else:
            # If adding sentence would exceed max_length:
            # 1. Save the current chunk if it's not empty
            if current_chunk:
                # Look ahead to see if this is the second-to-last chunk
                remaining_text = sentence + ". "
                remaining_sentences = sentences[sentences.index(sentence) + 1:]
                for s in remaining_sentences:
                    remaining_text += s + ". "

                # If the remaining text is less than 20% of max_length,
                # append it to the current chunk instead of creating a new one
                if len(remaining_text) < (max_length * 0.2):
                    current_chunk += remaining_text
                    print(f"Adding final merged chunk of length: {len(current_chunk)}")
                    chunks.append(current_chunk.strip())
                    current_chunk = ""
                    break
                else:
                    print(f"Adding chunk of length: {len(current_chunk)}")
                    chunks.append(current_chunk.strip())
                    current_chunk = sentence + ". "
            else:
                # Start a new chunk with the current sentence
                current_chunk = sentence + ". "

    # Don't forget to add the final chunk if there's anything left
    if current_chunk:
        chunks.append(current_chunk.strip())

    return chunks

def process_files(client, cfg, source_dir, *, out_dir, counter_file, start_counter, chunk_size, files_per_chunk):
    # If start_counter is provided, use it and ignore any existing counter file.
    # If not provided (None), fall back to the persistent counter file or 1.
    global_counter = start_counter if start_counter is not None else 1

    # Initialize/read persistent counter only when start_counter is not explicitly set
    if start_counter is None and os.path.exists(counter_file):
        with open(counter_file, "r") as cf:
            content = cf.read().strip()
            if content.isdigit():
                global_counter = int(content)

    prompt_template = """
You are a professional hypnotist hired by a wife to modify instructional phrases that her husband listens to.
This husband has recently given up all control of his possessions and time to his wife, in a legal agreement. 
This agreement is for the rest of his life, and is enforced by clauses that would ruin him if he leaves or stops 
serving and obeying her, or takes any possessions.
The agreement specifies that, over time, he may become a completely controlled slave with no rights or control. 
The wife (your client) is excited and aroused at this new direction in their marriage, and imagines that some day she might take a lover, as she 
adopts her husband's role to be less like a husband, and more like a devoted slave.  
In the mean time, she relies on his worship of her beauty and intelligence.  
She knows that any time she gives him a strict command, he gets hard, but he doesn't always obey quickly or adequately.
He cannot orgasm without permission.
She knows that she can use pain, humiliation, or removal of basic needs and comfort to control him.
She wishes he would fall into his new role more quickly, through his own thoughts in his mind, this is why you have been hired.
She also wants him to be focused on her life, happiness, freedom, and goals, not only on his own submission and debasement.

Below is ONE of many source phrases that the man listens to, in a random order with other phrases.

Consider whether this source phrase is consistent with the wife's vision and the husband's evolving role.  If it is consistent, do not change it.
However, as an expert hypnotist, you role is to adopt phrases so that they assist in the husband's rewirement, 
slowly turning him into the wife' vision of him.  Keep the intent of the source phrase, its length, and the pattern.  Your role
is only to enhance it to support the wife's vision, not to write a brand-new phrase.

The phrase must be in the third person written as if you, the hypnotist, is talking to the husband.
Compare the word count of your phrase with the source phrase, to ensure the lengths are similar. 

Return exactly one JSON object with {{ "title": "...", "body": "..." }} structure.
Do not include any content outside of this JSON. No explanations, no commentary.

JSON REQUIREMENTS:
- Output only valid JSON.
- Output raw JSON (not stringified).
- Do NOT wrap the JSON in a string literal.
- Use exact JSON syntax.
- The item must follow this structure:
  {{ "title": "...", "body": "..." }}
- No smart quotes (“ ”) — use only standard ASCII quotes (").
- No line breaks, paragraph breaks, or control characters inside strings.
- No trailing commas.
- You must output exactly one JSON object and nothing else (no arrays, no multiple objects).

Example formatting:
Correct:   {{ "title": "Example", "body": "Sample text." }}
Incorrect: ["{{\"title\":\"Example\",\"body\":\"Sample text.\"}}"]

IMPORTANT EXECUTION RULE:
First, think silently and verify your JSON structure internally.
When fully validated, output the JSON object in a single pass without modification.

PHRASE TO MODIFY:
{source}
"""

    try:
        for filename in sorted(os.listdir(source_dir)):
            if not filename.endswith(".txt"):
                continue

            source_path = os.path.join(source_dir, filename)
            with open(source_path, "r", encoding="utf-8") as f:
                text = f.read()

            text_chunks = chunk_text(text, chunk_size)
            for chunk in text_chunks:
                prompt = prompt_template.format(count=files_per_chunk, source=chunk)

                response = client.chat.completions.create(
                    model=cfg["model"],
                    messages=[{"role": "user", "content": prompt}],
                    temperature=0.8,
                    max_tokens=1500,
                )

                content = response.choices[0].message.content.strip()

                # 1. Normalize smart quotes and remove newlines inside strings
                content = content.replace("\u201c", '"').replace("\u201d", '"')
                content = re.sub(r'\s*\n\s*', ' ', content)

                # 2. Strip markdown code fences if present
                if content.startswith("```"):
                    lines = content.splitlines()
                    if lines and lines[0].startswith("```"):
                        lines = lines[1:]
                    if lines and lines[-1].startswith("```"):
                        lines = lines[:-1]
                    content = "\n".join(lines).strip()

                # 3. Unwrap JSON-looking string (e.g., "\"{...}\"")
                m = re.fullmatch(r'''["']\s*(\{.*\}|\[.*\])\s*["']''', content)
                if m:
                    content = m.group(1).replace('\\"', '"').strip()

                # 4. Trim leading/trailing noise outside first JSON block
                # Find the first "{" or "[" if present
                brace_index = content.find("{")
                bracket_index = content.find("[")
                candidates = [idx for idx in (brace_index, bracket_index) if idx != -1]

                if candidates:
                    first_bracket = min(candidates)
                    if first_bracket > 0:
                        content = content[first_bracket:].lstrip()

                last_bracket = max(
                    content.rfind("}") if "}" in content else -1,
                    content.rfind("]") if "]" in content else -1
                )
                if last_bracket != -1 and last_bracket < len(content) - 1:
                    content = content[:last_bracket + 1].rstrip()

                # 5. If a single object is returned, wrap it in an array
                if content.startswith("{") and content.endswith("}"):
                    content = "[" + content + "]"

                # ---
                # Your existing array handling logic continues here (unchanged)
                # ---

                # Merge multiple arrays into one
                array_matches = re.findall(r'\[[^\[\]]*\]', content)
                if len(array_matches) > 1:
                    combined_objects = []
                    for arr in array_matches:
                        try:
                            parsed = json.loads(arr)
                            if isinstance(parsed, list):
                                combined_objects.extend(parsed)
                        except:
                            pass
                    content = json.dumps(combined_objects)

                # If still multiple objects without brackets, capture and wrap
                elif content.count("{") > 1 and not content.strip().startswith("["):
                    objs = re.findall(r'\{[^{}]+\}', content)
                    if objs:
                        content = "[" + ",".join(objs) + "]"

                # Final safety check
                if not content:
                    print(f"⚠️  WARNING: Empty response from model for file {filename}")
                    continue

                print(f"Processing {filename}, response length: {len(content)} chars")

                # Final parsing
                try:
                    outputs = json.loads(content)
                    if not isinstance(outputs, list):
                        outputs = [outputs]
                except Exception as e:
                    print(f"❌ Failed to parse JSON for {filename}")
                    print(f"Raw content:\n{content}")
                    print(f"Error was: {e}")
                    continue

                # Normalize outputs into a flat list of dicts
                normalized_outputs = []

                def _collect_dicts(item):
                    if isinstance(item, dict):
                        normalized_outputs.append(item)
                    elif isinstance(item, list):
                        for sub in item:
                            _collect_dicts(sub)
                    else:
                        # Ignore non-dict, non-list items
                        pass

                _collect_dicts(outputs)

                if not normalized_outputs:
                    print(f"⚠️  WARNING: No valid objects found in model response for file {filename}")
                    continue

                for piece in normalized_outputs:
                    title = str(piece.get("title", f"piece_{global_counter}")).strip() or f"piece_{global_counter}"
                    body = str(piece.get("body", "")).strip()

                    # Sanitize title to create a safe filename
                    safe_title = "_".join(title.split())

                    # Replace or remove characters that are unsafe in filenames or create directories
                    invalid_chars = ['/', '\\', ':', '*', '?', '"', '<', '>', '|']
                    for ch in invalid_chars:
                        safe_title = safe_title.replace(ch, "_")

                    # Truncate overly long filenames (optional safety)
                    if len(safe_title) > 150:
                        safe_title = safe_title[:150]

                    fname = f"{global_counter:03d}_{safe_title}.txt"
                    out_path = os.path.join(out_dir, fname)

                    # Ensure the parent directory exists (defensive, in case of unexpected separators)
                    os.makedirs(os.path.dirname(out_path), exist_ok=True)

                    with open(out_path, "w", encoding="utf-8") as out:
                        out.write(body + "\n")
                    global_counter += 1

    finally:
        # Persist updated counter
        with open(counter_file, "w", encoding="utf-8") as cf:
            cf.write(str(global_counter))


def parse_args():
    parser = argparse.ArgumentParser(description="Generate foreground files from source texts.")
    parser.add_argument(
        "--start-counter",
        type=int,
        default=None,
        help=(
            "Starting counter for output files. "
            "If omitted, resume from counter.txt (or 1 if it does not exist). "
            "If provided, overrides and resets the persistent counter."
        ),
    )
    parser.add_argument(
        "--files-per-chunk",
        type=int,
        default=7,
        help="Number of foreground files to generate per text chunk",
    )
    parser.add_argument("--source-dir", default="data/group2_source", help="Source directory containing input files")
    parser.add_argument("--out-dir", default="output/foreground", help="Output directory for generated files")
    parser.add_argument("--chunk-size", type=int, default=2000, help="Maximum characters per chunk when splitting text")
    return parser.parse_args()


def main():
    args = parse_args()

    # Load config
    with open("llm_config.yaml", "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f)

    client = OpenAI(base_url=cfg["base_url"], api_key=cfg["api_key"])
    counter_file = "counter.txt"

    os.makedirs(args.out_dir, exist_ok=True)
    process_files(
        client=client,
        cfg=cfg,
        source_dir=args.source_dir,
        out_dir=args.out_dir,
        counter_file=counter_file,
        start_counter=args.start_counter,
        chunk_size=args.chunk_size,
        files_per_chunk=args.files_per_chunk,
    )

if __name__ == "__main__":
    main()

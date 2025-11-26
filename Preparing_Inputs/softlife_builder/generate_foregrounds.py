import os
import json
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

def process_files(client, cfg, source_dir, out_dir, counter_file, start_counter, chunk_size, files_per_chunk):
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
You are a hypnotic writing assistant. Rewrite or divide the following text into
{count} short, self-contained files (2–6 sentences each). Maintain calm rhythm and thematic independence.
Each piece should be complete and self-contained, including necessary context and subjects.
Return results as a JSON array of objects with keys "title" and "body" only. Do not include any extra commentary.

TEXT:
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
    
                # Debug: Print the raw response if it's suspiciously short or empty
                if not content:
                    print(f"⚠️  WARNING: Empty response from model for file {filename}")
                    print(f"Skipping file: {filename}")
                    continue
    
                print(f"Processing {filename}, response length: {len(content)} chars")
    
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
                    print(f"❌ Failed to parse JSON for {filename}")
                    print(f"Raw content (first 500 chars):\n{content[:500]}")
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
    process_files(client, cfg, args.source_dir, args.out_dir, counter_file, args.start_counter, args.chunk_size, args.files_per_chunk)


if __name__ == "__main__":
    main()

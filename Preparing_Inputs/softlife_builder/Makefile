# Soft Life Builder — Makefile
# Automates environment setup, dependency install, and local LLM checks.

PYTHON := python3
VENV := .venv
ACTIVATE := $(VENV)/bin/activate

.PHONY: help venv install check-ollama run run-foreground run-subliminal clean

help:
	@echo ""
	@echo "Soft Life Builder Makefile"
	@echo "--------------------------"
	@echo "make venv              Create Python virtual environment"
	@echo "make install           Install dependencies (in venv)"
	@echo "make check-ollama      Verify Ollama is installed and running"
	@echo "make run               Run all generators (foreground + subliminals)"
	@echo "make run-foreground    Run only foreground generation"
	@echo "make run-subliminal    Run only subliminal generation"
	@echo "make clean             Remove build artifacts and virtual environment"
	@echo ""

# Step 1: Create virtual environment
venv:
	@if [ ! -d $(VENV) ]; then \
		echo "Creating virtual environment..."; \
		$(PYTHON) -m venv $(VENV); \
	fi

# Step 2: Install Python dependencies
install: venv
	@echo "Installing dependencies..."
	@. $(ACTIVATE) && pip install --upgrade pip
	@. $(ACTIVATE) && pip install openai pyyaml tqdm

# Step 3: Check that Ollama is available
check-ollama:
	@echo "Checking for Ollama..."
	@which ollama >/dev/null 2>&1 || { echo "❌ Ollama not found. Install from https://ollama.com/download"; exit 1; }
	@ollama list >/dev/null 2>&1 || { echo "❌ Ollama not responding. Start it with 'ollama serve'."; exit 1; }
	@echo "✅ Ollama is installed and running."

# Step 4: Run the generators
run: check-ollama
	@echo "Running all generators..."
	@. $(ACTIVATE) && python generate_foregrounds.py
	@. $(ACTIVATE) && python generate_subliminals.py

run-foreground: check-ollama
	@echo "Running foreground generator..."
	@. $(ACTIVATE) && python generate_foregrounds.py

run-subliminal: check-ollama
	@echo "Running sublimi

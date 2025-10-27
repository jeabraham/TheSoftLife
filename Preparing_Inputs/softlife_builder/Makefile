# Soft Life Builder — Makefile
# Automates environment setup, dependency install, Ollama checks, and LLM pulls.

PYTHON := python3
VENV := .venv
ACTIVATE := $(VENV)/bin/activate

.PHONY: help venv install check-ollama pull-model run run-foreground run-subliminal clean

help:
	@echo ""
	@echo "Soft Life Builder Makefile"
	@echo "--------------------------"
	@echo "make venv                 Create Python virtual environment"
	@echo "make install              Install dependencies (in venv)"
	@echo "make check-ollama         Verify Ollama is installed and running"
	@echo "make pull-model MODEL=x   Pull Ollama model (e.g., mistral, phi3, llama3)"
	@echo "make run                  Run all generators (foreground + subliminals)"
	@echo "make run-foreground       Run only foreground generation"
	@echo "make run-subliminal       Run only subliminal generation"
	@echo "make clean                Remove build artifacts and virtual environment"
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

# Step 4: Pull a model if not already available
pull-model: check-ollama
	@if [ -z "$(MODEL)" ]; then \
		echo "Usage: make pull-model MODEL=mistral"; \
		exit 1; \
	fi
	@if ollama list | grep -q "$(MODEL)"; then \
		echo "✅ Model '$(MODEL)' already installed."; \
	else \
		echo "⬇️  Pulling model '$(MODEL)'..."; \
		ollama pull $(MODEL); \
		echo "✅ Model '$(MODEL)' is ready."; \
	fi

# Step 5: Run the generators
run: check-ollama
	@echo "Running all generators..."
	@. $(ACTIVATE) && python generate_foregrounds.py
	@. $(ACTIVATE) && python generate_subliminals.py

run-foreground: check-ollama
	@echo "Running foreground generator..."
	@. $(ACTIVATE) && python generate_foregrounds.py

run-subliminal: check-ollama
	@echo "Running subliminal generator..."
	@. $(ACTIVATE) && python generate_subliminals.py

# Step 6: Clean
clean:
	@echo "Cleaning up..."
	@rm -rf $(VENV)
	@rm -rf output/__pycache__
	@find output -name "*.txt" -delete
	@echo "✅ Clean complete."

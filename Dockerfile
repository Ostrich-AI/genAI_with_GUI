FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

RUN apt-get update && \
    apt-get install -y \
        curl \
        procps \
        zstd && \
    rm -rf /var/lib/apt/lists/*

# Install Ollama
RUN curl -fsSL https://ollama.com/install.sh | sh

# Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Application code
COPY . .
CMD sh -c '\
echo "========================================" && \
echo "Starting GenAI Inference Container" && \
echo "========================================" && \
\
if command -v nvidia-smi >/dev/null 2>&1; then \
    echo "[INFO] NVIDIA GPU detected"; \
    nvidia-smi || true; \
else \
    echo "[INFO] No NVIDIA GPU detected. Running Ollama on CPU."; \
    export OLLAMA_LLM_LIBRARY=cpu; \
fi && \
\
echo "[INFO] Starting Ollama server..." && \
ollama serve & \
OLLAMA_PID=$! && \
\
echo "[INFO] Waiting for Ollama to become ready..." && \
until curl -s http://127.0.0.1:11434/api/tags >/dev/null 2>&1; do \
    sleep 1; \
done && \
\
echo "[INFO] Ollama is ready" && \
\
if ollama list | grep -q "^tinyllama"; then \
    echo "[INFO] tinyllama already available"; \
else \
    echo "[INFO] Pulling tinyllama model..."; \
    ollama pull tinyllama; \
fi && \
\
echo "[INFO] Running inference..." && \
python scripts/inference.py && \
\
echo "[INFO] Inference completed successfully" && \
echo "[INFO] Output file: output/output.csv" && \
\
kill ${OLLAMA_PID} >/dev/null 2>&1 || true && \
echo "[INFO] Ollama stopped" \
'

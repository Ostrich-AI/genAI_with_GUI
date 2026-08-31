# RAG Inference UI

This repository contains a Streamlit-based inference UI for document RAG workflows.

## What it does

- Ingest PDFs from the `dataset/` directory (and optional uploaded PDFs).
- Build embeddings and index chunks in Qdrant.
- Ask questions over indexed content using a chat interface.
- Generate answers with Ollama or OpenAI models.

## Project structure

- `inference.py` - launcher for the Streamlit app.
- `dataset/` - source PDFs used for ingestion.
- `requirements.txt` - Python dependencies.
- `Dockerfile` - container runtime definition.

## Setup

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Run locally

```bash
python inference.py
```

Then open:

- [http://localhost:8501](http://localhost:8501)

## Qdrant

The app is designed to use Qdrant for vector storage. Ensure Docker is installed/running if your workflow auto-starts Qdrant in a container.

## Notes

- Keep your OpenAI key in environment variables (for example, `OPENAI_API_KEY`) when using OpenAI models.
- Put PDFs in `dataset/` for default ingestion.

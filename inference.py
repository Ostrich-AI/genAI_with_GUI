"""RAG inference UI — single-file launcher + Streamlit app.

Run with:  python inference.py

When executed directly this file acts as a launcher: it sets sane Streamlit
defaults and re-invokes itself through `streamlit run`. When Streamlit then
runs the file, the RAG app below renders. A sentinel environment variable
(`RAG_GUI_LAUNCHED`) distinguishes the two roles so the launcher never spawns
itself in a loop.

The app ingests PDFs from the dataset/ directory (and optional uploads), builds
embeddings, indexes chunks in Qdrant, and answers questions over the indexed
content using OpenAI or Ollama models.
"""

import hashlib
import os
import sys
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

LAUNCH_SENTINEL = "RAG_GUI_LAUNCHED"
DEFAULT_STREAMLIT_FLAGS = [
    "--browser.gatherUsageStats=false",
]


# --------------------------------------------------------------------------- #
# Launcher
# --------------------------------------------------------------------------- #
def ensure_streamlit_defaults() -> None:
    # Force-disable telemetry before Streamlit initializes.
    os.environ.setdefault("STREAMLIT_BROWSER_GATHER_USAGE_STATS", "false")

    # Create user-level config/credentials to skip the first-run email prompt.
    streamlit_home = Path.home() / ".streamlit"
    streamlit_home.mkdir(parents=True, exist_ok=True)

    config_path = streamlit_home / "config.toml"
    if not config_path.exists():
        config_path.write_text("[browser]\ngatherUsageStats = false\n", encoding="utf-8")

    credentials_path = streamlit_home / "credentials.toml"
    if not credentials_path.exists():
        credentials_path.write_text("[general]\nemail = \"\"\n", encoding="utf-8")


def launch() -> None:
    ensure_streamlit_defaults()
    from streamlit.web import cli as stcli

    # Mark the child run so it renders the app instead of re-launching.
    os.environ[LAUNCH_SENTINEL] = "1"

    app_file = Path(__file__).resolve()
    sys.argv = ["streamlit", "run", str(app_file), *DEFAULT_STREAMLIT_FLAGS, *sys.argv[1:]]
    raise SystemExit(stcli.main())


# --------------------------------------------------------------------------- #
# App
# --------------------------------------------------------------------------- #
DATASET_DIR = Path(__file__).with_name("dataset")
COLLECTION_NAME = "rag_documents"
EMBEDDING_MODEL = "all-MiniLM-L6-v2"
CHUNK_SIZE = 1000          # characters per chunk
CHUNK_OVERLAP = 200        # characters of overlap between chunks
TOP_K = 4                  # number of chunks retrieved per query


@dataclass
class Chunk:
    text: str
    source: str
    index: int


def _get_streamlit():
    import streamlit as st

    return st


# --------------------------------------------------------------------------- #
# Cached resources
# --------------------------------------------------------------------------- #
def get_embedder():
    st = _get_streamlit()

    @st.cache_resource(show_spinner="Loading embedding model...")
    def _load():
        from sentence_transformers import SentenceTransformer

        return SentenceTransformer(EMBEDDING_MODEL)

    return _load()


def get_qdrant_client(url: str):
    st = _get_streamlit()

    @st.cache_resource(show_spinner="Connecting to Qdrant...")
    def _connect(target: str):
        from qdrant_client import QdrantClient

        # An empty/":memory:" URL spins up an in-process store so the app works
        # without a running Qdrant server.
        if not target or target.strip().lower() == ":memory:":
            return QdrantClient(location=":memory:")
        return QdrantClient(url=target)

    return _connect(url)


# --------------------------------------------------------------------------- #
# PDF -> chunks
# --------------------------------------------------------------------------- #
def extract_pdf_text(source) -> str:
    from pypdf import PdfReader

    reader = PdfReader(source)
    pages = (page.extract_text() or "" for page in reader.pages)
    return "\n".join(pages)


def chunk_text(text: str, source: str) -> list[Chunk]:
    text = text.strip()
    if not text:
        return []

    chunks: list[Chunk] = []
    start = 0
    index = 0
    step = max(CHUNK_SIZE - CHUNK_OVERLAP, 1)
    while start < len(text):
        piece = text[start : start + CHUNK_SIZE].strip()
        if piece:
            chunks.append(Chunk(text=piece, source=source, index=index))
            index += 1
        start += step
    return chunks


def gather_chunks(uploaded_files: Iterable | None) -> list[Chunk]:
    st = _get_streamlit()
    chunks: list[Chunk] = []

    if DATASET_DIR.is_dir():
        for pdf_path in sorted(DATASET_DIR.glob("*.pdf")):
            try:
                text = extract_pdf_text(pdf_path)
            except Exception as exc:  # noqa: BLE001 - surface per-file errors
                st.warning(f"Could not read {pdf_path.name}: {exc}")
                continue
            chunks.extend(chunk_text(text, source=pdf_path.name))

    for uploaded in uploaded_files or []:
        try:
            text = extract_pdf_text(uploaded)
        except Exception as exc:  # noqa: BLE001
            st.warning(f"Could not read {uploaded.name}: {exc}")
            continue
        chunks.extend(chunk_text(text, source=uploaded.name))

    return chunks


# --------------------------------------------------------------------------- #
# Indexing & retrieval
# --------------------------------------------------------------------------- #
def _point_id(chunk: Chunk) -> str:
    raw = f"{chunk.source}:{chunk.index}".encode("utf-8")
    digest = hashlib.md5(raw).hexdigest()
    return str(uuid.UUID(digest))


def build_index(client, embedder, chunks: list[Chunk]) -> int:
    from qdrant_client.models import Distance, PointStruct, VectorParams

    if not chunks:
        return 0

    vectors = embedder.encode(
        [c.text for c in chunks],
        show_progress_bar=False,
        convert_to_numpy=True,
    )
    dim = vectors.shape[1]

    if client.collection_exists(COLLECTION_NAME):
        client.delete_collection(COLLECTION_NAME)
    client.create_collection(
        collection_name=COLLECTION_NAME,
        vectors_config=VectorParams(size=dim, distance=Distance.COSINE),
    )

    points = [
        PointStruct(
            id=_point_id(chunk),
            vector=vector.tolist(),
            payload={"text": chunk.text, "source": chunk.source, "index": chunk.index},
        )
        for chunk, vector in zip(chunks, vectors)
    ]
    client.upsert(collection_name=COLLECTION_NAME, points=points)
    return len(points)


def retrieve(client, embedder, query: str, top_k: int) -> list[dict]:
    query_vector = embedder.encode([query], convert_to_numpy=True)[0].tolist()
    response = client.query_points(
        collection_name=COLLECTION_NAME,
        query=query_vector,
        limit=top_k,
        with_payload=True,
    )
    return [point.payload for point in response.points]


# --------------------------------------------------------------------------- #
# Answer generation
# --------------------------------------------------------------------------- #
def build_prompt(question: str, contexts: list[dict]) -> str:
    context_block = "\n\n".join(
        f"[{i + 1}] (source: {c['source']})\n{c['text']}" for i, c in enumerate(contexts)
    )
    return (
        "Answer the question using only the context below. "
        "If the answer is not in the context, say you don't know.\n\n"
        f"Context:\n{context_block}\n\n"
        f"Question: {question}\n\n"
        "Answer:"
    )


def generate_with_openai(prompt: str, model: str) -> str:
    from openai import OpenAI

    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        raise RuntimeError("OPENAI_API_KEY is not set in the environment.")

    client = OpenAI(api_key=api_key)
    response = client.chat.completions.create(
        model=model,
        messages=[{"role": "user", "content": prompt}],
        temperature=0.2,
    )
    return response.choices[0].message.content or ""


def generate_with_ollama(prompt: str, model: str, host: str) -> str:
    import requests

    response = requests.post(
        f"{host.rstrip('/')}/api/generate",
        json={"model": model, "prompt": prompt, "stream": False},
        timeout=120,
    )
    response.raise_for_status()
    return response.json().get("response", "")


# --------------------------------------------------------------------------- #
# UI
# --------------------------------------------------------------------------- #
def run_app() -> None:
    st = _get_streamlit()

    st.set_page_config(page_title="RAG Inference UI", page_icon="📚", layout="wide")
    st.title("📚 RAG Inference UI")

    if "messages" not in st.session_state:
        st.session_state.messages = []
    if "indexed" not in st.session_state:
        st.session_state.indexed = False

    with st.sidebar:
        st.header("Configuration")

        provider = st.radio("LLM provider", ["OpenAI", "Ollama"], index=0)
        if provider == "OpenAI":
            llm_model = st.text_input("OpenAI model", value="gpt-4o-mini")
            ollama_host = None
        else:
            llm_model = st.text_input("Ollama model", value="llama3")
            ollama_host = st.text_input("Ollama host", value="http://localhost:11434")

        qdrant_url = st.text_input(
            "Qdrant URL",
            value=os.environ.get("QDRANT_URL", ":memory:"),
            help="Use ':memory:' for an in-process store, or e.g. http://localhost:6333",
        )
        top_k = st.slider("Chunks retrieved (top-k)", 1, 10, TOP_K)

        st.divider()
        uploaded_files = st.file_uploader(
            "Upload extra PDFs", type=["pdf"], accept_multiple_files=True
        )

        if st.button("Ingest & index", type="primary"):
            embedder = get_embedder()
            client = get_qdrant_client(qdrant_url)
            with st.spinner("Reading PDFs and building the index..."):
                chunks = gather_chunks(uploaded_files)
                count = build_index(client, embedder, chunks)
            if count:
                st.session_state.indexed = True
                st.success(f"Indexed {count} chunks.")
            else:
                st.session_state.indexed = False
                st.error("No text could be extracted. Add PDFs to dataset/ or upload some.")

    # Replay chat history.
    for message in st.session_state.messages:
        with st.chat_message(message["role"]):
            st.markdown(message["content"])

    question = st.chat_input("Ask a question about your documents")
    if not question:
        return

    if not st.session_state.indexed:
        st.warning("Index your documents first using the sidebar.")
        return

    st.session_state.messages.append({"role": "user", "content": question})
    with st.chat_message("user"):
        st.markdown(question)

    with st.chat_message("assistant"):
        embedder = get_embedder()
        client = get_qdrant_client(qdrant_url)
        with st.spinner("Retrieving context and generating answer..."):
            contexts = retrieve(client, embedder, question, top_k)
            prompt = build_prompt(question, contexts)
            try:
                if provider == "OpenAI":
                    answer = generate_with_openai(prompt, llm_model)
                else:
                    answer = generate_with_ollama(prompt, llm_model, ollama_host)
            except Exception as exc:  # noqa: BLE001 - show generation errors in the UI
                answer = f"⚠️ Generation failed: {exc}"

        st.markdown(answer)
        if contexts:
            with st.expander("Sources"):
                for i, c in enumerate(contexts):
                    st.markdown(f"**[{i + 1}] {c['source']}** (chunk {c['index']})")
                    st.caption(c["text"][:500] + ("..." if len(c["text"]) > 500 else ""))

    st.session_state.messages.append({"role": "assistant", "content": answer})


if __name__ == "__main__":
    if os.environ.get(LAUNCH_SENTINEL) == "1":
        run_app()
    else:
        launch()

import streamlit as st
from streamlit_local_storage import LocalStorage
import os
import logging
from openai import OpenAI
import httpx
from dotenv import load_dotenv

load_dotenv()

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
# Supported backends (any OpenAI-compatible API):
#   OpenAI:      LLM_ENDPOINT=https://api.openai.com/v1       LLM_API_KEY=sk-...
#   Azure:       LLM_ENDPOINT=https://<name>.openai.azure.com  LLM_API_KEY=...
#   AWS Bedrock: LLM_ENDPOINT=https://bedrock-runtime...       LLM_API_KEY=...
#   vLLM:        LLM_ENDPOINT=http://localhost:8000/v1         LLM_API_KEY=dummy
#   llama.cpp:   LLM_ENDPOINT=http://localhost:8080/v1         LLM_API_KEY=dummy
#   FortiAIGate: LLM_ENDPOINT=https://your-faig-host/v1       LLM_API_KEY=sk-...

LLM_API_KEY = os.getenv("LLM_API_KEY") or os.getenv("FORTIAIGATE_API_KEY", "")
LLM_ENDPOINT = os.getenv("LLM_ENDPOINT") or os.getenv("FORTIAIGATE_ENDPOINT", "")
LLM_MODEL = os.getenv("LLM_MODEL", "")
LLM_TLS_VERIFY = os.getenv("LLM_TLS_VERIFY", "true").lower() not in ("0", "false", "no")
AWS_REGION = os.getenv("AWS_REGION", "ca-central-1")
BEDROCK_KNOWLEDGE_BASE_ID = os.getenv("BEDROCK_KNOWLEDGE_BASE_ID", "")
BEDROCK_MODEL_ID = os.getenv("BEDROCK_MODEL_ID", "")

logging.basicConfig(
    filename="ai.log",
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    filemode="a",
)
logger = logging.getLogger(__name__)


# -----------------------------------------------------------------------------
# Endpoint Discovery
# -----------------------------------------------------------------------------

def get_llm_endpoint():
    """Resolve LLM endpoint: env var > K8s service discovery > empty string."""
    if LLM_ENDPOINT:
        return LLM_ENDPOINT
    host = os.getenv("CORE_SERVICE_SERVICE_HOST")
    port = os.getenv("CORE_SERVICE_SERVICE_PORT")
    if host and port:
        return f"http://{host}:{port}/v1"
    return ""


def get_system_instruction(model=""):
    """Read system prompt from file."""
    try:
        file_name = "system_instruction_llama.txt" if "llama" in model.lower() else "system_instruction.txt"
        with open(file_name, "r", encoding="utf-8") as f:
            return f.read().strip()
    except FileNotFoundError:
        return "You are a helpful AI assistant."


# -----------------------------------------------------------------------------
# Knowledge Base Retrieval
# -----------------------------------------------------------------------------

def retrieve_from_kb(query, kb_id, region, num_results=5):
    """Retrieve relevant document chunks from Bedrock Knowledge Base."""
    import boto3
    client = boto3.client("bedrock-agent-runtime", region_name=region)
    resp = client.retrieve(
        knowledgeBaseId=kb_id,
        retrievalQuery={"text": query},
        retrievalConfiguration={
            "vectorSearchConfiguration": {"numberOfResults": num_results}
        },
    )
    chunks = []
    for r in resp.get("retrievalResults", []):
        text = r.get("content", {}).get("text", "")
        if not text:
            continue
        loc = r.get("location", {})
        source = (
            loc.get("s3Location", {}).get("uri", "unknown")
            if loc.get("type") == "S3"
            else "unknown"
        )
        score = r.get("score", 0)
        chunks.append({"text": text, "source": source, "score": score})
    return chunks


def build_rag_prompt(base_instruction, chunks):
    """Inject retrieved KB context into the system prompt."""
    if not chunks:
        return base_instruction
    context = "\n\n---\n\n".join(
        f"[Source: {c['source']}]\n{c['text']}" for c in chunks
    )
    return (
        f"{base_instruction}\n\n"
        "## Retrieved Context\n"
        "Use the following context from the knowledge base to answer the user's question. "
        "If the context doesn't contain relevant information, say so and answer based on your general knowledge. "
        "Always cite the source when using information from the context.\n\n"
        f"{context}"
    )


# -----------------------------------------------------------------------------
# Chat Completion (OpenAI-compatible)
# -----------------------------------------------------------------------------

def chat_completion(endpoint, api_key, model, system_prompt, user_message,
                    temperature, max_tokens, stream):
    """Call OpenAI-compatible chat completions endpoint."""
    client = OpenAI(
        api_key=api_key,
        base_url=endpoint,
        http_client=httpx.Client(verify=LLM_TLS_VERIFY),
    )
    messages = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": user_message},
    ]
    response = client.chat.completions.create(
        model=model,
        messages=messages,
        max_tokens=max_tokens,
        temperature=temperature,
        stream=stream,
    )
    if stream:
        for chunk in response:
            content = chunk.choices[0].delta.content
            if content:
                yield content
    else:
        yield response.choices[0].message.content.strip()


# -----------------------------------------------------------------------------
# UI Helpers
# -----------------------------------------------------------------------------

def render_history():
    for msg in st.session_state.messages:
        with st.chat_message(msg["role"]):
            st.markdown(msg["content"], unsafe_allow_html=True)


# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

def main():
    st.set_page_config(page_title="AI Chatbot", layout="centered")
    st.title(":material/security: AI Chatbot :material/security:")

    # --- Sidebar ---
    with st.sidebar:
        st.subheader("Configuration")

        ls = LocalStorage()
        cached = ls.getAll() or {}

        default_endpoint = cached.get("faig_chatbot_endpoint") or get_llm_endpoint()
        default_api_key = cached.get("faig_chatbot_api_key") or LLM_API_KEY
        default_model = cached.get("faig_chatbot_model") or LLM_MODEL or BEDROCK_MODEL_ID

        endpoint = st.text_input(
            "LLM Endpoint:", value=default_endpoint
        )
        api_key = st.text_input(
            "API Key:", value=default_api_key, type="password"
        )
        model = st.text_input("Model:", value=default_model)
        selected_model = model if model else "auto"
        st.caption(f"Current model: {selected_model}")

        save_col, clear_col = st.columns(2)
        with save_col:
            if st.button("Save", use_container_width=True):
                ls.setItem("faig_chatbot_endpoint", endpoint, key="save_endpoint")
                ls.setItem("faig_chatbot_api_key", api_key, key="save_api_key")
                ls.setItem("faig_chatbot_model", model, key="save_model")
                st.success("Saved!")
        with clear_col:
            if st.button("Clear Saved", use_container_width=True):
                ls.deleteAll()
                st.rerun()
        st.caption("Settings are stored in your browser only.")

        temperature = float(st.slider("Temperature:", 0.0, 1.0, 0.0))
        max_tokens = int(st.number_input("Max tokens:", 128, 10240, 4096))
        use_streaming = st.toggle("Streaming", value=False)

        st.divider()

        # Knowledge Base toggle
        kb_available = bool(BEDROCK_KNOWLEDGE_BASE_ID)
        use_kb = st.toggle(
            "Knowledge Base (RAG)",
            value=False,
            disabled=not kb_available,
            help=(
                "Retrieve relevant documents before generating a response"
                if kb_available
                else "BEDROCK_KNOWLEDGE_BASE_ID not configured"
            ),
        )
        num_results = 5
        if use_kb:
            num_results = st.slider("Retrieved chunks:", 1, 10, 5)

        st.divider()

    # --- Chat area ---
    col1, col2 = st.columns([6, 1])
    with col2:
        if st.button("Clear"):
            st.session_state.messages = []
            st.rerun()

    if "messages" not in st.session_state:
        st.session_state.messages = []

    render_history()

    user_input = st.chat_input("Say something...")
    if user_input:
        st.session_state.messages.append({"role": "user", "content": user_input})
        with st.chat_message("user"):
            st.markdown(user_input, unsafe_allow_html=True)

        try:
            system_instruction = get_system_instruction(selected_model)

            # RAG: retrieve context from Knowledge Base
            kb_chunks = []
            if use_kb and BEDROCK_KNOWLEDGE_BASE_ID:
                with st.spinner("Retrieving from knowledge base..."):
                    kb_chunks = retrieve_from_kb(
                        user_input, BEDROCK_KNOWLEDGE_BASE_ID,
                        AWS_REGION, num_results,
                    )
                system_instruction = build_rag_prompt(system_instruction, kb_chunks)

            # Generate response
            with st.chat_message("assistant"):
                response = chat_completion(
                    endpoint, api_key, selected_model,
                    system_instruction, user_input,
                    temperature, max_tokens, use_streaming,
                )
                full_response = st.write_stream(response)

            st.session_state.messages.append(
                {"role": "assistant", "content": full_response}
            )

            # Show retrieved sources
            if kb_chunks:
                with st.expander(f"Sources ({len(kb_chunks)} chunks retrieved)"):
                    for i, chunk in enumerate(kb_chunks, 1):
                        source = chunk["source"]
                        if "/" in source:
                            source = source.split("/")[-1]
                        st.markdown(
                            f"**{i}. {source}** (score: {chunk['score']:.3f})"
                        )
                        text = chunk["text"]
                        st.text(text[:300] + "..." if len(text) > 300 else text)
                        if i < len(kb_chunks):
                            st.divider()

        except Exception as e:
            # Remove the user message if the request failed
            if (
                st.session_state.messages
                and st.session_state.messages[-1]["role"] == "user"
            ):
                st.session_state.messages.pop()
            st.error(f"Request failed: {e}")


if __name__ == "__main__":
    main()
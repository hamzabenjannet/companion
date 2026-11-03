---
name: Setup Ollama
description: Set up Ollama.
---

# MacOS Setup

## Install Ollama via Homebrew

```bash
brew install ollama
```

### Run Ollama

```bash
OLLAMA_HOST="0.0.0.0" OLLAMA_FLASH_ATTENTION="1" OLLAMA_KV_CACHE_TYPE="q8_0" /opt/homebrew/opt/ollama/bin/ollama serve
```

> OLLAMA_HOST: The host address for the Ollama server. Setting it to "
> OLLAMA_FLASH_ATTENTION: Enables flash attention for improved performance.
> OLLAMA_KV_CACHE_TYPE: Specifies the key-value cache type for model inference.

### Pull the models

- LLaVA model : Used for multimodal reasoning tasks and image understanding.
- qwen2.5:3b : A 3 billion parameter model for general-purpose tasks.

```bash
ollama pull llava
ollama pull qwen2.5:3b
```

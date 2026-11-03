---
name: Whisper ASR Service
description: Set up Whisper ASR Service for automatic speech recognition using OpenAI's Whisper model.
---

# Docker Setup for Whisper ASR Service

Use the following Docker Compose configuration to set up the Whisper ASR Service, which provides automatic speech recognition capabilities using OpenAI's Whisper model. This service supports GPU acceleration if available.

Create a `docker-compose.yml` file with the following content:

```yaml
# companion-whisper-asr (for automatic speech recognition using OpenAI's Whisper model, with support for GPU acceleration if available)
# --- Whisper ASR Service (Automatic Speech Recognition) ---
# Uses a Python/FastAPI wrapper around OpenAI's Whisper model.
# NOTE: For production use, you *must* have a GPU. Uncomment the 'deploy' block below if your machine has CUDA drivers.
# https://hub.docker.com/r/onerahmet/openai-whisper-asr-webservice
services:
  companion-whisper-asr:
    profiles: ["auto"]
    container_name: companion-whisper-asr
    hostname: companion-whisper-asr
    image: onerahmet/openai-whisper-asr-webservice:latest
    # UNCOMMENT THE 'deploy' SECTION BELOW IF YOU HAVE A CUDA-ENABLED GPU
    # deploy:
    #   resources:
    #     reservations:
    #       devices:
    #         - capabilities: [gpu]
    restart: unless-stopped
    volumes:
      - $PWD/volumes/companion-whisper-asr/whisper:/root/.cache/whisper
    ports:
      - "9000:9000"
    networks:
      - companion_network
    env:
      - ASR_MODEL="medium"
      - ASR_ENGINE="openai_whisper"
  #
networks:
  companion_network:
    name: companion_network
    external: true
```

# Running the Whisper ASR Service

```bash
docker-compose up -d
```

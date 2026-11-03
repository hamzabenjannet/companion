# Companion

A macOS AI companion for live assistance, transcription, and multimodal reasoning. The project is designed to route work across multiple providers and models so the user can get the best possible experience while keeping the system modular, testable, and easy to extend.

This repository is intentionally structured for collaboration. The code follows clear boundaries between capture, processing, providers, tools, and UI so different contributors can work on isolated parts without creating fragile coupling.

## Why this project exists

Modern AI products are often locked to a single model or provider. That limits quality, cost control, and resilience. Companion aims to solve that by creating a provider-agnostic execution layer where the app can:

- use local speech-to-text and local model inference when privacy or offline work matters;
- switch to remote multimodal providers such as Google Gemini and OpenRouter when higher performance or larger context is needed;
- keep the same orchestration logic regardless of the underlying backend;
- prepare the assistant for tool calling, MCP integrations, and file-aware workflows.

The project is built around the idea that an assistant should do more than answer questions. It should observe the user context, react in real time, update files when needed, and integrate with external tools and servers in a controlled way.

## Core goals

- support multiple AI providers and model families behind one consistent interface;
- keep capture, transcription, reasoning, and tool execution separate by responsibility;
- allow local and remote processing to coexist without changing the higher-level app logic;
- provide a clean foundation for future MCP server and tool-using workflows;
- stay easy to maintain, test, and contribute to as the project grows.

## Current status

This repository is in active development and already includes the core architecture for:

- macOS app shell and floating assistant UI;
- microphone, system audio, and screen capture pipeline;
- local transcription and inference integration with Whisper and Ollama;
- remote multimodal provider integrations for Gemini and OpenRouter;
- provider registration and configuration system;
- tool registry and extension points for future MCP-backed actions.

The project is not a single monolithic assistant. It is a modular platform designed to evolve into a richer agentic workflow system.

## Features

### Multimodal provider abstraction

The app does not hardcode one model or vendor. Providers are defined through a common contract and are selected through a configuration layer. This makes it easier to add providers and keep user settings consistent across model changes.

### Local-first architecture

The app can run local speech-to-text and local model flow for privacy-sensitive or self-hosted workflows. This is useful for developers who want reproducible, offline-first behavior without sacrificing a standard remote provider path.

### Remote model support

Provider integrations already include Google Gemini and OpenRouter, with the architecture ready to support additional providers through the same interface and model-selection flow.

### Capture and processing pipeline

The project separates chunk capture, queueing, processing, and transcript management. This makes it easier to reason about streaming behavior, batching, throttling, and debugging without putting all logic into the UI.

### Tool ecosystem ready

The repository includes a `ToolRegistry` and `AssistantTool` abstraction for future built-in tools, file operations, and MCP server calls. The structure is ready for expanding into commands that can inspect files, modify resources, or call external systems.

## Architecture overview

The project is organized into clear layers:

- `App/`: application composition and window setup;
- `Capture/`: microphone, system audio, and screen capture;
- `Pipeline/`: conversation state, chunk processing, assistant orchestration, and prompts;
- `Providers/`: provider contracts, configuration, model registry, and backend implementations;
- `Settings/`: persisted user and provider preferences;
- `Tools/`: tool definitions and invocation system;
- `UI/`: SwiftUI views for controls, transcript, and settings;
- `Storage/`: secure storage and persistence helpers;
- `Debug/`: logging and diagnostic tooling;
- `companionTests/`: architecture and behavior tests.

## Runtime Data-Flow Diagram

The diagram shows how live capture reaches the assistant. The selected processor determines whether Companion uses local Whisper and Ollama services or a remote multimodal provider.

```text
┌─────────────────────┐   ┌─────────────────────┐   ┌─────────────────────┐
│ MicrophoneCapture   │   │ SystemAudioCapture  │   │ ScreenCapture       │
│ microphone audio    │   │ system audio        │   │ screen video        │
└──────────┬──────────┘   └──────────┬──────────┘   └──────────┬──────────┘
           │                         │                         │
           └─────────────────────────┼─────────────────────────┘
                                     ▼
                         ┌─────────────────────┐
                         │ AudioChunker /      │
                         │ VideoChunkWriter    │
                         └──────────┬──────────┘
                                    │ MediaChunk
                                    ▼
                         ┌─────────────────────┐
                         │ MeetingAssistant    │
                         │ ordered chunk queue │
                         └──────────┬──────────┘
                                    │
                                    ▼
                         ┌─────────────────────┐
                         │ ProcessorFactory    │
                         │ selected provider   │
                         └───────┬───────┬─────┘
                                 │       │
                 Local provider  │       │ Remote provider
                                 ▼       ▼
                  ┌──────────────────┐  ┌─────────────────────┐
                  │ Whisper /asr     │  │ Gemini or OpenRouter│
                  │ audio → text     │  │ audio/video + context│
                  └────────┬─────────┘  └──────────┬──────────┘
                           │                       │
                           ▼                       │
                  ┌──────────────────┐             │
                  │ Ollama /api/chat │             │
                  │ transcript →     │             │
                  │ suggestion       │             │
                  └────────┬─────────┘             │
                           └───────────┬───────────┘
                                       ▼
                         ┌─────────────────────┐
                         │ MeetingAssistant    │
                         │ transcript +        │
                         │ suggestions + logs  │
                         └──────────┬──────────┘
                                    ▼
                         ┌─────────────────────┐
                         │ SwiftUI interface   │
                         │ conversation +      │
                         │ capture status      │
                         └─────────────────────┘

      Typed messages ───────────────► selected processor
      ToolRegistry ─────────────────► extension point; provider tool calling
                                      is not implemented yet
```

In local mode, Companion sends audio chunks to Whisper for transcription, then sends transcript context to Ollama for suggestions. In remote mode, the selected provider receives supported audio and video chunks with conversation context and returns transcript and suggestion data. Screen video is skipped in local mode.

## Project structure

```text
companion/
├── App/
│   ├── AppEnvironment.swift
│   └── CompanionApp.swift
├── Capture/
├── Debug/
├── Networking/
├── Pipeline/
│   ├── Prompts/
│   └── ...
├── Providers/
│   ├── Gemini/
│   ├── Local/
│   ├── OpenRouter/
│   └── ...
├── Settings/
├── Storage/
├── Tools/
├── UI/
└── ...

companionTests/
├── ArchitectureTests.swift
├── GeminiClientTests.swift
├── MeetingAssistantTests.swift
├── OpenRouterClientTests.swift
└── ...
```

## SOLID design principles in the codebase

This project was intentionally built with collaboration and maintainability in mind. The main architectural patterns align with SOLID principles:

- Single Responsibility: each area owns one concern, such as capture, providers, or UI rendering.
- Open/Closed: new providers can be added by conforming to provider contracts without changing existing pipeline logic.
- Liskov Substitution: provider and processing objects interact through interfaces and shared capabilities rather than concrete implementations.
- Interface Segregation: the code exposes focused contracts such as `MultimodalClient`, `RemoteProviderDefinition`, and `AssistantTool` rather than large monolithic types.
- Dependency Inversion: the app composes dependencies through `AppEnvironment` and configuration objects instead of hardwiring implementation details.

This makes the project easier to extend with new models, tools, and runtime environments without forcing broad refactors.

## How the app works

The flow is intentionally simple and composable:

1. the app captures audio and screen input;
2. chunks are buffered and queued;
3. a selected processor turns those chunks into transcript or reasoning requests;
4. the configured provider sends the request to a model backend;
5. the assistant responds with transcript, suggestions, or action output;
6. future tool and MCP integrations can route follow-up actions back into the user environment.

That model keeps the system flexible while also keeping the runtime behavior understandable for contributors.

## Provider model

The provider layer is built around a registry-driven design:

- `ProcessingProvider` identifies the provider;
- `RemoteProviderDefinition` describes how to configure and instantiate a client;
- `ProviderConfiguration` stores settings and selected model state;
- `ProcessorFactory` chooses the correct pipeline processor for the runtime mode;
- `RemoteChunkProcessor` and `LocalChunkProcessor` handle provider-specific behavior behind a shared interface.

This is one of the main architectural strengths of the project: the application logic stays stable even as provider integrations evolve.

## Tooling and MCP readiness

The project includes an explicit tool system that is designed for actions such as:

- file inspection and editing;
- command execution;
- model-driven workflow orchestration;
- MCP server calls and structured tool responses.

The current code establishes the extensibility point, and the next step is to fill in concrete tool implementations and provider support for tool-calling workflows.

## Getting started

### Requirements

- macOS
- Xcode
- Apple developer tools for local macOS app development
- Access to a local or remote model backend, such as Ollama or a supported provider API

### Local setup

1. Clone the repository:

```bash
git clone https://github.com/hamzabenjannet/companion.git
cd companion
```

2. Open the project in Xcode:

```bash
open companion.xcodeproj
```

3. Build and run the `companion` scheme.

4. Configure your provider and backend settings in the app:
   - local Whisper endpoint;
   - local Ollama endpoint and model;
   - remote provider credentials;
   - capture settings for microphone, system audio, and screen.

### Optional local backend

The app is designed to work with a local stack such as:

- Whisper for speech-to-text;
- Ollama for local LLM inference;
- optional developer-hosted services for custom workflows.

## Testing

This repository includes unit tests for architecture, provider configuration, local processing, and assistant behavior.

Use Xcode or the command line to run the validation suite:

```bash
xcodebuild -project companion.xcodeproj -scheme companion test
```

The tests cover provider registration, settings persistence, processor selection, and core tool registry behavior.

## Contribution guidelines

We welcome contributions from developers who want to improve the assistant, add new providers, or expand the tool ecosystem.

### Principles

- keep the code modular and protocol-driven;
- respect the existing layer boundaries;
- prefer interfaces over concrete coupling;
- add tests for new behavior;
- document architectural decisions when they add complexity.

### Good first contribution areas

- new provider implementations;
- tool definitions and execution flows;
- prompt and pipeline improvements;
- UX and interaction refinements;
- testing and reliability improvements;
- documentation and onboarding improvements.

### Suggested workflow

1. fork the repository;
2. create a branch for your feature or fix;
3. keep changes focused and well-scoped;
4. validate with the relevant tests;
5. open a pull request with a clear description and rationale.

## Roadmap

See the [project roadmap](roadmap.md) for current capabilities, priorities, and completion criteria.

## Security and privacy

The project is designed to support both local and remote AI workflows. Users should be careful about:

- storing API keys securely;
- validating provider endpoints and model permissions;
- avoiding accidental exposure of sensitive content in logs or debug output;
- limiting tool access to trusted commands and system actions.

The code already includes dedicated storage and transport abstractions to help keep this separation clean.

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

## Acknowledgements

This project builds on the work of the local AI ecosystem, the macOS developer ecosystem, and the broader open source community that continues to make model-driven tools and local-first AI workflows accessible to developers.

## Community and collaboration

The long-term goal is to evolve Companion into a collaborative, open-source AI assistant platform that supports multiple models, multiple providers, and real workflows that help users move from raw output to action.

If you want to help shape the project, start by improving the architecture, adding provider integrations, or building the tool and MCP layer that turns the assistant from a responder into an active collaborator.

---

Built for developers who want a local-first, provider-flexible AI assistant that can grow into a powerful, action-capable workspace partner.

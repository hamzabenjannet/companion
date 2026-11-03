# Companion Roadmap

This roadmap reflects the current codebase and its main product goal: let users combine models and providers in a capable assistant, while keeping each integration testable and safe to extend.

Work is grouped by dependency and user value rather than by calendar date. Priorities can change as implementation and contributor capacity evolve.

## Current Capabilities

The app currently provides:

- microphone, system audio, and screen capture with chunked processing;
- local audio transcription through Whisper and assistant responses through Ollama;
- an Ollama model picker that refreshes installed models from the configured server;
- remote multimodal processing through Google Gemini or OpenRouter, selected by the user;
- provider-specific model lists, persisted settings, and API-key storage in the macOS Keychain;
- transcript, suggestion, capture status, and request/chunk debugging views;
- a `ToolRegistry` and `AssistantTool` contract for registering and invoking tools.

The pipeline selects one provider for a session. Multi-model workflows remain future work. Provider definitions do not yet advertise tool-calling support, and the app has no built-in file-editing tools or MCP client.

## Priorities

### 1. Coordinate Work Across Providers

Let users assign models to clear roles and run a workflow across those models. Keep the existing single-provider flow as the default while adding explicit routing rules.

Work toward:

- defining a provider-neutral request and result contract for orchestration;
- supporting sequential handoffs between configured models;
- allowing users to choose when to use a specialist model, a fallback, or a second opinion;
- preserving conversation context and source information across handoffs;
- reporting per-step status and errors in the UI and debug logs.

**Completion criteria**

- Tests cover routing, successful handoffs, unavailable providers, and partial failures.
- Users can see which provider handled each step.
- Existing local-only and single-remote-provider workflows continue to work.

### 2. Add a Complete Tool-Calling Loop

Connect provider tool-call responses to the existing `ToolRegistry`. Start with a provider and model that support tool calls, then keep the integration behind provider capabilities.

Work toward:

- representing tool calls and results in provider-neutral types;
- sending tool definitions to capable models;
- invoking registered tools and returning their results to the model;
- limiting call count and surfacing malformed arguments, tool errors, and cancellation;
- requiring user approval for actions that change files or run commands.

**Completion criteria**

- An end-to-end test covers model request, tool invocation, tool result, and final model response.
- Providers without tool support continue to work without receiving tool definitions.
- The UI shows the requested action and its result, and asks before a sensitive action.

### 3. Add Workspace-Scoped File Actions

Provide useful file operations while keeping the user in control of the affected workspace.

Work toward:

- letting the user select or grant access to a workspace;
- adding narrowly scoped file read and edit tools;
- previewing proposed changes before writing;
- checking paths against the granted workspace and rejecting access outside it;
- recording approved actions and their outcomes in the session.

**Completion criteria**

- Tests verify allowed paths, rejected paths, edit previews, approval, and write failures.
- The app never writes a proposed change before the user approves it.
- The user can identify which files changed and review the resulting diff.

### 4. Integrate MCP Servers

Connect Model Context Protocol servers through the same controlled tool boundary as built-in actions.

Work toward:

- letting users configure, connect, and disconnect MCP servers;
- discovering server-provided tools and presenting their names and descriptions;
- routing approved tool calls and results through the assistant;
- handling server errors, timeouts, and disconnects without blocking unrelated tools;
- documenting how server credentials and permissions work.

**Completion criteria**

- Tests cover tool discovery, invocation, server failure, and disconnect behavior.
- Users can review the server and tool involved before approving a sensitive action.
- An unavailable MCP server does not prevent local or provider-only workflows.

### 5. Improve Reliability and Release Readiness

Make the core workflows easier to set up, diagnose, and maintain as contributors add providers and tools.

Work toward:

- adding CI for build and test validation;
- improving setup and troubleshooting guidance for local backends and provider credentials;
- showing clear capture-permission, connection, and configuration errors;
- reviewing debug logs for accidental exposure of prompts, transcripts, or credentials;
- expanding tests around capture failures, cancellation, queue behavior, and provider responses;
- documenting provider and tool contribution patterns.

**Completion criteria**

- Contributors can run documented build and test commands on a clean checkout.
- CI validates the supported build and test targets.
- Common setup and permission failures have actionable UI or documentation guidance.
- Tests cover key failure paths in addition to successful requests.

## Design Guardrails

- Keep provider-specific API details inside provider clients.
- Keep orchestration dependent on provider-neutral protocols and capabilities.
- Store provider secrets in the Keychain and never include them in logs.
- Scope tools to the minimum access they need.
- Require approval before destructive or externally visible actions.
- Add tests and documentation when a change introduces a new provider, tool, or workflow.
- Preserve the current local and single-provider flows as new orchestration features arrive.

## Contributing to the Roadmap

Contributors can start with provider tests, setup guidance, error handling, accessibility, or narrowly scoped tools. Before taking on a larger milestone, open an issue to agree on its scope and acceptance criteria.

Roadmap entries describe intended work, not delivery commitments. A milestone is complete when its acceptance criteria pass and the related documentation is current.

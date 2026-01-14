# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

gptel is a simple Large Language Model (LLM) chat client for Emacs with support for multiple models and backends. It provides conversational AI capabilities from anywhere in Emacs.

## Build and Development

This is an Emacs Lisp package. There is no build system - files are loaded directly by Emacs.

**Byte-compile a file:**
```bash
emacs -Q -batch -L . -f batch-byte-compile <file>.el
```

**Byte-compile all files:**
```bash
emacs -Q -batch -L . -f batch-byte-compile *.el
```

**Load and test interactively:**
```elisp
(add-to-list 'load-path "/path/to/gptel")
(require 'gptel)
```

**Package requirements:**
- Emacs 27.1+
- transient 0.7.4+
- compat 30.1.0.0+

## Code Architecture

### Core Files

- **gptel.el** - Main entry point. Defines `gptel-send`, `gptel-mode`, chat buffer UI, state persistence, and the user-facing API
- **gptel-request.el** - Low-level LLM request infrastructure. Defines `gptel-request` API, `gptel-backend` struct, model/tool definitions, and the `gptel-fsm` state machine for handling multi-step LLM interactions
- **gptel-transient.el** - Transient menu system (`gptel-menu`) for configuring backends, models, system prompts, and request parameters

### Backend Providers

Each backend file implements a `gptel-<backend>` struct inheriting from `gptel-backend` (or `gptel-openai`), along with `cl-defmethod` implementations for request/response handling:

- **gptel-openai.el** - OpenAI/ChatGPT (base for OpenAI-compatible APIs). Provides `gptel-make-openai`, `gptel-make-azure`, `gptel-make-gpt4all`
- **gptel-anthropic.el** - Anthropic/Claude. Provides `gptel-make-anthropic`
- **gptel-gemini.el** - Google Gemini. Provides `gptel-make-gemini`
- **gptel-ollama.el** - Ollama local models. Provides `gptel-make-ollama`
- **gptel-openai-extras.el** - PrivateGPT, Perplexity, DeepSeek, xAI. Provides `gptel-make-privategpt`, `gptel-make-perplexity`, `gptel-make-deepseek`, `gptel-make-xai`
- **gptel-kagi.el** - Kagi FastGPT/Summarizer. Provides `gptel-make-kagi`
- **gptel-gh.el** - GitHub Copilot. Provides `gptel-make-gh-copilot`
- **gptel-bedrock.el** - AWS Bedrock. Provides `gptel-make-bedrock`

### Feature Modules

- **gptel-context.el** - Context aggregation (`gptel-add`, `gptel-add-file`). Manages sending additional buffers, regions, files, or directories with requests
- **gptel-org.el** - Org mode integration. Branching conversations, org property-based config, markdown-to-org conversion
- **gptel-rewrite.el** - Text rewriting/refactoring (`gptel-rewrite`). Overlay-based UI for reviewing/accepting LLM-suggested changes
- **gptel-integrations.el** - External package integrations including MCP (Model Context Protocol) via mcp.el

### Key Abstractions

**Backend struct** (`gptel-backend` in gptel-openai.el): Base struct for all LLM providers with slots for host, endpoint, API key, models, request parameters.

**Generic methods**: Backends implement `gptel-curl--parse-stream`, `gptel--parse-response`, `gptel--request-data` via `cl-defmethod` for provider-specific request/response handling.

**FSM (gptel-fsm)**: State machine in gptel-request.el that orchestrates multi-step interactions (tool calls, streaming responses). Handlers in `gptel-send--handlers` define state transitions.

**Tools** (`gptel-tool` struct): Function specifications that LLMs can invoke. Created with `gptel-make-tool`, selected via `gptel-tools` menu.

**Presets** (`gptel-make-preset`): Named bundles of configuration (backend, model, system message, tools) that can be saved and applied.

## Code Style

Follow `.dir-locals.el`:
- No tabs (indent-tabs-mode nil)
- Double space after sentences (sentence-end-double-space t)

Bug references use format: `https://github.com/karthink/gptel/issues/%s`

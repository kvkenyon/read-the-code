# ADR 0001: Native platform and distribution

Status: accepted provisional contract default (RTC-000)

Read the Code’s rebuild targets macOS 14 and uses SwiftUI with narrow AppKit bridges. Distribution is Developer ID plus notarization, outside the Mac App Store; Sparkle 2 is represented as a pinned update dependency placeholder. Launch at login is opt-in, and the app remains a normal Dock application. Local model adapters are Ollama and generic OpenAI-compatible loopback endpoints only.

This ADR records the blueprint defaults for contracts and scaffolding. It does not authorize release, signing, publication, or merge.

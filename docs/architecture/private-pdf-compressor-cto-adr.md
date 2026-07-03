# ADR-001: Private PDF Compressor MVP Architecture

## Status
Accepted for Demo Day planning — 2026-06-19

## Context
The owner has explicitly approved **Private PDF Compressor** and asked the company to proceed right away. The product promise is narrow: compress PDFs privately, with no server upload, and present a demo-ready utility fast.

Boardroom itself is a local-first iPhone command center backed by a Mac relay and Hermes tools. The compressor should follow the same trust posture: private-by-default, no hidden cloud dependency, and clear owner-visible artifacts.

The nearest active product constraint from the company context is urgency: get something demonstrable without inventing an overbuilt platform. There is no existing Private PDF Compressor implementation in this repository yet; this ADR defines the first buildable slice.

## Decision
Build the MVP as a **local-first macOS/iOS utility architecture** with a thin UI and an isolated compression engine.

### Bounded contexts

1. **Document Intake**
   - Import one or more PDF files.
   - Validate that input is a readable PDF.
   - Never copy files outside a sandbox/temp workspace unless the user saves output.

2. **Compression Engine**
   - Owns all compression policy.
   - Provides presets: `Smallest`, `Balanced`, `High Quality`.
   - Produces a deterministic result object: original size, compressed size, reduction percent, output URL, warnings.
   - Must be callable from CLI/tests without UI.

3. **Privacy & Metadata**
   - Strips or preserves metadata based on explicit setting.
   - Defaults to stripping obvious metadata for the private product promise.
   - Performs all work locally.

4. **Result Review**
   - Shows before/after size.
   - Opens preview before save/share.
   - Makes quality trade-off visible instead of pretending every PDF can shrink safely.

### Architecture shape

Use a simple modular monolith, not microservices or event-driven architecture.

```text
UI / App Shell
  -> Document Intake
  -> Compression Use Case
      -> Compression Engine Adapter
      -> Privacy/Metadata Policy
  -> Result Review / Save
```

Dependency direction:

- UI depends on application/use-case layer.
- Use-case layer depends on protocols, not UI.
- Compression implementation sits behind an adapter so we can swap PDFKit, CoreGraphics, Ghostscript, or external CLI tooling later.
- Domain result types remain framework-light where practical.

### Demo Day scope

For the first demo, deliver:

1. Pick a PDF.
2. Choose one preset, default `Balanced`.
3. Compress locally.
4. Show original size, compressed size, percent reduction.
5. Save/share compressed PDF.
6. Show an honest warning if the file cannot be reduced meaningfully.

Out of scope for first demo:

- Cloud sync.
- Batch automation.
- OCR.
- PDF editing.
- Subscription/paywall implementation.
- Exotic PDF repair.

## Consequences

### Easier

- Fast MVP: one clear flow, no backend.
- Strong privacy story: no upload path to audit.
- Testable core: compression can be exercised with fixture PDFs independent of the UI.
- Reversible implementation: adapter boundary lets the team replace the compression backend if quality or file-size results are poor.

### Harder

- On-device/local compression may be less powerful than cloud pipelines.
- PDF compression quality varies sharply by input type; scanned image PDFs behave differently from text/vector PDFs.
- If using an external CLI on Mac for early proof, iOS parity must be checked before promising App Store behavior.
- Metadata stripping can break workflows where users expect author/title fields to remain.

## Technical risk register

| Risk | Impact | Mitigation |
|---|---:|---|
| Compression produces larger file | High | Compare output size; keep original if no improvement; tell user honestly. |
| Visible quality loss | High | Presets with preview; default to Balanced. |
| App Store incompatible backend | High | Keep engine behind adapter; avoid hard-coding Ghostscript-only assumptions into UI. |
| Privacy claim undermined by temp files | High | Temp workspace cleanup; no network calls in compression path. |
| Large PDFs freeze UI | Medium | Run compression off main thread; progress state and cancel later. |

## Initial implementation plan

1. Add a small compression domain model: `CompressionPreset`, `CompressionJob`, `CompressionResult`, `CompressionWarning`.
2. Add `PDFCompressionEngine` protocol.
3. Implement a first local adapter.
   - Preferred for Apple-native app: PDFKit/CoreGraphics if output reduction is acceptable.
   - Fallback for Mac proof: shell adapter to a local tool only if clearly marked non-iOS.
4. Add fixture PDFs and tests for:
   - readable input validation;
   - reduction calculation;
   - no-improvement warning;
   - metadata policy flag;
   - temp cleanup behavior.
5. Build the minimal UI flow after the core passes tests.

## CTO guidance to Builder/QA

- Do not fake compression numbers.
- Do not claim files never leave the device unless the implementation has no network path.
- Do not ship a demo that only renames/copies PDFs.
- The owner needs buyer-value proof: before/after size and a real saved compressed PDF.

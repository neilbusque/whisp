# Third-party notices

Whisp is licensed under MIT. Vendored software retains its original license and copyright notices.

## whisper.cpp and ggml

`Sources/CWhisper/` includes the CPU backend and selected public headers from [whisper.cpp v1.7.4](https://github.com/ggml-org/whisper.cpp/tree/v1.7.4), including ggml. The upstream MIT license is preserved in [Sources/CWhisper/LICENSE](Sources/CWhisper/LICENSE). Comments and notices inside the vendored files remain intact. `scripts/fetch-whisper.sh` reproduces the selected source layout and preserves that license.

## Whisper model weights

Model weights are downloaded separately from the [whisper.cpp model repository](https://huggingface.co/ggerganov/whisper.cpp). They derive from [OpenAI Whisper](https://github.com/openai/whisper), whose code and model weights are released under MIT. The weights are not tracked in this Git repository. Review the upstream model documentation before redistributing a model bundle.

## Platform and services

Apple frameworks are provided by macOS. Optional OpenAI API use requires the user's own account and API key and is governed by OpenAI's service terms, separately from this project's source license.

## Artwork

The Whisp icon in `Resources/` was generated for this project. The repository's MIT license applies to the project's original source and artwork, subject to any rights retained by third-party components.

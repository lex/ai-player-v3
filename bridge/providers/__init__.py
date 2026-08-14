"""
LLM provider interface.

All providers implement the same complete() signature so agent.py
is provider-agnostic. ProviderConfig carries everything provider-specific.

Supported providers:
  "lmstudio"  — openai_compat.py  (LM Studio, Ollama, vLLM, llama.cpp server)
  "openai"    — openai_compat.py  (api.openai.com with real key)
  "custom"    — openai_compat.py  (any OpenAI-compatible endpoint)
  "anthropic" — anthropic.py      (Claude via api.anthropic.com)
"""

from dataclasses import dataclass, field


@dataclass
class ProviderConfig:
    provider: str = "lmstudio"
    model: str = "local-model"
    url: str = "http://localhost:1234/v1"
    api_key: str = "lm-studio"
    timeout: float = 120.0
    max_tokens: int = 8192
    temperature: float = 0.7
    # Reasoning budget for models that think before answering. Sent only when set,
    # so servers that do not know the parameter are unaffected. On a reasoning model
    # the thinking tokens dominate turn latency: they are generated at the same rate
    # as the answer but never reach the game, so a turn can spend most of its time
    # producing text the mod throws away. Check the server's /v1/models
    # supported_parameters for "reasoning_effort" before setting this.
    reasoning_effort: str = ""
    # Free-form extras merged into the request body, for server-specific switches the
    # OpenAI schema has no field for — above all "stop thinking entirely", which is a
    # different knob from reasoning_effort on servers that think by default.
    extra_body: dict = field(default_factory=dict)


def get_provider(config: ProviderConfig):
    """Return the complete() callable for the given provider."""
    if config.provider == "anthropic":
        from .anthropic import complete
    else:
        from .openai_compat import complete
    return complete

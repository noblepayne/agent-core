# Injector virtual-model chain defaults. Host-overridable via
# agent-core.injector.chains (plain values; {} here means "use these").
# Verified-working models only (live probes 2026-08-23, both gateway endpoints).
# The `thunder` chain is intentionally absent: it requires a host-side SSH tunnel.
#
# Verified ✅ (tool-call probed 2026-08-23):
#   zen/x-preview-f-free, zen/hy3-free, zen/big-pickle, zen/nemotron-3-ultra-free,
#   zen/mimo-v2.5-free, zen/laguna-s-2.1-free, zen/nemotron-3.5-lightning-free,
#   openrouter/cohere/north-mini-code:free, openrouter/nvidia/nemotron-3-ultra-550b-a55b:free,
#   openrouter/nvidia/nemotron-3-super-120b-a12b:free, openrouter/nvidia/nemotron-3.5-lightning:free,
#   openrouter/dots-studio/dots-3-note-preview:free, openrouter/poolside/laguna-s-2.1:free,
#   openrouter/poolside/laguna-xs-2.1:free, groq/openai/gpt-oss-120b, groq/openai/gpt-oss-20b,
#   openrouter/openai/gpt-oss-120b, openrouter/deepseek/deepseek-v4-flash-0731
#
# Culled ❌:
#   zen/deepseek-v4-flash-free        — upstream "Model is unavailable" (400) on both hosts
#   zen/ling-3.0-flash-free           — delisted from Zen catalog
#   zen/north-mini-code-free          — delisted from Zen catalog
#   nvidia/z-ai/glm-5.2               — delisted from NIM (GLM-5.2:free on OR is 429-storm)
#   groq/llama-3.1-8b-instant         — delisted from Groq
#   groq/llama-3.3-70b-versatile      — delisted from Groq
#   openrouter/inclusionai/ling-3.0-flash:free — delisted
#   openrouter/openai/gpt-oss-20b:free         — delisted
#   openrouter/qwen/qwen3.7-flash     — now 200-but-no-toolcall (regression since Aug 3)
#   openrouter/google/gemma-4-26b-a4b-it:free  — consistent 429 on both hosts
#
# Provider health notes (2026-08-23):
#   - NVIDIA NIM: EVERY nvidia/* model returns 403 "provider API error" on both
#     hosts — provider-wide key/permission problem, not a model problem. Models
#     kept in chains below; they fast-fall-through via retry-on 403. Fix the NIM
#     key in bifrost to re-enable the tier. New models blocked by this:
#     nvidia/moonshotai/kimi-k3, nvidia/thinkingmachines/inkling.
#   - OpenRouter inkling/inkling-small:free return 403 "only available on agentic
#     harnesses" — bifrost isn't recognized as one; unusable.
#   - openrouter/free router: no endpoints support tool use — unusable for agents.
#   - zen/x-preview-f-free (Ox Alpha stealth) is free only until ~2026-08-27.
#     openrouter/stealth/ox-alpha (probed PASS) is chained directly behind it
#     in brain/coder/researcher/thinker so expiry costs nothing.
_: {
  brain = {
    chain = [
      # === Tier 0: Zen Free (rate-limit diverse, 7 buckets) ===
      "zen/x-preview-f-free"
      # OR stealth mirror of Ox Alpha — survives past Zen free expiry (~Aug 27)
      "openrouter/stealth/ox-alpha"
      "zen/hy3-free"
      "zen/big-pickle"
      "zen/nemotron-3-ultra-free"
      "zen/mimo-v2.5-free"
      "zen/laguna-s-2.1-free"
      "zen/nemotron-3.5-lightning-free"
      # === Tier 1: NVIDIA NIM (provider-wide 403 until key fixed) ===
      "nvidia/minimaxai/minimax-m3"
      "nvidia/nvidia/nemotron-3-ultra-550b-a55b"
      "nvidia/nvidia/nemotron-3-super-120b-a12b"
      "nvidia/openai/gpt-oss-120b"
      # === Tier 2: OpenRouter Free ===
      "openrouter/nvidia/nemotron-3-ultra-550b-a55b:free"
      "openrouter/nvidia/nemotron-3-super-120b-a12b:free"
      "openrouter/cohere/north-mini-code:free"
      "openrouter/dots-studio/dots-3-note-preview:free"
      # === Tier 3: Groq ===
      "groq/openai/gpt-oss-120b"
      # === Tier 4: Paid backstop ===
      "openrouter/openai/gpt-oss-120b"
      "openrouter/deepseek/deepseek-v4-flash-0731"
    ];
    cooldown-minutes = 15;
    retry-on = [400 401 402 403 404 429 500 501 502 503];
  };

  subagent = {
    chain = [
      "zen/nemotron-3.5-lightning-free"
      "zen/mimo-v2.5-free"
      "zen/laguna-s-2.1-free"
      "nvidia/poolside/laguna-xs-2.1"
      "nvidia/nvidia/nemotron-3-super-120b-a12b"
      "openrouter/poolside/laguna-xs-2.1:free"
      "openrouter/poolside/laguna-s-2.1:free"
      "openrouter/nvidia/nemotron-3.5-lightning:free"
      "openrouter/cohere/north-mini-code:free"
      "groq/openai/gpt-oss-20b"
      "groq/openai/gpt-oss-120b"
      "openrouter/openai/gpt-oss-120b"
    ];
    cooldown-minutes = 10;
    retry-on = [400 401 402 403 404 429 500 501 502 503];
  };

  coder = {
    chain = [
      # === Tier 0: Zen Free ===
      "zen/x-preview-f-free"
      # OR stealth mirror of Ox Alpha — survives past Zen free expiry (~Aug 27)
      "openrouter/stealth/ox-alpha"
      "zen/hy3-free"
      "zen/big-pickle"
      "zen/nemotron-3-ultra-free"
      "zen/mimo-v2.5-free"
      "zen/laguna-s-2.1-free"
      "zen/nemotron-3.5-lightning-free"
      # === Tier 1: NVIDIA NIM (403 until key fixed) ===
      "nvidia/poolside/laguna-xs-2.1"
      "nvidia/stepfun-ai/step-3.7-flash"
      "nvidia/openai/gpt-oss-120b"
      # === Tier 2: OpenRouter Free ===
      "openrouter/cohere/north-mini-code:free"
      "openrouter/poolside/laguna-xs-2.1:free"
      "openrouter/poolside/laguna-s-2.1:free"
      "openrouter/dots-studio/dots-3-note-preview:free"
      # === Tier 3: Groq ===
      "groq/openai/gpt-oss-120b"
      # === Tier 4: Paid backstop ===
      "openrouter/openai/gpt-oss-120b"
      "openrouter/deepseek/deepseek-v4-flash-0731"
    ];
    cooldown-minutes = 10;
    retry-on = [400 401 402 403 404 429 500 501 502 503];
  };

  researcher = {
    chain = [
      "zen/x-preview-f-free"
      # OR stealth mirror of Ox Alpha — survives past Zen free expiry (~Aug 27)
      "openrouter/stealth/ox-alpha"
      "zen/hy3-free"
      "zen/big-pickle"
      "zen/nemotron-3-ultra-free"
      "zen/mimo-v2.5-free"
      "zen/laguna-s-2.1-free"
      "nvidia/minimaxai/minimax-m3"
      "nvidia/nvidia/nemotron-3-ultra-550b-a55b"
      "nvidia/nvidia/nemotron-3-super-120b-a12b"
      "openrouter/nvidia/nemotron-3-ultra-550b-a55b:free"
      "openrouter/nvidia/nemotron-3-super-120b-a12b:free"
      "openrouter/dots-studio/dots-3-note-preview:free"
      "groq/openai/gpt-oss-120b"
      "openrouter/deepseek/deepseek-v4-flash-0731"
    ];
    cooldown-minutes = 10;
    retry-on = [400 401 402 403 404 429 500 501 502 503];
  };

  thinker = {
    chain = [
      "zen/x-preview-f-free"
      # OR stealth mirror of Ox Alpha — survives past Zen free expiry (~Aug 27)
      "openrouter/stealth/ox-alpha"
      "zen/hy3-free"
      "zen/big-pickle"
      "zen/nemotron-3-ultra-free"
      "zen/mimo-v2.5-free"
      "nvidia/minimaxai/minimax-m3"
      "nvidia/nvidia/nemotron-3-ultra-550b-a55b"
      "nvidia/nvidia/nemotron-3-super-120b-a12b"
      "openrouter/nvidia/nemotron-3-ultra-550b-a55b:free"
      "openrouter/nvidia/nemotron-3-super-120b-a12b:free"
      "groq/openai/gpt-oss-120b"
      "openrouter/deepseek/deepseek-v4-flash-0731"
    ];
    cooldown-minutes = 10;
    retry-on = [400 401 402 403 404 429 500 501 502 503];
  };

  paid = {
    chain = ["openrouter/deepseek/deepseek-v4-flash-0731"];
    cooldown-minutes = 15;
    retry-on = [400 401 402 403 404 429 500 501 502 503];
  };

  one-shot = {
    chain = [
      "zen/nemotron-3.5-lightning-free"
      "zen/mimo-v2.5-free"
      "zen/laguna-s-2.1-free"
      "openrouter/nvidia/nemotron-3.5-lightning:free"
      "groq/openai/gpt-oss-20b"
    ];
    cooldown-minutes = 10;
    retry-on = [400 401 402 403 404 429 500 501 502 503];
  };
}

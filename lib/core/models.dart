/// One concrete (provider, model) target the router can call.
class Endpoint {
  final String providerId; // e.g. "groq"
  final String baseUrl; // e.g. https://api.groq.com/openai/v1
  final String apiKey;
  final String model;
  final Map<String, String> extraHeaders;

  /// Discovered models the user may pick explicitly; never part of the
  /// automatic ("auto") fallback chain.
  final bool selectableOnly;

  const Endpoint({
    required this.providerId,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.extraHeaders = const {},
    this.selectableOnly = false,
  });

  /// Per-key suffix gives same-provider keys independent fallback slots
  /// without exposing the actual key in logs or UI.
  String get id => '$providerId/$model/${apiKey.hashCode}';
}

class ChatRequest {
  final List<Map<String, dynamic>> messages;
  final double? temperature;
  final double? topP;
  final int? maxTokens;
  final List<Map<String, dynamic>>? tools;

  /// Model preference. Router treats "auto" as "use my chain".
  final String model;

  const ChatRequest({
    required this.messages,
    this.model = 'auto',
    this.temperature,
    this.topP,
    this.maxTokens,
    this.tools,
  });

  Map<String, dynamic> toBody(String modelId) => {
        'model': modelId,
        'messages': messages,
        'stream': true,
        'stream_options': {'include_usage': true},
        if (temperature != null) 'temperature': temperature,
        if (topP != null) 'top_p': topP,
        if (maxTokens != null) 'max_tokens': maxTokens,
        if (tools != null) 'tools': tools,
      };
}

// ---- Errors the router reasons about --------------------------------------

sealed class LlmError implements Exception {
  final String message;
  final int? status;
  const LlmError(this.message, [this.status]);
  @override
  String toString() => 'LlmError($status): $message';
}

/// 429 — cool this key/model down, try the next target.
class RateLimitError extends LlmError {
  final Duration retryAfter;
  const RateLimitError(super.message, this.retryAfter) : super();
}

/// 5xx / timeout / network — short cooldown, try next.
class TransientError extends LlmError {
  const TransientError(super.message, [super.status]);
}

/// 401/403/400/404 — bad key or bad model. Long cooldown, try next.
class FatalError extends LlmError {
  const FatalError(super.message, [super.status]);
}

class AllProvidersFailed implements Exception {
  final Object? lastError;
  final String? reason; // set when no request was actually attempted
  final String? details; // one line per provider: what failed and when it retries
  const AllProvidersFailed(this.lastError, [this.reason, this.details]);
  @override
  String toString() {
    final head = lastError == null && reason != null
        ? reason!
        : 'All providers failed. Last error: $lastError';
    return details == null || details!.isEmpty ? head : '$head\n$details';
  }
}

class ProviderStats {
  int requests = 0;
  int errors = 0;
  int promptTokens = 0;
  int completionTokens = 0;
  int lastLatencyMs = 0; // time to first token
  void record({required int latencyMs, int prompt = 0, int completion = 0}) {
    requests++;
    lastLatencyMs = latencyMs;
    promptTokens += prompt;
    completionTokens += completion;
  }
}

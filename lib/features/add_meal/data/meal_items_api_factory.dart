import 'package:http/http.dart' as http;
import 'package:opennutritracker/core/utils/ai_credential_storage.dart';
import 'package:opennutritracker/core/utils/ai_model_catalogue.dart';
import 'package:opennutritracker/core/utils/plaintext_destination_guard.dart';
import 'package:opennutritracker/features/add_meal/data/anthropic_meal_items_api.dart';
import 'package:opennutritracker/features/add_meal/data/openai_meal_items_api.dart';
import 'package:opennutritracker/features/add_meal/data/openai_compatible_meal_items_api.dart';
import 'package:opennutritracker/features/add_meal/domain/meal_items_api.dart';
import 'package:opennutritracker/features/add_meal/domain/structured_tool_api.dart';

/// Turns a stored selection into the client that will carry it.
///
/// **This is the whole of provider selection.** The interpreters take a
/// [MealItemsApi] and never learn which one they were handed, because the
/// prompt and the schema never depended on the destination — so adding a
/// provider is a case here and a change nowhere else.
///
/// A free function rather than a private helper in `locator.dart` so it can
/// be tested directly. The thing worth asserting is that choosing OpenRouter
/// in settings really produces an OpenRouter request pinned to the vendor
/// the screen named, and that is not observable through the locator.
/// Throws [StateError] where the selection cannot name a model. For the three
/// curated providers that is unreachable — an unknown id falls back to the
/// list's first entry — and for a server the user runs it is prevented one
/// layer up, because the model is part of what "configured" means there
/// (#738) and an unconfigured provider never reaches this function.
/// How long a server the user runs is given to answer.
///
/// Six times the hosted budget, and not a guess. #774 measured a real Ollama
/// on an **M4 Mac mini, 16 GB** — good hardware for this, not a stress case —
/// serving an 8B model: **22–24s from cold, 8–17s warm**. The 20s the hosted
/// clients use failed two of three requests after the model was unloaded, and
/// Ollama unloads after five idle minutes by default, so "the first request
/// of the meal" is the ordinary case rather than an edge one.
///
/// The margin is deliberately generous because the measurement came from the
/// fast end of the range this provider exists to serve. Someone running the
/// same model on an older laptop or a Raspberry Pi is the *point* of "your
/// own server", and a budget tuned to an M4 would quietly exclude them.
///
/// It costs nothing when the server is quick: the timeout is a ceiling on
/// waiting, not a delay. What it does cost is how long the bulk-add screen
/// can sit in its progress state, which is the open half of #774 — the fix
/// there is a progress state that does not read as a hang, not a shorter
/// ceiling.
const ownServerTimeout = Duration(seconds: 120);

/// How long Z.ai is given to answer — reasoning time comes on top of the
/// answer, so the hosted 20s is tuned for a speed these models do not have.
///
/// Measured 2026-10-19 against the coding endpoint at reasoning effort
/// `high`: the same two-photo label-scan request answered in 19 s, 25 s,
/// 25 s and 45 s across four runs, purely from queue load. A 60 s budget
/// failed on-device at evening peak — with the mobile upload still to add —
/// so the ceiling has to clear an outlier run with margin, not the average.
const zaiTimeout = Duration(seconds: 150);

/// How long a setup-time probe waits for an endpoint the user just typed.
///
/// **Defined as [ownServerTimeout] rather than as its own number, and that
/// is the point.** A probe that gave up sooner than a real request would
/// certify an endpoint the app then fails against; one that waited longer
/// would pass an endpoint every real request times out on. Either way the
/// verdict describes a request nobody will ever make. #779's probe is also
/// the *first* request a machine ever sees, so its model is cold by
/// definition — exactly the case #774 measured at 22–24s.
const aiEndpointProbeTimeout = ownServerTimeout;

/// Turns a stored selection into the client that will carry it.
///
/// [timeout] overrides the per-provider default. It exists for the probe,
/// which is not an ordinary request: it runs once at setup, against an
/// address nobody has spoken to yet, and giving up on it early is how a
/// perfectly good server gets recorded as unfit.
MealItemsApi mealItemsApiFor(
  http.Client client,
  AiSelection selection, {
  Duration? timeout,
}) {
  final model = AiModelCatalogue.resolve(selection.provider, selection.modelId);
  final modelId = model?.id ?? selection.modelId;
  if (modelId == null) {
    throw StateError('no model for ${selection.provider.name}');
  }
  // The hosted three cannot be reached without one; only the fourth may have
  // none, and it must not send an empty bearer.
  String key() => selection.apiKey ?? '';

  return switch (selection.provider) {
    AiProvider.anthropic => AnthropicMealItemsApi(
      client,
      key,
      model: modelId,
      timeout: timeout ?? AnthropicMealItemsApi.defaultTimeout,
    ),
    AiProvider.openrouter => OpenAiCompatibleMealItemsApi.openRouter(
      client,
      key,
      model: modelId,
      // Pinned with fallbacks off, so the vendor named in settings is the
      // vendor that served the request rather than the one the slug happens
      // to mention. Unpinned, `anthropic/claude-haiku-4.5` was answered by
      // Amazon Bedrock on every attempt of a three-run probe.
      providers: model?.providers,
      timeout: timeout ?? OpenAiCompatibleMealItemsApi.defaultTimeout,
    ),
    // No pin and no metadata header: reached directly, so there is no broker
    // to constrain and nobody in between to name.
    AiProvider.openai => OpenAiMealItemsApi(
      client,
      key,
      model: modelId,
      timeout: timeout ?? OpenAiMealItemsApi.defaultTimeout,
    ),
    // Z.ai's GLM models on the coding-plan endpoint. The same wire format as
    // OpenRouter without the broker — and with reasoning switched on, because
    // GLM-5.3 cannot be asked not to think. The effort level is the user's
    // choice in the dialog; unset reads as `high`, the level this provider
    // was requested with.
    //
    // The longer budget is not a guess either: reasoning time comes on top of
    // the answer, and 20s was tuned for models that reply immediately.
    AiProvider.zai => OpenAiCompatibleMealItemsApi(
      client,
      key,
      model: modelId,
      endpoint: OpenAiCompatibleMealItemsApi.zaiEndpoint,
      reasoningEffort:
          (selection.reasoningEffort ?? AiReasoningEffort.high).name,
      failureFor: OpenAiCompatibleMealItemsApi.zaiFailureFor,
      // A timeout here is the same fact #774 measured on a user's own
      // server: the model was still working and the network was fine.
      // Left as the default `transient`, it reads "check your connection" —
      // which sent a user whose scan had merely out-thought the budget to
      // debug a 5G link that had been carrying the request the whole time.
      timeoutFailure: MealInterpreterFailure.timeout,
      timeout: timeout ?? zaiTimeout,
    ),
    // The user's own address, no broker, and **no forcing by name**: #733
    // measured that Ollama has no `tool_choice` field at all and llama.cpp
    // silently downgrades an object to "auto", so asking for a named function
    // would be a request most of these servers quietly ignore. `required` is
    // what the app means with one tool defined, and where it is unsupported
    // the reply lands as the existing no-tool-call refusal.
    AiProvider.ownServer => OpenAiCompatibleMealItemsApi(
      // The only provider whose address the user supplies, so the only one
      // where plaintext is possible at all — the other three are compiled-in
      // `https://`. Wrapping here rather than at the call site means any
      // future caller of this factory is covered without knowing to ask.
      GuardedPlaintextClient(client),
      selection.apiKey == null ? null : key,
      model: modelId,
      endpoint: Uri.parse(selection.endpoint!),
      toolChoice: ToolChoiceMode.anyTool,
      // The two halves of #774, and they only make sense together. The
      // longer budget is what stops a cold model load being reported as a
      // failure at all; the classification is what stops the failures that
      // remain — a machine that genuinely cannot serve this model in two
      // minutes — from being described as a network problem.
      timeout: timeout ?? ownServerTimeout,
      timeoutFailure: MealInterpreterFailure.timeout,
    ),
  };
}

/// The same selection, as the structured-tool client the label scan uses.
///
/// Every branch of [mealItemsApiFor] constructs a class that implements
/// both [MealItemsApi] and [StructuredToolApi] — one configuration, one
/// wire format, two seams — so the client is already built and only the
/// type has to change. The cast is checked by
/// `structured_tool_api_factory_test.dart` for every provider, which is
/// what keeps a future branch from quietly opting out of the second seam.
StructuredToolApi structuredToolApiFor(
  http.Client client,
  AiSelection selection,
) => mealItemsApiFor(client, selection) as StructuredToolApi;

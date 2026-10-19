import 'package:opennutritracker/features/add_meal/domain/meal_photo_interpreter.dart';

export 'package:opennutritracker/features/add_meal/domain/meal_interpreter_exception.dart';
export 'package:opennutritracker/features/add_meal/domain/meal_photo_interpreter.dart'
    show MealPhoto;

/// One forced tool call whose schema the caller defines, returning the tool
/// arguments as a JSON object.
///
/// The seam the label scan hangs off. [MealItemsApi] exists so the bulk-add
/// flow's schema — counts and names, never nutrition — is the only schema any
/// provider is asked to fill; that guarantee is about *that* flow, where the
/// model must not invent numbers a database should have measured. Reading a
/// nutrition label off a photograph is the opposite contract: the number on
/// the packaging was measured by the manufacturer, the model transcribes it,
/// and the user reviews every value in the edit-meal form before it is
/// saved. A second schema for that belongs to a second seam rather than a
/// widening of the first, so the provenance rule of the bulk-add schema
/// stays one question — "did anyone add a field there?".
///
/// Implemented by the same three clients [MealItemsApi] has, so every
/// provider the settings screen offers speaks both seams with one
/// configuration. The callers of this one are expected to enforce their own
/// schema in Dart, exactly as `mealItemsFromJson` does: nothing a model
/// returns is trusted past a parser that drops what it does not recognise.
abstract interface class StructuredToolApi {
  /// Raises [MealInterpreterException] for every ordinary failure, carrying
  /// the provider's status code where there was one.
  ///
  /// [photos] may be empty — the call is then text-only, which the nutrient
  /// merge step is. [userPrompt] is the user-turn text; [system] the rules.
  Future<Map<String, dynamic>> requestToolJson({
    required String system,
    required String userPrompt,
    required List<MealPhoto> photos,
    required String toolName,
    required String toolDescription,
    required Map<String, dynamic> toolSchema,
  });
}

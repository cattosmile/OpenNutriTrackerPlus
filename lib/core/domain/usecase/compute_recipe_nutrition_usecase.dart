import 'package:opennutritracker/core/domain/entity/recipe_ingredient_entity.dart';
import 'package:opennutritracker/core/utils/calc/unit_calc.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_nutriments_entity.dart';

class ComputeRecipeNutritionResult {
  final MealNutrimentsEntity perHundredG;
  final double totalWeightG;

  const ComputeRecipeNutritionResult({
    required this.perHundredG,
    required this.totalWeightG,
  });
}

class ComputeRecipeNutritionUseCase {
  // Treat a serving as the snapshot meal's serving weight in grams.
  // Treat 1 ml ≈ 1 g per the v1 simplification (see plan §3, decision 3).
  // Returns null when the unit can't be converted (e.g. a "serving" unit
  // on an ingredient that has no servingQuantity).
  double? convertAmountToGrams({
    required double amount,
    required String unit,
    double? servingQuantityG,
  }) {
    switch (unit) {
      case 'g':
      case 'gml':
      case 'g/ml':
        return amount;
      case 'ml':
      case 'l':
      case 'cl':
      case 'dl':
        if (unit == 'l') return amount * 1000;
        if (unit == 'cl') return amount * 10;
        if (unit == 'dl') return amount * 100;
        return amount;
      case 'kg':
        return amount * 1000;
      case 'mg':
        return amount / 1000;
      case 'oz':
        return UnitCalc.ozToG(amount);
      case 'fl oz':
      case 'fl.oz':
        return UnitCalc.flOzToMl(amount);
      case 'serving':
        if (servingQuantityG == null || servingQuantityG <= 0) return null;
        return amount * servingQuantityG;
      default:
        return null;
    }
  }

  ComputeRecipeNutritionResult compute(
    List<RecipeIngredientEntity> ingredients, {
    double? totalWeightOverride,
  }) {
    if (ingredients.isEmpty) {
      return ComputeRecipeNutritionResult(
        perHundredG: MealNutrimentsEntity.empty(),
        totalWeightG: 0,
      );
    }

    final totalWeightG =
        totalWeightOverride ??
        ingredients.fold<double>(0, (sum, i) => sum + i.convertedAmountG);

    if (totalWeightG <= 0) {
      return ComputeRecipeNutritionResult(
        perHundredG: MealNutrimentsEntity.empty(),
        totalWeightG: 0,
      );
    }

    // For every nutrient field: sum (value100 ?? 0) × convertedAmountG / 100
    // across ingredients, but track whether *any* ingredient had a non-null
    // value for that field. If none did, the recipe field stays null too —
    // that preserves the existing UI behaviour of hiding unknown micros.
    //
    // The previous shape called a per-nutrient helper 24 times, each doing
    // its own anyNonNull() + total() pass. Restructuring to a single sweep
    // over the ingredient list keeps the same null-stays-null semantics
    // while collapsing 48 traversals into 1.
    final acc = _NutrientAccumulator();
    for (final ingredient in ingredients) {
      acc.addFrom(
        ingredient.snapshotMeal.nutriments,
        ingredient.convertedAmountG,
      );
    }

    final per = acc.toEntityPerHundredG(totalWeightG);

    return ComputeRecipeNutritionResult(
      perHundredG: per,
      totalWeightG: totalWeightG,
    );
  }
}

/// Single-pass accumulator for the nutrient fields on
/// [MealNutrimentsEntity]. The four macros are tracked explicitly; every
/// micronutrient flows through the entity's key contract
/// ([MealNutrimentsEntity.micronutrientByKey] /
/// [MealNutrimentsEntity.micronutrientKeys] /
/// [MealNutrimentsEntity.copyWithMicronutrients]), so a field added there
/// aggregates here without this file changing again. Each micro key has a
/// running sum, present only while some ingredient carried a non-null
/// value for it — that flag drives the existing "hide unknown micros" UI
/// behaviour: if every ingredient was silent on, say, vitamin B6, the
/// recipe stays silent too rather than showing a misleading 0.
class _NutrientAccumulator {
  double _energyKcal = 0, _carbs = 0, _fat = 0, _protein = 0;
  bool _hasEnergy = false, _hasCarbs = false, _hasFat = false;
  bool _hasProtein = false;
  final Map<String, double> _microSums = {};

  void addFrom(MealNutrimentsEntity n, double convertedAmountG) {
    final ratio = convertedAmountG / 100;

    if (n.energyKcal100 != null) _hasEnergy = true;
    _energyKcal += (n.energyKcal100 ?? 0) * ratio;

    if (n.carbohydrates100 != null) _hasCarbs = true;
    _carbs += (n.carbohydrates100 ?? 0) * ratio;

    if (n.fat100 != null) _hasFat = true;
    _fat += (n.fat100 ?? 0) * ratio;

    if (n.proteins100 != null) _hasProtein = true;
    _protein += (n.proteins100 ?? 0) * ratio;

    for (final key in MealNutrimentsEntity.micronutrientKeys) {
      final value = n.micronutrientByKey(key);
      if (value == null) continue;
      _microSums.update(
        key,
        (sum) => sum + value * ratio,
        ifAbsent: () => value * ratio,
      );
    }
  }

  MealNutrimentsEntity toEntityPerHundredG(double totalWeightG) {
    double? norm(double sum, bool anyPresent) =>
        anyPresent ? sum * 100 / totalWeightG : null;

    // The constructor's required base trio is meaningless here —
    // copyWithMicronutrients overwrites all three from the map.
    return MealNutrimentsEntity(
      energyKcal100: norm(_energyKcal, _hasEnergy),
      carbohydrates100: norm(_carbs, _hasCarbs),
      fat100: norm(_fat, _hasFat),
      proteins100: norm(_protein, _hasProtein),
      sugars100: null,
      saturatedFat100: null,
      fiber100: null,
    ).copyWithMicronutrients({
      for (final entry in _microSums.entries)
        entry.key: entry.value * 100 / totalWeightG,
    });
  }
}

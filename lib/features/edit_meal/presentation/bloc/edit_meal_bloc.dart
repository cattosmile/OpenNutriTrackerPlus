import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:opennutritracker/core/data/data_source/custom_meal_data_source.dart';
import 'package:opennutritracker/core/data/dbo/meal_dbo.dart';
import 'package:opennutritracker/core/data/repository/config_repository.dart';
import 'package:opennutritracker/core/domain/usecase/get_config_usecase.dart';
import 'package:opennutritracker/core/utils/extensions.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_entity.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_nutriments_entity.dart';

part 'edit_meal_state.dart';

part 'edit_meal_event.dart';

/// Computes the per-100g scale factor for a typed base-quantity string.
///
/// `createNewMealEntity` multiplies every typed nutriment by this factor
/// before storing it on the per-100g fields, so values typed at the
/// user's chosen base quantity land in the canonical "per 100" slot.
/// Lifted out of the bloc so it can be unit-tested directly without
/// instantiating the bloc's dependency graph — see
/// `test/unit_test/edit_meal_simple_mode_scale_test.dart` for the
/// regression coverage on Simple-mode (#232).
///
/// A base of 0 falls back to the no-op factor like unparseable input does:
/// `100 / 0` is infinite, and a nutriment typed as 0 times infinity is NaN,
/// which reached the stored meal, the intake and the day's totals, and
/// blanked every card that rounds a total with `toInt()` (#1254).
double factorTo100gFromBase(String baseQuantity) {
  final parsed = double.tryParse(baseQuantity);
  return (parsed != null && parsed.isFinite && parsed > 0) ? (100 / parsed) : 1;
}

/// Custom meal form view mode (#232). Persisted on ConfigDBO so the form
/// remembers which view the user prefers between sessions.
enum CustomMealFormMode {
  simple,
  advanced;

  static CustomMealFormMode fromString(String? value) {
    if (value == advanced.name) return advanced;
    // Simple is the default for new users and for any unrecognised value:
    // it removes the per-100g cognitive load and matches the most common
    // request from the people who filed #232.
    return simple;
  }
}

class EditMealBloc extends Bloc<EditMealEvent, EditMealState> {
  final GetConfigUsecase _getConfigUsecase;
  final CustomMealDataSource _customMealDataSource; // #267
  final ConfigRepository _configRepository;

  EditMealBloc(
    this._getConfigUsecase,
    this._customMealDataSource,
    this._configRepository,
  ) : super(EditMealInitial()) {
    on<InitializeEditMealEvent>((event, emit) async {
      emit(EditMealLoadingState());

      final config = await _getConfigUsecase.getConfig();
      final mode = CustomMealFormMode.fromString(
        await _configRepository.getCustomMealFormMode(),
      );
      emit(
        EditMealLoadedState(
          usesImperialUnits: config.usesImperialFoodUnits,
          formMode: mode,
        ),
      );
    });
  }

  /// Persist the user's form view preference so the next custom-meal entry
  /// opens in the same mode they last used (#232).
  Future<void> setFormMode(CustomMealFormMode mode) async {
    await _configRepository.setCustomMealFormMode(mode.name);
  }

  MealEntity createNewMealEntity(
    MealEntity oldMealEntity,
    String nameText,
    String brandsText,
    String mealQuantityText,
    String servingQuantityText,
    String baseQuantity,
    String? unitText,
    String kcalText,
    String carbsText,
    String fatText,
    String proteinText, {
    Map<String, String?>? microTexts,
    String? barcodeOverride,
    String? localImagePathOverride,
    bool clearLocalImagePath = false,
  }) {
    final double factorTo100g = factorTo100gFromBase(baseQuantity);

    double? multiplyIfNotNull(double? nutrimentValue) {
      return nutrimentValue != null ? nutrimentValue * factorTo100g : null;
    }

    double? fromTextOrOld(String? text, double? oldValue) =>
        multiplyIfNotNull(text?.toDoubleOrNull() ?? oldValue);

    // Every micronutrient — the base three under the header plus each
    // section field — routes through the same two-step lookup: the typed
    // text wins, else the old entity's value carries over, and either way
    // the base-quantity factor scales it to per-100g. Keys are the entity
    // field names; micronutrientByKey is the read side of that contract.
    final oldNutriments = oldMealEntity.nutriments;
    double? micro(String key) =>
        fromTextOrOld(microTexts?[key], oldNutriments.micronutrientByKey(key));

    final newMealNutriments = MealNutrimentsEntity(
      energyKcal100: multiplyIfNotNull(kcalText.toDoubleOrNull()),
      carbohydrates100: multiplyIfNotNull(carbsText.toDoubleOrNull()),
      fat100: multiplyIfNotNull(fatText.toDoubleOrNull()),
      proteins100: multiplyIfNotNull(proteinText.toDoubleOrNull()),
      sugars100: micro('sugars100'),
      saturatedFat100: micro('saturatedFat100'),
      fiber100: micro('fiber100'),
      sodium100: micro('sodium100'),
      calcium100: micro('calcium100'),
      iron100: micro('iron100'),
      potassium100: micro('potassium100'),
      magnesium100: micro('magnesium100'),
      vitaminD100: micro('vitaminD100'),
      vitaminB12100: micro('vitaminB12100'),
      monounsaturatedFat100: micro('monounsaturatedFat100'),
      polyunsaturatedFat100: micro('polyunsaturatedFat100'),
      transFat100: micro('transFat100'),
      cholesterol100: micro('cholesterol100'),
      phosphorus100: micro('phosphorus100'),
      zinc100: micro('zinc100'),
      chloride100: micro('chloride100'),
      vitaminA100: micro('vitaminA100'),
      vitaminC100: micro('vitaminC100'),
      vitaminE100: micro('vitaminE100'),
      vitaminK100: micro('vitaminK100'),
      vitaminB1100: micro('vitaminB1100'),
      vitaminB2100: micro('vitaminB2100'),
      niacin100: micro('niacin100'),
      vitaminB5100: micro('vitaminB5100'),
      vitaminB6100: micro('vitaminB6100'),
      vitaminB7100: micro('vitaminB7100'),
      vitaminB9100: micro('vitaminB9100'),
      choline100: micro('choline100'),
      copper100: micro('copper100'),
      manganese100: micro('manganese100'),
      selenium100: micro('selenium100'),
      iodine100: micro('iodine100'),
      fluoride100: micro('fluoride100'),
      chromium100: micro('chromium100'),
      molybdenum100: micro('molybdenum100'),
      ala100: micro('ala100'),
      epa100: micro('epa100'),
      dha100: micro('dha100'),
      caffeine100: micro('caffeine100'),
    );

    return MealEntity(
      // #167: a user-typed or scanned barcode wins over whatever came
      // from the originating OFF/FDC record, but only when the override
      // was actually supplied. Empty-string is treated as "clear" so a
      // user can erase a stored code by blanking the field.
      code: barcodeOverride ?? oldMealEntity.code,
      name: nameText.toStringOrNull(),
      brands: brandsText.toStringOrNull(),
      url: oldMealEntity.url,
      thumbnailImageUrl: oldMealEntity.thumbnailImageUrl,
      mainImageUrl: oldMealEntity.mainImageUrl,
      mealQuantity: mealQuantityText.toStringOrNull(),
      mealUnit: unitText,
      servingQuantity: servingQuantityText.toDoubleOrNull(),
      // The custom-meal form has a single unit selector shared by the meal
      // size and the serving size, so the serving unit is that selected unit
      // — not the serving *quantity* text, which used to land here and made
      // the meal-detail serving option read "Serving (50.0 50)" instead of
      // "Serving (50 g)" (#495).
      servingUnit: unitText,
      servingSize: oldMealEntity.servingSize,
      nutriments: newMealNutriments,
      source: oldMealEntity.source,
      // #64 follow-up: a freshly-picked local photo wins over what was
      // on the old entity; a clear flag means the user removed the
      // photo and the slug should be wiped from the saved meal.
      localImagePath: clearLocalImagePath
          ? null
          : (localImagePathOverride ?? oldMealEntity.localImagePath),
    );
  }

  /// Persist custom meal template so it appears in Recent Meals before first log (#267)
  Future<void> saveCustomMeal(MealEntity mealEntity) async {
    await _customMealDataSource.saveCustomMeal(
      MealDBO.fromMealEntity(mealEntity),
    );
  }
}

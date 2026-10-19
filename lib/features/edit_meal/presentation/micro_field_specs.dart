import 'package:flutter/material.dart';
import 'package:opennutritracker/core/styles/app_palette.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_nutriments_entity.dart';
import 'package:opennutritracker/generated/l10n.dart';

/// Label getter for a micronutrient field/section header — resolved against
/// the generated [S] localization at build time.
typedef MicroLabel = String Function(S s);

/// One editable micronutrient in the custom-meal form: the entity field
/// key (see [MealNutrimentsEntity.micronutrientByKey]), its label and the
/// unit the field shows as a suffix.
class MicroFieldSpec {
  final String key;
  final MicroLabel label;
  final String unit;

  const MicroFieldSpec(this.key, this.label, this.unit);
}

/// A labelled group of micronutrient fields in the advanced form.
class MicroSectionSpec {
  final MicroLabel header;
  final List<MicroFieldSpec> fields;

  const MicroSectionSpec(this.header, this.fields);
}

/// The one heading style every nutrient-section header uses, on every
/// surface (edit form, diary panel, trends averages) — so a section title
/// never changes size between screens or within one list.
class MicroSectionHeading extends StatelessWidget {
  final String text;

  const MicroSectionHeading(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = isDark ? AppPalette.dark : AppPalette.light;
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w700,
        color: palette.textStrong,
      ),
    );
  }
}

/// The advanced form's micronutrient sections. Keys are the entity field
/// names — the same strings the edit form's controllers and
/// `EditMealBloc.createNewMealEntity`'s `microTexts` map are keyed by.
///
/// The diary nutrient panel and the trends averages group their rows
/// through this same list, so all three surfaces agree on what belongs
/// where.
final List<MicroSectionSpec> microSections = <MicroSectionSpec>[
  MicroSectionSpec((s) => s.editMealCarbsSectionLabel, <MicroFieldSpec>[
    MicroFieldSpec('fiber100', (s) => s.fiberLabel, 'g'),
    MicroFieldSpec('sugars100', (s) => s.sugarLabel, 'g'),
  ]),
  MicroSectionSpec((s) => s.editMealFatsSectionLabel, <MicroFieldSpec>[
    MicroFieldSpec('saturatedFat100', (s) => s.saturatedFatLabel, 'g'),
    MicroFieldSpec(
      'monounsaturatedFat100',
      (s) => s.monounsaturatedFatLabel,
      'g',
    ),
    MicroFieldSpec(
      'polyunsaturatedFat100',
      (s) => s.polyunsaturatedFatLabel,
      'g',
    ),
    MicroFieldSpec('transFat100', (s) => s.transFatLabel, 'g'),
    MicroFieldSpec('cholesterol100', (s) => s.cholesterolLabel, 'mg'),
  ]),
  MicroSectionSpec((s) => s.editMealMineralsSectionLabel, <MicroFieldSpec>[
    MicroFieldSpec('sodium100', (s) => s.sodiumLabel, 'mg'),
    MicroFieldSpec('potassium100', (s) => s.potassiumLabel, 'mg'),
    MicroFieldSpec('magnesium100', (s) => s.magnesiumLabel, 'mg'),
    MicroFieldSpec('calcium100', (s) => s.calciumLabel, 'mg'),
    MicroFieldSpec('phosphorus100', (s) => s.phosphorusLabel, 'mg'),
    MicroFieldSpec('zinc100', (s) => s.zincLabel, 'mg'),
    MicroFieldSpec('iron100', (s) => s.ironLabel, 'mg'),
    MicroFieldSpec('chloride100', (s) => s.chlorideLabel, 'mg'),
  ]),
  MicroSectionSpec((s) => s.editMealVitaminsSectionLabel, <MicroFieldSpec>[
    MicroFieldSpec('vitaminA100', (s) => s.vitaminALabel, 'µg'),
    MicroFieldSpec('vitaminC100', (s) => s.vitaminCLabel, 'mg'),
    MicroFieldSpec('vitaminD100', (s) => s.vitaminDLabel, 'µg'),
    MicroFieldSpec('vitaminE100', (s) => s.vitaminELabel, 'mg'),
    MicroFieldSpec('vitaminK100', (s) => s.vitaminKLabel, 'µg'),
    MicroFieldSpec('vitaminB1100', (s) => s.vitaminB1Label, 'mg'),
    MicroFieldSpec('vitaminB2100', (s) => s.vitaminB2Label, 'mg'),
    MicroFieldSpec('niacin100', (s) => s.niacinLabel, 'mg'),
    MicroFieldSpec('vitaminB5100', (s) => s.vitaminB5Label, 'mg'),
    MicroFieldSpec('vitaminB6100', (s) => s.vitaminB6Label, 'mg'),
    MicroFieldSpec('vitaminB7100', (s) => s.vitaminB7Label, 'µg'),
    MicroFieldSpec('vitaminB9100', (s) => s.vitaminB9Label, 'µg'),
    MicroFieldSpec('vitaminB12100', (s) => s.vitaminB12Label, 'µg'),
    MicroFieldSpec('choline100', (s) => s.cholineLabel, 'mg'),
  ]),
  MicroSectionSpec((s) => s.editMealTraceElementsSectionLabel, <MicroFieldSpec>[
    MicroFieldSpec('copper100', (s) => s.copperLabel, 'µg'),
    MicroFieldSpec('manganese100', (s) => s.manganeseLabel, 'mg'),
    MicroFieldSpec('selenium100', (s) => s.seleniumLabel, 'µg'),
    MicroFieldSpec('iodine100', (s) => s.iodineLabel, 'µg'),
    MicroFieldSpec('fluoride100', (s) => s.fluorideLabel, 'mg'),
    MicroFieldSpec('chromium100', (s) => s.chromiumLabel, 'µg'),
    MicroFieldSpec('molybdenum100', (s) => s.molybdenumLabel, 'µg'),
  ]),
  MicroSectionSpec((s) => s.editMealOmega3SectionLabel, <MicroFieldSpec>[
    MicroFieldSpec('ala100', (s) => s.alaLabel, 'g'),
    MicroFieldSpec('epa100', (s) => s.epaLabel, 'g'),
    MicroFieldSpec('dha100', (s) => s.dhaLabel, 'g'),
    MicroFieldSpec('caffeine100', (s) => s.caffeineLabel, 'mg'),
  ]),
];

/// The localized label for any per-100 nutrient key the edit form and the
/// AI scan share — macros and the three base micro rows live outside the
/// sections, everything else through [microSections].
String nutrientFieldLabel(S s, String key) => switch (key) {
  'energyKcal100' => s.mealEnergyLabel,
  'carbohydrates100' => s.mealCarbsLabel,
  'fat100' => s.mealFatLabel,
  'proteins100' => s.mealProteinLabel,
  'fiber100' => s.fiberLabel,
  'saturatedFat100' => s.saturatedFatLabel,
  'sugars100' => s.sugarLabel,
  _ => _sectioned[key]?.label(s) ?? key,
};

final Map<String, MicroFieldSpec> _sectioned = {
  for (final section in microSections)
    for (final field in section.fields) field.key: field,
};

/// Index of [microSections] by field key — the section a per-100 entity key
/// belongs to, for surfaces that group rows (diary panel, trends averages)
/// rather than render the specs themselves.
final Map<String, MicroSectionSpec> microSectionByKey = {
  for (final section in microSections)
    for (final field in section.fields) field.key: section,
};

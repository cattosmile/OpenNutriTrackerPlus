import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_nutriments_entity.dart';

part 'meal_nutriments_dbo.g.dart';

@HiveType(typeId: 3)
@JsonSerializable()
class MealNutrimentsDBO extends HiveObject {
  @HiveField(0)
  final double? energyKcal100;
  @HiveField(1)
  final double? carbohydrates100;
  @HiveField(2)
  final double? fat100;
  @HiveField(3)
  final double? proteins100;
  @HiveField(4)
  final double? sugars100;
  @HiveField(5)
  final double? saturatedFat100;
  @HiveField(6)
  final double? fiber100;
  // #237: Extended lipid profile
  @HiveField(7)
  final double? monounsaturatedFat100;
  @HiveField(8)
  final double? polyunsaturatedFat100;
  @HiveField(9)
  final double? transFat100;
  @HiveField(10)
  final double? cholesterol100;
  // #237: Minerals (mg per 100g)
  @HiveField(11)
  final double? sodium100;
  @HiveField(12)
  final double? potassium100;
  @HiveField(13)
  final double? magnesium100;
  @HiveField(14)
  final double? calcium100;
  @HiveField(15)
  final double? iron100;
  @HiveField(16)
  final double? zinc100;
  @HiveField(17)
  final double? phosphorus100;
  // #237: Vitamins
  @HiveField(18)
  final double? vitaminA100; // µg RAE
  @HiveField(19)
  final double? vitaminC100; // mg
  @HiveField(20)
  final double? vitaminD100; // µg
  @HiveField(21)
  final double? vitaminB6100; // mg
  @HiveField(22)
  final double? vitaminB12100; // µg
  @HiveField(23)
  final double? niacin100; // mg (B3)
  // Extended vitamin set
  @HiveField(24)
  final double? vitaminE100; // mg
  @HiveField(25)
  final double? vitaminK100; // µg
  @HiveField(26)
  final double? vitaminB1100; // mg (thiamine)
  @HiveField(27)
  final double? vitaminB2100; // mg (riboflavin)
  @HiveField(28)
  final double? vitaminB5100; // mg (pantothenic acid)
  @HiveField(29)
  final double? vitaminB7100; // µg (biotin)
  @HiveField(30)
  final double? vitaminB9100; // µg (folate)
  @HiveField(31)
  final double? choline100; // mg
  // Trace elements and electrolyte
  @HiveField(32)
  final double? chloride100; // mg
  @HiveField(33)
  final double? copper100; // µg
  @HiveField(34)
  final double? manganese100; // mg
  @HiveField(35)
  final double? selenium100; // µg
  @HiveField(36)
  final double? iodine100; // µg
  @HiveField(37)
  final double? fluoride100; // mg
  @HiveField(38)
  final double? chromium100; // µg
  @HiveField(39)
  final double? molybdenum100; // µg
  // Omega-3 fatty acids
  @HiveField(40)
  final double? ala100; // g
  @HiveField(41)
  final double? epa100; // g
  @HiveField(42)
  final double? dha100; // g
  @HiveField(43)
  final double? caffeine100; // mg

  MealNutrimentsDBO({
    required this.energyKcal100,
    required this.carbohydrates100,
    required this.fat100,
    required this.proteins100,
    required this.sugars100,
    required this.saturatedFat100,
    required this.fiber100,
    this.monounsaturatedFat100,
    this.polyunsaturatedFat100,
    this.transFat100,
    this.cholesterol100,
    this.sodium100,
    this.potassium100,
    this.magnesium100,
    this.calcium100,
    this.iron100,
    this.zinc100,
    this.phosphorus100,
    this.vitaminA100,
    this.vitaminC100,
    this.vitaminD100,
    this.vitaminB6100,
    this.vitaminB12100,
    this.niacin100,
    this.vitaminE100,
    this.vitaminK100,
    this.vitaminB1100,
    this.vitaminB2100,
    this.vitaminB5100,
    this.vitaminB7100,
    this.vitaminB9100,
    this.choline100,
    this.chloride100,
    this.copper100,
    this.manganese100,
    this.selenium100,
    this.iodine100,
    this.fluoride100,
    this.chromium100,
    this.molybdenum100,
    this.ala100,
    this.epa100,
    this.dha100,
    this.caffeine100,
  });

  factory MealNutrimentsDBO.fromProductNutrimentsEntity(
    MealNutrimentsEntity nutriments,
  ) {
    return MealNutrimentsDBO(
      energyKcal100: nutriments.energyKcal100,
      carbohydrates100: nutriments.carbohydrates100,
      fat100: nutriments.fat100,
      proteins100: nutriments.proteins100,
      sugars100: nutriments.sugars100,
      saturatedFat100: nutriments.saturatedFat100,
      fiber100: nutriments.fiber100,
      monounsaturatedFat100: nutriments.monounsaturatedFat100,
      polyunsaturatedFat100: nutriments.polyunsaturatedFat100,
      transFat100: nutriments.transFat100,
      cholesterol100: nutriments.cholesterol100,
      sodium100: nutriments.sodium100,
      potassium100: nutriments.potassium100,
      magnesium100: nutriments.magnesium100,
      calcium100: nutriments.calcium100,
      iron100: nutriments.iron100,
      zinc100: nutriments.zinc100,
      phosphorus100: nutriments.phosphorus100,
      vitaminA100: nutriments.vitaminA100,
      vitaminC100: nutriments.vitaminC100,
      vitaminD100: nutriments.vitaminD100,
      vitaminB6100: nutriments.vitaminB6100,
      vitaminB12100: nutriments.vitaminB12100,
      niacin100: nutriments.niacin100,
      vitaminE100: nutriments.vitaminE100,
      vitaminK100: nutriments.vitaminK100,
      vitaminB1100: nutriments.vitaminB1100,
      vitaminB2100: nutriments.vitaminB2100,
      vitaminB5100: nutriments.vitaminB5100,
      vitaminB7100: nutriments.vitaminB7100,
      vitaminB9100: nutriments.vitaminB9100,
      choline100: nutriments.choline100,
      chloride100: nutriments.chloride100,
      copper100: nutriments.copper100,
      manganese100: nutriments.manganese100,
      selenium100: nutriments.selenium100,
      iodine100: nutriments.iodine100,
      fluoride100: nutriments.fluoride100,
      chromium100: nutriments.chromium100,
      molybdenum100: nutriments.molybdenum100,
      ala100: nutriments.ala100,
      epa100: nutriments.epa100,
      dha100: nutriments.dha100,
      caffeine100: nutriments.caffeine100,
    );
  }

  factory MealNutrimentsDBO.fromJson(Map<String, dynamic> json) =>
      _$MealNutrimentsDBOFromJson(json);

  Map<String, dynamic> toJson() => _$MealNutrimentsDBOToJson(this);
}

import 'package:flutter_test/flutter_test.dart';
import 'package:opennutritracker/core/data/data_source/custom_meal_data_source.dart';
import 'package:opennutritracker/core/data/repository/config_repository.dart';
import 'package:opennutritracker/core/domain/usecase/get_config_usecase.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_entity.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_nutriments_entity.dart';
import 'package:opennutritracker/features/edit_meal/presentation/bloc/edit_meal_bloc.dart';

/// The custom-meal form hands its micronutrient fields to
/// `createNewMealEntity` as one `microTexts` map keyed by the entity field
/// name. These tests pin the two contracts that map carries: a typed value
/// wins over the old entity's value, and both scale by the base-quantity
/// factor exactly like the macros; a key the form never sends keeps the old
/// value (scaled) rather than being wiped to null.
void main() {
  final bloc = EditMealBloc(
    _FakeGetConfigUsecase(),
    _FakeCustomMealDataSource(),
    _FakeConfigRepository(),
  );

  MealEntity oldMeal({MealNutrimentsEntity? nutriments}) => MealEntity(
    code: 'old',
    name: 'old',
    url: null,
    mealQuantity: null,
    mealUnit: 'g',
    servingQuantity: null,
    servingUnit: null,
    servingSize: null,
    nutriments: nutriments ?? MealNutrimentsEntity.empty(),
    source: MealSourceEntity.custom,
  );

  test('typed micro text wins and scales by the base factor', () {
    final meal = bloc.createNewMealEntity(
      oldMeal(),
      'Salmon',
      '',
      '200',
      '100',
      '200', // base 200 → factor 100/200 = 0.5
      'g',
      '200',
      '0',
      '13',
      '20',
      microTexts: {'dha100': '2.0'},
    );

    expect(meal.nutriments.dha100, 1.0);
  });

  test('a key the form did not send keeps the old value, scaled', () {
    final meal = bloc.createNewMealEntity(
      oldMeal(
        nutriments: const MealNutrimentsEntity(
          energyKcal100: 0,
          carbohydrates100: 0,
          fat100: 0,
          proteins100: 0,
          sugars100: 0,
          saturatedFat100: 0,
          fiber100: 0,
          selenium100: 40,
        ),
      ),
      'Fish',
      '',
      '100',
      '100',
      '50', // base 50 → factor 2
      'g',
      '100',
      '0',
      '5',
      '15',
    );

    expect(meal.nutriments.selenium100, 80);
  });

  test('empty text falls back to the old value, not zero', () {
    final meal = bloc.createNewMealEntity(
      oldMeal(
        nutriments: const MealNutrimentsEntity(
          energyKcal100: 0,
          carbohydrates100: 0,
          fat100: 0,
          proteins100: 0,
          sugars100: 0,
          saturatedFat100: 0,
          fiber100: 0,
          caffeine100: 35,
        ),
      ),
      'Coffee',
      '',
      '100',
      '100',
      '100',
      'g',
      '2',
      '0',
      '0',
      '0',
      microTexts: {'caffeine100': ''},
    );

    expect(meal.nutriments.caffeine100, 35);
  });
}

class _FakeGetConfigUsecase implements GetConfigUsecase {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeCustomMealDataSource implements CustomMealDataSource {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeConfigRepository implements ConfigRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

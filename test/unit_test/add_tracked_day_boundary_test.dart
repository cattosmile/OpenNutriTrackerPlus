import 'package:flutter_test/flutter_test.dart';
import 'package:opennutritracker/core/domain/entity/app_theme_entity.dart';
import 'package:hive_ce/hive.dart';
import 'package:opennutritracker/core/data/data_source/tracked_day_data_source.dart';
import 'package:opennutritracker/core/data/dbo/tracked_day_dbo.dart';
import 'package:opennutritracker/core/data/repository/config_repository.dart';
import 'package:opennutritracker/core/data/repository/tracked_day_repository.dart';
import 'package:opennutritracker/core/domain/entity/config_entity.dart';
import 'package:opennutritracker/core/domain/usecase/add_tracked_day_usecase.dart';
import 'package:opennutritracker/core/domain/usecase/get_config_usecase.dart';

import '../helpers/hive_test_setup.dart';
import '../helpers/fake_hive_db_provider.dart';

/// ConfigRepository stub answering getConfig() from a fixed entity, so
/// the boundary offset is controllable without opening a config box.
class _FixedConfigRepository implements ConfigRepository {
  _FixedConfigRepository(this.entity);

  final ConfigEntity entity;

  @override
  Future<ConfigEntity> getConfig() async => entity;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AddTrackedDayUsecase boundary keying', () {
    late Box<TrackedDayDBO> box;
    late TrackedDayDataSource dataSource;

    setUpAll(() {
      Hive.init('.');
      registerHiveAdaptersOnce();
    });

    setUp(() async {
      final stamp = DateTime.now().microsecondsSinceEpoch;
      box = await Hive.openBox<TrackedDayDBO>('boundary_usecase_$stamp');
      dataSource = TrackedDayDataSource(FakeHiveDBProvider(trackedDayBox: box));
    });

    tearDown(() async {
      await box.deleteFromDisk();
    });

    AddTrackedDayUsecase usecaseWithOffset({int hours = 5, int minutes = 0}) {
      return AddTrackedDayUsecase(
        TrackedDayRepository(dataSource),
        GetConfigUsecase(
          _FixedConfigRepository(
            ConfigEntity(
              false,
              false,
              false,
              AppThemeEntity.dark,
              dayStartOffsetHours: hours,
              dayStartOffsetMinutes: minutes,
            ),
          ),
        ),
      );
    }

    test('a meal logged at 00:30 lands on the previous day row', () async {
      final usecase = usecaseWithOffset();

      await usecase.addNewTrackedDay(
        DateTime(2026, 10, 19, 0, 30),
        2000,
        200,
        60,
        120,
      );
      await usecase.addDayCaloriesTracked(DateTime(2026, 10, 19, 0, 30), 250);

      expect(await dataSource.getTrackedDay(DateTime(2026, 10, 19)), isNull);
      final row = await dataSource.getTrackedDay(DateTime(2026, 10, 18));
      expect(row, isNotNull);
      expect(row!.caloriesTracked, 250);
      expect(row.calorieGoal, 2000);
    });

    test('a daytime moment lands on its own day', () async {
      final usecase = usecaseWithOffset();

      await usecase.addNewTrackedDay(
        DateTime(2026, 10, 19, 14, 23),
        2000,
        200,
        60,
        120,
      );

      expect(await dataSource.getTrackedDay(DateTime(2026, 10, 19)), isNotNull);
    });

    test('a bare-midnight label (picked diary day) stays on its day', () async {
      final usecase = usecaseWithOffset();

      await usecase.addNewTrackedDay(
        DateTime(2026, 10, 19),
        2000,
        200,
        60,
        120,
      );

      expect(await dataSource.getTrackedDay(DateTime(2026, 10, 19)), isNotNull);
    });

    test('hasTrackedDay resolves through the boundary too', () async {
      final usecase = usecaseWithOffset();

      await usecase.addNewTrackedDay(
        DateTime(2026, 10, 19, 0, 30),
        2000,
        200,
        60,
        120,
      );

      expect(await usecase.hasTrackedDay(DateTime(2026, 10, 18, 9, 0)), isTrue);
      expect(
        await usecase.hasTrackedDay(DateTime(2026, 10, 19, 9, 0)),
        isFalse,
      );
    });

    test('a minute-level boundary (05:30) is honoured', () async {
      final usecase = usecaseWithOffset(hours: 5, minutes: 30);

      await usecase.addNewTrackedDay(
        DateTime(2026, 10, 19, 5, 15),
        2000,
        200,
        60,
        120,
      );

      expect(await dataSource.getTrackedDay(DateTime(2026, 10, 18)), isNotNull);
    });

    test('without a config use case the offset reads as 0', () async {
      final usecase = AddTrackedDayUsecase(TrackedDayRepository(dataSource));

      await usecase.addNewTrackedDay(
        DateTime(2026, 10, 19, 0, 30),
        2000,
        200,
        60,
        120,
      );

      expect(await dataSource.getTrackedDay(DateTime(2026, 10, 19)), isNotNull);
    });
  });
}

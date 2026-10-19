import 'package:auto_size_text/auto_size_text.dart';
import 'package:flutter/material.dart';
import 'package:opennutritracker/core/domain/entity/calories_profile_entity.dart';
import 'package:opennutritracker/core/domain/entity/config_entity.dart';
import 'package:opennutritracker/core/domain/entity/intake_entity.dart';
import 'package:opennutritracker/core/domain/entity/tracked_day_entity.dart';
import 'package:opennutritracker/core/domain/entity/user_entity.dart';
import 'package:opennutritracker/core/domain/entity/user_gender_entity.dart';
import 'package:opennutritracker/core/domain/usecase/get_config_usecase.dart';
import 'package:opennutritracker/core/domain/usecase/get_intake_usecase.dart';
import 'package:opennutritracker/core/domain/usecase/get_user_usecase.dart';
import 'package:opennutritracker/core/presentation/widgets/app_card.dart';
import 'package:opennutritracker/core/styles/app_palette.dart';
import 'package:opennutritracker/core/styles/dimens.dart';
import 'package:opennutritracker/core/utils/calc/day_boundary_calc.dart';
import 'package:opennutritracker/core/utils/calc/dri_reference.dart';
import 'package:opennutritracker/core/utils/locator.dart';
import 'package:opennutritracker/features/add_meal/domain/entity/meal_nutriments_entity.dart';
import 'package:opennutritracker/features/edit_meal/presentation/micro_field_specs.dart';
import 'package:opennutritracker/generated/l10n.dart';
import 'package:url_launcher/url_launcher.dart';

/// Daily micronutrient summary that aggregates the nutrients reporters keep
/// asking for — fibre, sodium, saturated fat, sugar, calcium, iron, potassium,
/// vitamin D, vitamin B12, and magnesium — across the day's intake list and
/// renders each as a "value / reference" row with a small progress bar.
///
/// The references are sensible DRIs for an average adult (FDA Daily Values
/// where applicable). Iron and magnesium are gender-aware because the gap
/// between female and male DRIs is large enough that a single number would
/// mislead one group or the other.
///
/// As a follow-up to #160 the panel now supports two extra dimensions:
///   * a Day / Week SegmentedButton toggle. "Week" computes a 7-day rolling
///     average (today + the previous 6 days) so the user can see whether a
///     single low-iron day was actually an outlier; references stay the
///     same. The previous days' intakes are fetched via [GetIntakeUsecase]
///     in [didChangeDependencies] and again whenever [selectedDay] changes.
///   * a per-nutrient show/hide map persisted on [ConfigEntity]. Defaults to
///     "everything visible"; the user can hide individual nutrients from
///     Settings → Nutrients (see [NutrientPanelKeys]).
///
/// Computation is on the fly from [intakes] (plus the fetched week window
/// when Week is selected). PR #314 added the per-meal micronutrient fields
/// on [MealNutrimentsDBO]; this widget simply sums them.
class DailyNutrientPanel extends StatefulWidget {
  final List<IntakeEntity> intakes;

  /// The day the panel is summarising. Used as the anchor for the weekly
  /// rolling average (today + the previous 6 days). Defaults to "today".
  final DateTime? selectedDay;

  /// Forwarded from the diary day view so the panel can prefer the user's
  /// per-nutrient goals (set in Settings → Nutrient goals, #173) over
  /// the published daily references. Null on days the user hasn't tracked
  /// yet — in which case the panel falls back to the default DRIs.
  final TrackedDayEntity? trackedDay;

  /// Averages-only mode, used by the Trends tab: when set, the panel shows
  /// one view — the per-day average over this many days ending today —
  /// with no Day/Week toggle. [intakes] is ignored in this mode (the panel
  /// fetches its own window).
  final int? averageWindowDays;

  /// Overrides the collapse header's title (defaults to
  /// "Today's nutrients"). Trends passes "Average nutrients".
  final MicroLabel? title;

  /// Inset around the card. The diary day view relies on this for its
  /// horizontal spacing (the default); Trends embeds the panel in a list
  /// that already pads its children, so it passes [EdgeInsets.zero] —
  /// otherwise the card renders narrower than its siblings.
  final EdgeInsetsGeometry outerPadding;

  const DailyNutrientPanel({
    super.key,
    required this.intakes,
    this.selectedDay,
    this.trackedDay,
    this.averageWindowDays,
    this.title,
    this.outerPadding = const EdgeInsets.fromLTRB(
      Dimens.spacing16,
      Dimens.spacing8,
      Dimens.spacing16,
      Dimens.spacing4,
    ),
  });

  // ---- Default daily references (#173) ----------------------------------
  // Published DRIs / FDA Daily Values used when the user hasn't set their
  // own target in Settings → Nutrient goals. Iron and magnesium default
  // to a gender-aware value; the rest are gender-neutral.
  static const double defaultFibreRefG = 30.0;
  static const double defaultSaturatedFatRefG = 20.0;
  static const double defaultSugarRefG = 50.0;
  static const double defaultSodiumRefMg = 2300.0;
  static const double defaultCalciumRefMg = 1000.0;
  static const double defaultPotassiumRefMg = 3500.0;
  static const double defaultVitaminDRefUg = 15.0;
  static const double defaultVitaminB12RefUg = 2.4;
  static const double defaultMagnesiumRefMg = 355.0; // non-binary midpoint

  /// Pure helpers that prefer the user's [TrackedDayEntity] per-nutrient
  /// goal when set, falling back to the published default otherwise.
  /// Public because the unit test suite asserts each one in isolation.
  static double resolveFibreReference(TrackedDayEntity? trackedDay) =>
      trackedDay?.fibreGoal ?? defaultFibreRefG;

  static double resolveSatFatReference(TrackedDayEntity? trackedDay) =>
      trackedDay?.satFatGoal ?? defaultSaturatedFatRefG;

  static double resolveSugarsReference(TrackedDayEntity? trackedDay) =>
      trackedDay?.sugarsGoal ?? defaultSugarRefG;

  static double resolveSodiumReference(TrackedDayEntity? trackedDay) =>
      trackedDay?.sodiumGoal ?? defaultSodiumRefMg;

  static double resolveCalciumReference(TrackedDayEntity? trackedDay) =>
      trackedDay?.calciumGoal ?? defaultCalciumRefMg;

  /// Iron uses a gender-aware default that the caller supplies, since the
  /// female / male DRIs (18 vs 8 mg) are far enough apart that an averaged
  /// number would mislead one group.
  static double resolveIronReference(
    TrackedDayEntity? trackedDay,
    double genderDefault,
  ) => trackedDay?.ironGoal ?? genderDefault;

  static double resolvePotassiumReference(TrackedDayEntity? trackedDay) =>
      trackedDay?.potassiumGoal ?? defaultPotassiumRefMg;

  static double resolveVitaminDReference(TrackedDayEntity? trackedDay) =>
      trackedDay?.vitaminDGoal ?? defaultVitaminDRefUg;

  static double resolveVitaminB12Reference(TrackedDayEntity? trackedDay) =>
      trackedDay?.vitaminB12Goal ?? defaultVitaminB12RefUg;

  static double resolveMagnesiumReference(TrackedDayEntity? trackedDay) =>
      trackedDay?.magnesiumGoal ?? defaultMagnesiumRefMg;

  @override
  State<DailyNutrientPanel> createState() => _DailyNutrientPanelState();
}

class _DailyNutrientPanelState extends State<DailyNutrientPanel> {
  _NutrientView _view = _NutrientView.day;
  // Collapsed by default — see the build method's note on visual weight.
  // Persists for the lifetime of the screen; revisiting the day view
  // resets it, which feels right given how secondary the detail is.
  bool _expanded = false;

  Future<_PanelData>? _panelDataFuture;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _panelDataFuture ??= _loadPanelData();
  }

  @override
  void didUpdateWidget(covariant DailyNutrientPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The parent passes a fresh intake list whenever the day changes or an
    // intake is added/removed. Refetch so the weekly average stays accurate
    // and the visibility map picks up any Settings edits. A changed
    // averageWindowDays (the Trends range chips) must refetch too: the
    // fetched window and the divisor would otherwise disagree and the
    // averages would shrink or grow by the ratio of the two windows.
    if (oldWidget.intakes != widget.intakes ||
        oldWidget.selectedDay != widget.selectedDay ||
        oldWidget.averageWindowDays != widget.averageWindowDays) {
      _panelDataFuture = _loadPanelData();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_PanelData>(
      future: _panelDataFuture,
      builder: (context, snapshot) {
        final data = snapshot.data;
        // Render the daily view (no weekly history yet) while the future
        // resolves — keeps the panel from blank-flashing on every rebuild.
        return _buildPanel(context, data);
      },
    );
  }

  Future<_PanelData> _loadPanelData() async {
    UserEntity? user;
    try {
      user = await locator<GetUserUsecase>().getUserData();
    } catch (_) {
      // Pre-onboarding / tests: fall back to gender-neutral defaults.
      user = null;
    }

    Map<String, bool> visibility = const <String, bool>{};
    var dayStartOffsetTotalMinutes = 0;
    try {
      final config = await locator<GetConfigUsecase>().getConfig();
      visibility = config.nutrientPanelVisibility;
      dayStartOffsetTotalMinutes = config.dayStartOffsetTotalMinutes;
    } catch (_) {
      // Tests without the locator wired up — default to "all visible".
    }

    List<IntakeEntity> weekIntakes = widget.intakes;
    try {
      // Without a picked day (Trends averages) anchor the window on the
      // logical today, so entries logged before the boundary count
      // towards the day the diary says they belong to.
      final anchor =
          widget.selectedDay ??
          DayBoundaryCalc.currentLogicalDayMinutes(dayStartOffsetTotalMinutes);
      weekIntakes = await _fetchWindowIntakes(
        anchor,
        widget.averageWindowDays ?? 7,
        dayStartOffsetTotalMinutes: dayStartOffsetTotalMinutes,
      );
    } catch (_) {
      // If the intake use case isn't registered (tests), the daily view
      // still works fine — fall back to whatever the parent gave us.
      weekIntakes = widget.intakes;
    }

    return _PanelData(
      user: user,
      visibility: visibility,
      weekIntakes: weekIntakes,
    );
  }

  Future<List<IntakeEntity>> _fetchWindowIntakes(
    DateTime anchor,
    int days, {
    int dayStartOffsetTotalMinutes = 0,
  }) async {
    final getIntakeUsecase = locator<GetIntakeUsecase>();
    final all = <IntakeEntity>[];
    for (int dayOffset = 0; dayOffset < days; dayOffset++) {
      final day = DateTime(
        anchor.year,
        anchor.month,
        anchor.day,
      ).subtract(Duration(days: dayOffset));
      // The per-day getters apply the configured boundary, so an entry
      // logged before the day start lands in the previous logical day —
      // the same bucketing the diary itself uses.
      final offsetHours = dayStartOffsetTotalMinutes ~/ 60;
      final offsetMinutes = dayStartOffsetTotalMinutes % 60;
      all
        ..addAll(
          await getIntakeUsecase.getBreakfastIntakeByDay(
            day,
            dayStartOffsetHours: offsetHours,
            dayStartOffsetMinutes: offsetMinutes,
          ),
        )
        ..addAll(
          await getIntakeUsecase.getLunchIntakeByDay(
            day,
            dayStartOffsetHours: offsetHours,
            dayStartOffsetMinutes: offsetMinutes,
          ),
        )
        ..addAll(
          await getIntakeUsecase.getDinnerIntakeByDay(
            day,
            dayStartOffsetHours: offsetHours,
            dayStartOffsetMinutes: offsetMinutes,
          ),
        )
        ..addAll(
          await getIntakeUsecase.getSnackIntakeByDay(
            day,
            dayStartOffsetHours: offsetHours,
            dayStartOffsetMinutes: offsetMinutes,
          ),
        );
    }
    return all;
  }

  Widget _buildPanel(BuildContext context, _PanelData? data) {
    final user = data?.user;
    final visibility = data?.visibility ?? const <String, bool>{};
    // Pick the right source for totals. Daily view sums today's intakes;
    // weekly view sums the seven-day window; averages mode (Trends) sums
    // its own window and divides by that window's day count. In averages
    // mode there is no toggle — the window the parent chose is the view.
    final isAverageMode = widget.averageWindowDays != null;
    final isWeekly = isAverageMode || _view == _NutrientView.week;
    final averageDays = isWeekly ? (widget.averageWindowDays ?? 7) : 1;
    final source = isWeekly
        ? (data?.weekIntakes ?? widget.intakes)
        : widget.intakes;
    final totals = NutrientPanelTotals.fromIntakes(
      source,
      averageDays: averageDays,
    );
    final fiberG = totals.fiberG;
    final sodiumMg = totals.sodiumMg;
    final saturatedFatG = totals.saturatedFatG;
    final sugarG = totals.sugarG;
    final calciumMg = totals.calciumMg;
    final ironMg = totals.ironMg;
    final potassiumMg = totals.potassiumMg;
    final vitaminDMcg = totals.vitaminDMcg;
    final vitaminB12Mcg = totals.vitaminB12Mcg;
    final magnesiumMg = totals.magnesiumMg;

    // Reference values are sensible adult DRIs / FDA Daily Values. Iron's
    // reference uses UserEntity.gender so women see 18mg and men see 8mg;
    // magnesium follows the same gender-aware pattern (400/310). Non-binary
    // users get a midpoint, in line with the app's existing averaged-
    // reference convention for non-binary calculations.
    // Per-nutrient targets — route through the public resolver helpers so
    // the unit tests and the build method share a single source of truth.
    final td = widget.trackedDay;
    // Helper: prefer the per-day tracked override, then the IOM age-banded
    // DRI when a user record is available, then the gender-agnostic default
    // the panel has always used as a last resort. This keeps the existing
    // resolver helpers as the single source of truth for tests, but layers
    // the age-aware IOM lookup (#245) on top for users we know enough about.
    double resolveWithDri(
      double? Function() trackedOverride,
      String nutrientKey,
      double fallback,
    ) {
      final tracked = trackedOverride();
      if (tracked != null) return tracked;
      if (user != null) {
        final dri = getReferenceFor(nutrient: nutrientKey, user: user);
        if (dri != null) return dri.amount;
      }
      return fallback;
    }

    final fiberRefG = resolveWithDri(
      () => td?.fibreGoal,
      NutrientPanelKeys.fiber,
      DailyNutrientPanel.defaultFibreRefG,
    );
    final sodiumRefMg = resolveWithDri(
      () => td?.sodiumGoal,
      NutrientPanelKeys.sodium,
      DailyNutrientPanel.defaultSodiumRefMg,
    );
    // Saturated fat and sugars have no IOM RDA — the resolver helper still
    // returns the published FDA Daily Value as the fallback for both.
    final saturatedFatRefG = DailyNutrientPanel.resolveSatFatReference(td);
    final sugarRefG = DailyNutrientPanel.resolveSugarsReference(td);
    final calciumRefMg = resolveWithDri(
      () => td?.calciumGoal,
      NutrientPanelKeys.calcium,
      DailyNutrientPanel.defaultCalciumRefMg,
    );
    final ironRefMg = resolveWithDri(
      () => td?.ironGoal,
      NutrientPanelKeys.iron,
      _ironRefForUser(user),
    );
    final potassiumRefMg = resolveWithDri(
      () => td?.potassiumGoal,
      NutrientPanelKeys.potassium,
      DailyNutrientPanel.defaultPotassiumRefMg,
    );
    final vitaminDRefMcg = resolveWithDri(
      () => td?.vitaminDGoal,
      NutrientPanelKeys.vitaminD,
      DailyNutrientPanel.defaultVitaminDRefUg,
    );
    final vitaminB12RefMcg = resolveWithDri(
      () => td?.vitaminB12Goal,
      NutrientPanelKeys.vitaminB12,
      DailyNutrientPanel.defaultVitaminB12RefUg,
    );
    final magnesiumRefMg = resolveWithDri(
      () => td?.magnesiumGoal,
      NutrientPanelKeys.magnesium,
      _magnesiumRefForUser(user),
    );

    final s = S.of(context);
    final allRows = <_PanelRow>[
      _PanelRow(
        key: NutrientPanelKeys.fiber,
        label: s.fiberLabel,
        value: fiberG,
        reference: fiberRefG,
        unit: 'g',
        excessMatters: false,
      ),
      _PanelRow(
        key: NutrientPanelKeys.sodium,
        label: s.sodiumLabel,
        value: sodiumMg,
        reference: sodiumRefMg,
        unit: 'mg',
        excessMatters: true,
      ),
      _PanelRow(
        key: NutrientPanelKeys.saturatedFat,
        label: s.saturatedFatLabel,
        value: saturatedFatG,
        reference: saturatedFatRefG,
        unit: 'g',
        excessMatters: true,
      ),
      _PanelRow(
        key: NutrientPanelKeys.sugar,
        label: s.sugarLabel,
        value: sugarG,
        reference: sugarRefG,
        unit: 'g',
        excessMatters: true,
      ),
      _PanelRow(
        key: NutrientPanelKeys.calcium,
        label: s.calciumLabel,
        value: calciumMg,
        reference: calciumRefMg,
        unit: 'mg',
        excessMatters: false,
      ),
      _PanelRow(
        key: NutrientPanelKeys.iron,
        label: s.ironLabel,
        value: ironMg,
        reference: ironRefMg,
        unit: 'mg',
        excessMatters: false,
      ),
      _PanelRow(
        key: NutrientPanelKeys.potassium,
        label: s.potassiumLabel,
        value: potassiumMg,
        reference: potassiumRefMg,
        unit: 'mg',
        excessMatters: false,
      ),
      _PanelRow(
        key: NutrientPanelKeys.vitaminD,
        label: s.vitaminDLabel,
        value: vitaminDMcg,
        reference: vitaminDRefMcg,
        unit: 'µg',
        excessMatters: false,
      ),
      _PanelRow(
        key: NutrientPanelKeys.vitaminB12,
        label: s.vitaminB12Label,
        value: vitaminB12Mcg,
        reference: vitaminB12RefMcg,
        unit: 'µg',
        excessMatters: false,
      ),
      _PanelRow(
        key: NutrientPanelKeys.magnesium,
        label: s.magnesiumLabel,
        value: magnesiumMg,
        reference: magnesiumRefMg,
        unit: 'mg',
        excessMatters: false,
      ),
      // The extended set: one row per nutrient, value summed through the
      // totals helper, reference via the same tracked-override → IOM →
      // fallback chain the rows above use (the tracked-day goals only
      // exist for the base set, so the override slot is simply null here).
      for (final spec in _extendedRowSpecs)
        _PanelRow(
          key: spec.key,
          label: spec.label(s),
          value: totals.extendedByKey(
            spec.key,
            source,
            averageDays: averageDays,
          ),
          reference: resolveWithDri(
            () => null,
            spec.key,
            spec.fallbackReference,
          ),
          unit: spec.unit,
          excessMatters: spec.excessMatters,
        ),
      // EPA + DHA as one combined row: EFSA's 250 mg/day adequate intake is
      // for the sum, so two separate rows would each imply their own
      // target. Summed in mg because the entity stores grams.
      _PanelRow(
        key: NutrientPanelKeys.epaDha,
        label: s.epaDhaLabel,
        value: NutrientPanelTotals.epaDhaMg(source, averageDays: averageDays),
        reference: resolveWithDri(() => null, NutrientPanelKeys.epaDha, 250),
        unit: 'mg',
        excessMatters: false,
      ),
    ];

    // Filter by the user's per-nutrient visibility setting (anything not
    // mentioned in the map defaults to visible), then group what remains
    // under the same section headers the edit-meal form uses (see
    // microSections) — the panel used to be a flat list in which base and
    // extended rows interleaved arbitrarily.
    final rowsByKey = {
      for (final row in allRows.where((row) => visibility[row.key] ?? true))
        row.key: row,
    };
    final panelKeyByEntity = {
      for (final entry in _panelEntityKeys.entries) entry.value: entry.key,
    };
    final sectioned = <(String, List<_PanelRow>)>[];
    for (final section in microSections) {
      final rows = <_PanelRow>[];
      for (final field in section.fields) {
        final row = rowsByKey[panelKeyByEntity[field.key]];
        if (row != null) rows.add(row);
        // Panel-only rows that share a section with form fields but have
        // no entity key of their own (EPA+DHA sums two fields) hook in
        // right after their neighbour instead of via the entity map.
        for (final extra in _panelOnlyRowsAfter[field.key] ?? const []) {
          final extraRow = rowsByKey[extra];
          if (extraRow != null) rows.add(extraRow);
        }
      }
      if (rows.isNotEmpty) sectioned.add((section.header(s), rows));
    }

    // Collapsed by default: the diary day view already carries a lot of
    // visual weight (kcal summary, macro circles, sortable meal sections),
    // so the nutrient detail sits inside an ExpansionTile and only reveals
    // itself when the user explicitly opens it. The header still shows
    // "Today's nutrients" so the affordance is discoverable.
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = isDark ? AppPalette.dark : AppPalette.light;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: widget.outerPadding,
      child: AppCard(
        padding: const EdgeInsets.symmetric(horizontal: Dimens.spacing8),
        child: Theme(
          // Strips the dividers ExpansionTile would otherwise draw above and
          // below itself — they fight with the calm card surface the panel
          // now sits inside.
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            shape: const RoundedRectangleBorder(
              borderRadius: Dimens.borderRadiusL,
            ),
            collapsedShape: const RoundedRectangleBorder(
              borderRadius: Dimens.borderRadiusL,
            ),
            tilePadding: const EdgeInsets.symmetric(
              horizontal: Dimens.spacing12,
            ),
            childrenPadding: const EdgeInsets.fromLTRB(
              Dimens.spacing12,
              0.0,
              Dimens.spacing12,
              Dimens.spacing16,
            ),
            title: Row(
              children: [
                Expanded(
                  child: AutoSizeText(
                    widget.title?.call(s) ?? s.diaryNutrientPanelTitle,
                    maxLines: 1,
                    minFontSize: 12,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                // Inline info icon. Tapping it pops the data-disclaimer
                // dialog without expanding the panel — IconButton's own
                // InkResponse consumes the pointer event, so the
                // surrounding ExpansionTile doesn't toggle.
                Semantics(
                  identifier: 'dri-panel-info',
                  child: IconButton(
                    tooltip: s.driPanelInfoTitle,
                    icon: Icon(
                      Icons.info_outline_rounded,
                      size: 22,
                      color: palette.textMuted,
                    ),
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.symmetric(
                      horizontal: Dimens.spacing8,
                    ),
                    onPressed: () => _showDataDisclaimer(context, s),
                  ),
                ),
              ],
            ),
            initiallyExpanded: _expanded,
            onExpansionChanged: (open) => setState(() => _expanded = open),
            children: [
              // Averages mode (Trends) has no Day/Week choice — the window
              // the parent picked is the view.
              if (!isAverageMode) ...[
                Align(
                  alignment: Alignment.centerRight,
                  child: SegmentedButton<_NutrientView>(
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    showSelectedIcon: false,
                    segments: <ButtonSegment<_NutrientView>>[
                      ButtonSegment(
                        value: _NutrientView.day,
                        label: Text(s.nutrientPanelDayLabel),
                      ),
                      ButtonSegment(
                        value: _NutrientView.week,
                        label: Text(s.nutrientPanelWeekLabel),
                      ),
                    ],
                    selected: <_NutrientView>{_view},
                    onSelectionChanged: (selection) {
                      setState(() => _view = selection.first);
                    },
                  ),
                ),
                const SizedBox(height: Dimens.spacing8),
              ],
              // The colour rules are invisible without something explaining
              // them — especially at 0 %, where every bar looks the same.
              // Two muted lines under the header keep the pairing (icon up
              // = reach, icon down = limit) and the colour states readable.
              if (sectioned.isNotEmpty) const _PanelLegend(),
              if (sectioned.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: Dimens.spacing4,
                  ),
                  child: Text(
                    s.nutrientPanelAllHiddenLabel,
                    style: textTheme.bodySmall?.copyWith(
                      color: palette.textMuted,
                    ),
                  ),
                )
              else
                for (final (header, rows) in sectioned) ...[
                  Padding(
                    padding: const EdgeInsets.only(
                      top: Dimens.spacing8,
                      bottom: Dimens.spacing4,
                    ),
                    child: MicroSectionHeading(header),
                  ),
                  for (final row in rows)
                    _NutrientRow(
                      label: row.label,
                      value: row.value,
                      reference: row.reference,
                      unit: row.unit,
                      excessMatters: row.excessMatters,
                    ),
                ],
            ],
          ),
        ),
      ),
    );
  }

  void _showDataDisclaimer(BuildContext context, S s) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          icon: const Icon(Icons.info_outline),
          title: Text(s.driPanelInfoTitle),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(s.driPanelInfoBody),
                const SizedBox(height: 12.0),
                Text(s.diaryNutrientPanelDataDisclaimer),
                const SizedBox(height: 16.0),
                Semantics(
                  identifier: 'dri-panel-info-link',
                  child: InkWell(
                    onTap: () async {
                      final uri = Uri.parse(driSourceUrl);
                      // Best-effort link launch — silently no-ops if the
                      // platform reports it cannot handle the URL, which is
                      // friendlier than throwing in front of the user.
                      if (await canLaunchUrl(uri)) {
                        await launchUrl(
                          uri,
                          mode: LaunchMode.externalApplication,
                        );
                      }
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4.0),
                      child: Text(
                        s.driPanelInfoLinkLabel,
                        style: Theme.of(dialogContext).textTheme.bodyMedium
                            ?.copyWith(
                              color: Theme.of(
                                dialogContext,
                              ).colorScheme.primary,
                              decoration: TextDecoration.underline,
                            ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(s.dialogOKLabel),
            ),
          ],
        );
      },
    );
  }

  // Gender-aware defaults for the two nutrients where female / male DRIs
  // disagree substantively. Non-binary users route through their chosen
  // [CaloriesProfileEntity] just like the calorie calculation does
  // (see [TDEECalc.getTDEEKcalIOM2005]): Estrogen-typical → female value,
  // Testosterone-typical → male value, Averaged (default) → midpoint.
  // This keeps a single source of truth for what "non-binary → which
  // reference" means across the app, rather than the nutrient panel
  // silently disagreeing with the calorie panel a few sections above.
  static double _ironRefForUser(UserEntity? user) {
    const female = 18.0;
    const male = 8.0;
    const averaged = 14.0;
    return _dispatchGenderReference(
      user,
      female: female,
      male: male,
      averaged: averaged,
    );
  }

  static double _magnesiumRefForUser(UserEntity? user) {
    const female = 310.0;
    const male = 400.0;
    const averaged = 355.0;
    return _dispatchGenderReference(
      user,
      female: female,
      male: male,
      averaged: averaged,
    );
  }

  static double _dispatchGenderReference(
    UserEntity? user, {
    required double female,
    required double male,
    required double averaged,
  }) {
    if (user == null) return averaged;
    switch (user.gender) {
      case UserGenderEntity.female:
        return female;
      case UserGenderEntity.male:
        return male;
      case UserGenderEntity.nonBinary:
        switch (user.caloriesProfile ?? CaloriesProfileEntity.averaged) {
          case CaloriesProfileEntity.averaged:
            return averaged;
          case CaloriesProfileEntity.estrogenTypical:
            return female;
          case CaloriesProfileEntity.testosteroneTypical:
            return male;
        }
    }
  }
}

enum _NutrientView { day, week }

/// One row of the extended panel: its key, label getter, display unit and
/// the gender-neutral fallback used when no IOM row applies (none today —
/// every extended nutrient has a table row — but the chain still needs a
/// final fallback the way the base rows have one).
class _ExtendedRowSpec {
  final String key;
  final String Function(S s) label;
  final String unit;
  final double fallbackReference;

  /// Whether the reference is a ceiling rather than a target — true only
  /// for caffeine (EFSA 400 mg). Colors and the "Limit" tag follow it.
  final bool excessMatters;

  const _ExtendedRowSpec(
    this.key,
    this.label,
    this.unit,
    this.fallbackReference, {
    this.excessMatters = false,
  });
}

// `final`, not `const`: the label entries are closures over the generated
// localization object, which cannot be a constant expression.
final List<_ExtendedRowSpec> _extendedRowSpecs = <_ExtendedRowSpec>[
  _ExtendedRowSpec(NutrientPanelKeys.zinc, (s) => s.zincLabel, 'mg', 11),
  _ExtendedRowSpec(
    NutrientPanelKeys.phosphorus,
    (s) => s.phosphorusLabel,
    'mg',
    700,
  ),
  _ExtendedRowSpec(
    NutrientPanelKeys.chloride,
    (s) => s.chlorideLabel,
    'mg',
    2300,
  ),
  _ExtendedRowSpec(
    NutrientPanelKeys.vitaminA,
    (s) => s.vitaminALabel,
    'µg',
    800,
  ),
  _ExtendedRowSpec(
    NutrientPanelKeys.vitaminC,
    (s) => s.vitaminCLabel,
    'mg',
    90,
  ),
  _ExtendedRowSpec(
    NutrientPanelKeys.vitaminE,
    (s) => s.vitaminELabel,
    'mg',
    15,
  ),
  _ExtendedRowSpec(
    NutrientPanelKeys.vitaminK,
    (s) => s.vitaminKLabel,
    'µg',
    105,
  ),
  _ExtendedRowSpec(
    NutrientPanelKeys.vitaminB1,
    (s) => s.vitaminB1Label,
    'mg',
    1.2,
  ),
  _ExtendedRowSpec(
    NutrientPanelKeys.vitaminB2,
    (s) => s.vitaminB2Label,
    'mg',
    1.3,
  ),
  _ExtendedRowSpec(NutrientPanelKeys.niacin, (s) => s.niacinLabel, 'mg', 16),
  _ExtendedRowSpec(
    NutrientPanelKeys.vitaminB5,
    (s) => s.vitaminB5Label,
    'mg',
    5,
  ),
  _ExtendedRowSpec(
    NutrientPanelKeys.vitaminB6,
    (s) => s.vitaminB6Label,
    'mg',
    1.3,
  ),
  _ExtendedRowSpec(
    NutrientPanelKeys.vitaminB7,
    (s) => s.vitaminB7Label,
    'µg',
    30,
  ),
  _ExtendedRowSpec(
    NutrientPanelKeys.vitaminB9,
    (s) => s.vitaminB9Label,
    'µg',
    400,
  ),
  _ExtendedRowSpec(NutrientPanelKeys.choline, (s) => s.cholineLabel, 'mg', 550),
  _ExtendedRowSpec(NutrientPanelKeys.copper, (s) => s.copperLabel, 'µg', 900),
  _ExtendedRowSpec(
    NutrientPanelKeys.manganese,
    (s) => s.manganeseLabel,
    'mg',
    2.3,
  ),
  _ExtendedRowSpec(
    NutrientPanelKeys.selenium,
    (s) => s.seleniumLabel,
    'µg',
    55,
  ),
  _ExtendedRowSpec(NutrientPanelKeys.iodine, (s) => s.iodineLabel, 'µg', 150),
  _ExtendedRowSpec(NutrientPanelKeys.fluoride, (s) => s.fluorideLabel, 'mg', 4),
  _ExtendedRowSpec(
    NutrientPanelKeys.chromium,
    (s) => s.chromiumLabel,
    'µg',
    35,
  ),
  _ExtendedRowSpec(
    NutrientPanelKeys.molybdenum,
    (s) => s.molybdenumLabel,
    'µg',
    45,
  ),
  _ExtendedRowSpec(NutrientPanelKeys.ala, (s) => s.alaLabel, 'g', 1.6),
  // EFSA safe daily caffeine intake for healthy adults, 2015 scientific
  // opinion — a ceiling, hence the only extended limit row.
  _ExtendedRowSpec(
    NutrientPanelKeys.caffeine,
    (s) => s.caffeineLabel,
    'mg',
    400,
    excessMatters: true,
  ),
];

/// Pure-function helper that aggregates a list of intakes into per-nutrient
/// totals. Pulled out of the widget so unit tests can exercise it directly
/// without spinning up a Flutter binding. `weekly: true` divides every total
/// by 7 to convert a seven-day window into an average daily intake.
class NutrientPanelTotals {
  final double fiberG;
  final double sodiumMg;
  final double saturatedFatG;
  final double sugarG;
  final double calciumMg;
  final double ironMg;
  final double potassiumMg;
  final double vitaminDMcg;
  final double vitaminB12Mcg;
  final double magnesiumMg;

  const NutrientPanelTotals({
    required this.fiberG,
    required this.sodiumMg,
    required this.saturatedFatG,
    required this.sugarG,
    required this.calciumMg,
    required this.ironMg,
    required this.potassiumMg,
    required this.vitaminDMcg,
    required this.vitaminB12Mcg,
    required this.magnesiumMg,
  });

  factory NutrientPanelTotals.fromIntakes(
    List<IntakeEntity> intakes, {
    int averageDays = 1,
  }) {
    final divisor = averageDays.toDouble();
    double sum(double? Function(MealNutrimentsEntity n) pick) {
      return intakes.fold<double>(0, (running, intake) {
            final per100 = pick(intake.meal.nutriments);
            if (per100 == null) return running;
            return running + intake.amount * per100 / 100.0;
          }) /
          divisor;
    }

    return NutrientPanelTotals(
      fiberG: sum((n) => n.fiber100),
      sodiumMg: sum((n) => n.sodium100),
      saturatedFatG: sum((n) => n.saturatedFat100),
      sugarG: sum((n) => n.sugars100),
      calciumMg: sum((n) => n.calcium100),
      ironMg: sum((n) => n.iron100),
      potassiumMg: sum((n) => n.potassium100),
      vitaminDMcg: sum((n) => n.vitaminD100),
      vitaminB12Mcg: sum((n) => n.vitaminB12100),
      magnesiumMg: sum((n) => n.magnesium100),
    );
  }

  /// Sum of one extended-panel nutrient across [intakes], addressed by its
  /// [NutrientPanelKeys] identifier. Reads through the entity's
  /// `micronutrientByKey`, so a key that names nothing reads as 0.
  /// `averageDays` divides the window total like the base totals do.
  double extendedByKey(
    String panelKey,
    List<IntakeEntity> intakes, {
    int averageDays = 1,
  }) {
    final entityKey = _panelEntityKeys[panelKey];
    if (entityKey == null) return 0;
    final total = intakes.fold<double>(0, (running, intake) {
      final per100 = intake.meal.nutriments.micronutrientByKey(entityKey);
      if (per100 == null) return running;
      return running + intake.amount * per100 / 100.0;
    });
    return total / averageDays.toDouble();
  }

  /// EPA + DHA combined, in milligrams — EFSA's 250 mg/day adequate intake
  /// is for the sum of the two, which is why the panel shows one row. The
  /// entity stores both as grams per 100 g. Static: it reads only its
  /// arguments, so tests call it without building a totals instance.
  static double epaDhaMg(List<IntakeEntity> intakes, {int averageDays = 1}) {
    final total = intakes.fold<double>(0, (running, intake) {
      final n = intake.meal.nutriments;
      final epa = n.epa100;
      final dha = n.dha100;
      if (epa == null && dha == null) return running;
      return running + intake.amount * ((epa ?? 0) + (dha ?? 0)) / 100.0;
    });
    // grams → milligrams
    return total * 1000.0 / averageDays.toDouble();
  }
}

/// Maps each panel key to the entity field `micronutrientByKey` reads it
/// through — the base rows as well as the extended set. One map so the
/// panel rows, the totals, the section grouping and the visibility list
/// cannot drift apart.
const Map<String, String> _panelEntityKeys = <String, String>{
  NutrientPanelKeys.fiber: 'fiber100',
  NutrientPanelKeys.sodium: 'sodium100',
  NutrientPanelKeys.saturatedFat: 'saturatedFat100',
  NutrientPanelKeys.sugar: 'sugars100',
  NutrientPanelKeys.calcium: 'calcium100',
  NutrientPanelKeys.iron: 'iron100',
  NutrientPanelKeys.potassium: 'potassium100',
  NutrientPanelKeys.vitaminD: 'vitaminD100',
  NutrientPanelKeys.vitaminB12: 'vitaminB12100',
  NutrientPanelKeys.magnesium: 'magnesium100',
  NutrientPanelKeys.zinc: 'zinc100',
  NutrientPanelKeys.phosphorus: 'phosphorus100',
  NutrientPanelKeys.chloride: 'chloride100',
  NutrientPanelKeys.vitaminA: 'vitaminA100',
  NutrientPanelKeys.vitaminC: 'vitaminC100',
  NutrientPanelKeys.vitaminE: 'vitaminE100',
  NutrientPanelKeys.vitaminK: 'vitaminK100',
  NutrientPanelKeys.vitaminB1: 'vitaminB1100',
  NutrientPanelKeys.vitaminB2: 'vitaminB2100',
  NutrientPanelKeys.niacin: 'niacin100',
  NutrientPanelKeys.vitaminB5: 'vitaminB5100',
  NutrientPanelKeys.vitaminB6: 'vitaminB6100',
  NutrientPanelKeys.vitaminB7: 'vitaminB7100',
  NutrientPanelKeys.vitaminB9: 'vitaminB9100',
  NutrientPanelKeys.choline: 'choline100',
  NutrientPanelKeys.copper: 'copper100',
  NutrientPanelKeys.manganese: 'manganese100',
  NutrientPanelKeys.selenium: 'selenium100',
  NutrientPanelKeys.iodine: 'iodine100',
  NutrientPanelKeys.fluoride: 'fluoride100',
  NutrientPanelKeys.chromium: 'chromium100',
  NutrientPanelKeys.molybdenum: 'molybdenum100',
  NutrientPanelKeys.ala: 'ala100',
  NutrientPanelKeys.caffeine: 'caffeine100',
};

/// Panel-only rows (no 1:1 entity field) and the entity key they render
/// after inside their section. EPA+DHA sums two entity fields, so it rides
/// along after ALA in the Omega-3 section.
const Map<String, List<String>> _panelOnlyRowsAfter = <String, List<String>>{
  'ala100': <String>[NutrientPanelKeys.epaDha],
};

/// Panel keys in the order the sections render them — public so the unit
/// tests can pin that every [NutrientPanelKeys] entry lands in exactly
/// one section (EPA and DHA form fields are detail-table-only and carry no
/// panel key of their own; the combined EPA+DHA row does, and drops in
/// after ALA via the map above).
List<String> nutrientPanelRowOrder() {
  final panelKeyByEntity = {
    for (final entry in _panelEntityKeys.entries) entry.value: entry.key,
  };
  return [
    for (final section in microSections)
      for (final field in section.fields) ...[
        ?panelKeyByEntity[field.key],
        ...?_panelOnlyRowsAfter[field.key],
      ],
  ];
}

/// Stable identifiers for the panel's nutrient rows. These are the keys the
/// per-nutrient visibility map uses on [ConfigEntity], so renaming any of
/// them is a backward-incompatible change: existing visibility overrides
/// would silently lose their associations.
class NutrientPanelKeys {
  NutrientPanelKeys._();

  static const String fiber = 'fiber';
  static const String sodium = 'sodium';
  static const String saturatedFat = 'saturated_fat';
  static const String sugar = 'sugar';
  static const String calcium = 'calcium';
  static const String iron = 'iron';
  static const String potassium = 'potassium';
  static const String vitaminD = 'vitamin_d';
  static const String vitaminB12 = 'vitamin_b12';
  static const String magnesium = 'magnesium';

  // Extended nutrient set. EPA / DHA and caffeine have no IOM reference —
  // they stay on the meal-detail table only — and neither do the lipid
  // sub-fractions, which the detail table also carries.
  static const String zinc = 'zinc';
  static const String phosphorus = 'phosphorus';
  static const String chloride = 'chloride';
  static const String vitaminA = 'vitamin_a';
  static const String vitaminC = 'vitamin_c';
  static const String vitaminE = 'vitamin_e';
  static const String vitaminK = 'vitamin_k';
  static const String vitaminB1 = 'vitamin_b1';
  static const String vitaminB2 = 'vitamin_b2';
  static const String niacin = 'niacin';
  static const String vitaminB5 = 'vitamin_b5';
  static const String vitaminB6 = 'vitamin_b6';
  static const String vitaminB7 = 'vitamin_b7';
  static const String vitaminB9 = 'vitamin_b9';
  static const String choline = 'choline';
  static const String copper = 'copper';
  static const String manganese = 'manganese';
  static const String selenium = 'selenium';
  static const String iodine = 'iodine';
  static const String fluoride = 'fluoride';
  static const String chromium = 'chromium';
  static const String molybdenum = 'molybdenum';
  static const String ala = 'ala';

  // EPA and DHA have no separate IOM reference, but EFSA sets an adequate
  // intake for the SUM of the two (250 mg/day, adults) — the panel carries
  // them as one combined row rather than two rows that would each imply
  // their own target. Caffeine follows EFSA's 400 mg/day safe intake, as a
  // limit row.
  static const String epaDha = 'epa_dha';
  static const String caffeine = 'caffeine';

  static const List<String> all = <String>[
    fiber,
    sodium,
    saturatedFat,
    sugar,
    calcium,
    iron,
    potassium,
    vitaminD,
    vitaminB12,
    magnesium,
    zinc,
    phosphorus,
    chloride,
    vitaminA,
    vitaminC,
    vitaminE,
    vitaminK,
    vitaminB1,
    vitaminB2,
    niacin,
    vitaminB5,
    vitaminB6,
    vitaminB7,
    vitaminB9,
    choline,
    copper,
    manganese,
    selenium,
    iodine,
    fluoride,
    chromium,
    molybdenum,
    ala,
    epaDha,
    caffeine,
  ];
}

/// The always-visible guide to what the bars and icons mean: up-arrow rows
/// are targets to reach, down-arrow rows are caps to stay under, and the
/// bar colour states what the current value says about that.
class _PanelLegend extends StatelessWidget {
  const _PanelLegend();

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = isDark ? AppPalette.dark : AppPalette.light;
    final textTheme = Theme.of(context).textTheme;
    final muted = textTheme.bodySmall?.copyWith(color: palette.textMuted);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Dimens.spacing12),
      decoration: BoxDecoration(
        color: palette.surfaceMuted,
        borderRadius: Dimens.borderRadiusM,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.nutrientPanelLegendTitle,
            style: textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: palette.textStrong,
            ),
          ),
          const SizedBox(height: Dimens.spacing8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.north_rounded, size: 16, color: palette.textMuted),
              const SizedBox(width: Dimens.spacing8),
              Expanded(child: Text(s.nutrientPanelLegendTarget, style: muted)),
            ],
          ),
          const SizedBox(height: Dimens.spacing4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.south_rounded, size: 16, color: palette.textMuted),
              const SizedBox(width: Dimens.spacing8),
              Expanded(child: Text(s.nutrientPanelLegendLimit, style: muted)),
            ],
          ),
        ],
      ),
    );
  }
}

class _PanelData {
  final UserEntity? user;
  final Map<String, bool> visibility;
  final List<IntakeEntity> weekIntakes;

  _PanelData({
    required this.user,
    required this.visibility,
    required this.weekIntakes,
  });
}

class _PanelRow {
  final String key;
  final String label;
  final double value;
  final double reference;
  final String unit;
  final bool excessMatters;

  _PanelRow({
    required this.key,
    required this.label,
    required this.value,
    required this.reference,
    required this.unit,
    required this.excessMatters,
  });
}

class _NutrientRow extends StatelessWidget {
  final String label;
  final double value;
  final double reference;
  final String unit;

  /// Whether going over the reference is a problem (sodium, saturated fat,
  /// sugar) versus simply not meeting a target (fibre, calcium, iron,
  /// potassium, vitamin D, vitamin B12, magnesium). Affects the colour the
  /// bar turns when the user goes over.
  final bool excessMatters;

  const _NutrientRow({
    required this.label,
    required this.value,
    required this.reference,
    required this.unit,
    required this.excessMatters,
  });

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = isDark ? AppPalette.dark : AppPalette.light;
    final textTheme = Theme.of(context).textTheme;
    final ratio = reference > 0 ? value / reference : 0.0;
    final clamped = ratio.clamp(0.0, 1.0).toDouble();
    final color = _colorForRatio(context, ratio);
    final valueLabel =
        '${value.toStringAsFixed(value >= 10 ? 0 : 1)}'
        ' / ${reference.toStringAsFixed(reference >= 10 ? 0 : 1)}$unit';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Dimens.spacing8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(
                  children: [
                    // Which direction this row wants to move, legible even
                    // when the bar is empty: up = a target to reach, down =
                    // a cap to stay under. The legend under the panel title
                    // explains the pair.
                    Icon(
                      excessMatters ? Icons.south_rounded : Icons.north_rounded,
                      size: 16,
                      color: palette.textMuted,
                    ),
                    const SizedBox(width: Dimens.spacing4),
                    Expanded(
                      child: Text(
                        label,
                        style: textTheme.bodyMedium?.copyWith(
                          color: palette.textStrong,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // For ceiling nutrients (sodium, saturated fat, sugar) the
                  // reference is a limit to stay under, not a target to reach.
                  // A small qualifier says so, since the bare "x / y" reads as
                  // a goal otherwise.
                  if (excessMatters) ...[
                    Text(
                      s.nutrientPanelLimitLabel,
                      style: textTheme.labelSmall?.copyWith(
                        color: palette.textMuted,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                    const SizedBox(width: Dimens.spacing4),
                  ],
                  Text(
                    valueLabel,
                    style: textTheme.bodySmall?.copyWith(
                      color: palette.textStrong,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: Dimens.spacing8),
          ClipRRect(
            borderRadius: BorderRadius.circular(8.0),
            child: LinearProgressIndicator(
              value: clamped,
              minHeight: 8.0,
              // A neutral track, not the palette's warm beige — on an
              // empty day the track is all that shows, and a tan bar read
              // as an orange warning when it means "nothing logged yet".
              backgroundColor: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: isDark ? 0.10 : 0.08),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ],
      ),
    );
  }

  Color _colorForRatio(BuildContext context, double ratio) {
    final scheme = Theme.of(context).colorScheme;
    if (excessMatters) {
      // Sodium / saturated fat / sugar: the reference is a cap. The warning
      // colours live on these rows ONLY — amber close to the cap, red over
      // it — so orange always means the same thing wherever it appears.
      if (ratio >= 1.0) return scheme.error;
      if (ratio >= 0.8) return Colors.amber.shade700;
      return scheme.primary;
    } else {
      // Target nutrients: the fill is always primary and the bar's LENGTH
      // carries the progress. "Not there yet" needs no colour of its own —
      // amber in that slot read as a warning, which it isn't. Reaching and
      // passing the target are both fine; a full bar means "reached".
      return scheme.primary;
    }
  }
}

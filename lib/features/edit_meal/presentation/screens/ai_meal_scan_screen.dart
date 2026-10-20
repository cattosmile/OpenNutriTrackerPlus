import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:logging/logging.dart';
import 'package:opennutritracker/core/styles/app_palette.dart';
import 'package:opennutritracker/core/utils/ai_credential_storage.dart';
import 'package:opennutritracker/core/utils/ai_model_catalogue.dart';
import 'package:opennutritracker/core/utils/locator.dart';
import 'package:opennutritracker/core/utils/navigation_options.dart';
import 'package:opennutritracker/features/add_meal/domain/structured_tool_api.dart';
import 'package:opennutritracker/features/add_meal/util/meal_photo_encoder.dart';
import 'package:opennutritracker/features/edit_meal/domain/ai_meal_scan.dart';
import 'package:opennutritracker/features/edit_meal/domain/usecase/ai_meal_scan_usecase.dart';
import 'package:opennutritracker/features/edit_meal/presentation/micro_field_specs.dart';
import 'package:opennutritracker/generated/l10n.dart';

/// What the scan screen pops with: the values the form prefill needs, plus
/// the front photo to reuse as the meal's image (null when none was picked).
typedef AiMealScanPayload = ({AiMealScanResult result, MealPhoto? frontPhoto});

/// Photographs a packaged food's label and lets the model + the free food
/// databases fill the custom-meal form.
///
/// Entered from the edit-meal screen's sparkle action; pops with an
/// [AiMealScanPayload] for the form to prefill, or null when the user backs
/// out. Photos live as encoded bytes in this screen's state until one is
/// popped out as the meal's image — the picker's cache copy is deleted on
/// encode, matching the disclosure the pick sheet shows.
class AiMealScanScreen extends StatefulWidget {
  const AiMealScanScreen({super.key});

  @override
  State<AiMealScanScreen> createState() => _AiMealScanScreenState();
}

class _AiMealScanScreenState extends State<AiMealScanScreen> {
  static final _log = Logger('AiMealScanScreen');

  MealPhoto? _frontPhoto;
  MealPhoto? _backPhoto;
  final _supermarketController = TextEditingController();
  final _brandController = TextEditingController();
  final _productNameController = TextEditingController();
  final _portionController = TextEditingController();

  AiMealScanPhase? _runningPhase;
  AiMealScanResult? _result;
  MealInterpreterFailure? _failure;
  bool _unavailable = false;

  @override
  void dispose() {
    _supermarketController.dispose();
    _brandController.dispose();
    _productNameController.dispose();
    _portionController.dispose();
    super.dispose();
  }

  /// Where the photos would go, and the name the pick sheet gives it —
  /// the same question bulk add asks before a photo leaves the device.
  ///
  /// Own-server is not probe-gated here, unlike the bulk-add camera: this
  /// screen's Analyse button is the gate, and a model that cannot see
  /// answers with the existing `unsupported` message rather than a hidden
  /// affordance.
  Future<({AiProvider provider, String name})?> _resolveDestination() async {
    final storage = locator<AiCredentialStorage>();
    final provider = await storage.activeProvider();
    if (provider == null) return null;
    if (provider == AiProvider.ownServer) {
      final endpoint = await storage.readEndpoint(provider: provider);
      final host = endpoint == null
          ? null
          : AiCredentialStorage.displayHost(endpoint);
      return host == null ? null : (provider: provider, name: host);
    }
    final model = AiModelCatalogue.resolve(
      provider,
      await storage.readModel(provider: provider),
    );
    if (model == null) return null;
    return (provider: provider, name: model.servedBy);
  }

  Future<void> _pickPhoto({required bool front}) async {
    FocusScope.of(context).unfocus();
    final destination = await _resolveDestination();
    if (!mounted) return;
    // With no identifiable destination there is no honest sentence to put
    // in the sheet — the same refusal bulk add makes.
    if (destination == null) return;
    final s = S.of(context);
    final disclosure = switch (destination.provider) {
      AiProvider.anthropic => s.aiScanDisclosureAnthropic,
      AiProvider.openrouter => s.aiScanDisclosureOpenRouter(destination.name),
      AiProvider.openai => s.aiScanDisclosureOpenAI,
      AiProvider.zai => s.aiScanDisclosureZai,
      AiProvider.google => s.aiScanDisclosureGoogle,
      AiProvider.ownServer => s.aiScanDisclosureOwnServer(destination.name),
    };
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            // The disclosure sits in the sheet, not a dialog to dismiss:
            // this is the moment a photo would leave the device.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                '$disclosure ${S.of(sheetContext).aiScanDisclosureCommon}\n\n'
                '${S.of(sheetContext).aiAssistExperimentalNote}',
                style: Theme.of(sheetContext).textTheme.bodySmall,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_rounded),
              title: Text(S.of(sheetContext).mealImageTakePhoto),
              onTap: () => Navigator.of(sheetContext).pop(ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_rounded),
              title: Text(S.of(sheetContext).mealImagePickFromGallery),
              onTap: () => Navigator.of(sheetContext).pop(ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;

    final XFile? picked;
    try {
      picked = await ImagePicker().pickImage(source: source);
    } catch (e, stackTrace) {
      _log.warning('Opening the label photo picker failed', e, stackTrace);
      return;
    }
    if (picked == null || !mounted) return;

    final photo = await MealPhotoEncoder.encodeAndDiscardSource(
      picked.path,
      format: MealPhotoFormat.forProvider(destination.provider),
    );
    if (!mounted) return;
    if (photo == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(S.of(context).aiScanUnreadablePhotoLabel)),
      );
      return;
    }
    setState(() {
      if (front) {
        _frontPhoto = photo;
      } else {
        _backPhoto = photo;
      }
      // New photos invalidate whatever ran before.
      _result = null;
      _failure = null;
      _unavailable = false;
    });
  }

  Future<void> _analyze() async {
    FocusScope.of(context).unfocus();
    final back = _backPhoto;
    if (back == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(S.of(context).aiScanNoBackPhotoLabel)),
      );
      return;
    }
    setState(() {
      _runningPhase = AiMealScanPhase.reading;
      _result = null;
      _failure = null;
      _unavailable = false;
    });
    final outcome = await locator<AiMealScanUseCase>().run(
      backPhoto: back,
      frontPhoto: _frontPhoto,
      supermarket: _supermarketController.text,
      brand: _brandController.text,
      productName: _productNameController.text,
      portionGrams: _portionController.text,
      localeCode: Localizations.localeOf(context).languageCode,
      onPhase: (phase) {
        if (mounted) setState(() => _runningPhase = phase);
      },
    );
    if (!mounted) return;
    setState(() {
      _runningPhase = null;
      switch (outcome) {
        case AiMealScanDone(:final result):
          _result = result;
        case AiMealScanUnavailable():
          _unavailable = true;
        case AiMealScanFailed(:final failure):
          _failure = failure;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = isDark ? AppPalette.dark : AppPalette.light;
    final s = S.of(context);
    return Scaffold(
      backgroundColor: palette.canvas,
      appBar: AppBar(
        backgroundColor: palette.canvas,
        surfaceTintColor: Colors.transparent,
        title: Text(
          s.aiScanTitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(s.aiScanIntro, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 16),
            _PhotoCard(
              identifier: 'ai-scan-front-photo',
              label: s.aiScanFrontPhotoLabel,
              photo: _frontPhoto,
              onPick: () => _pickPhoto(front: true),
              enabled: _runningPhase == null,
            ),
            const SizedBox(height: 12),
            _PhotoCard(
              identifier: 'ai-scan-back-photo',
              label: s.aiScanBackPhotoLabel,
              photo: _backPhoto,
              onPick: () => _pickPhoto(front: false),
              enabled: _runningPhase == null,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _supermarketController,
              decoration: InputDecoration(
                labelText: s.aiScanSupermarketLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _brandController,
              decoration: InputDecoration(
                labelText: s.aiScanBrandLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _productNameController,
              decoration: InputDecoration(
                labelText: s.aiScanProductNameLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _portionController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: s.aiScanPortionLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
            if (_runningPhase case final phase?)
              _ProgressCard(phase: phase)
            else if (_result case final result?)
              _ResultCard(
                result: result,
                onApply: () => Navigator.of(
                  context,
                ).pop((result: result, frontPhoto: _frontPhoto)),
              )
            else if (_failure case final failure?)
              _ErrorCard(message: _failureMessage(s, failure))
            else if (_unavailable)
              _ErrorCard(
                message: s.aiScanUnavailableLabel,
                actionLabel: s.settingsLabel,
                onAction: () => Navigator.of(
                  context,
                ).pushNamed(NavigationOptions.settingsRoute),
              ),
            const SizedBox(height: 16),
            Semantics(
              identifier: 'ai-scan-analyze',
              child: FilledButton.icon(
                onPressed: _runningPhase == null ? _analyze : null,
                icon: const Icon(Icons.auto_awesome_rounded),
                label: Text(s.aiScanAnalyzeLabel),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _failureMessage(S s, MealInterpreterFailure failure) =>
      switch (failure) {
        MealInterpreterFailure.auth => s.aiScanKeyRejectedLabel,
        MealInterpreterFailure.billing => s.aiScanNoCreditLabel,
        MealInterpreterFailure.rejected => s.aiScanUnreadablePhotoLabel,
        MealInterpreterFailure.unsupported => s.aiScanUnsupportedLabel,
        MealInterpreterFailure.insecureDestination =>
          s.aiScanInsecureServerLabel,
        MealInterpreterFailure.timeout => s.aiScanTimedOutLabel,
        MealInterpreterFailure.transient => s.aiScanFailedLabel,
      };
}

/// One photo slot: thumbnail when a photo is held, a dashed prompt tile
/// when it is not.
class _PhotoCard extends StatelessWidget {
  final String identifier;
  final String label;
  final MealPhoto? photo;
  final VoidCallback onPick;
  final bool enabled;

  const _PhotoCard({
    required this.identifier,
    required this.label,
    required this.photo,
    required this.onPick,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = isDark ? AppPalette.dark : AppPalette.light;
    return Semantics(
      identifier: identifier,
      child: OutlinedButton(
        onPressed: enabled ? onPick : null,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.all(12),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
        ),
        child: Row(
          children: [
            if (photo != null)
              ClipRRect(
                borderRadius: const BorderRadius.all(Radius.circular(8)),
                child: Image.memory(
                  photo!.bytes,
                  width: 64,
                  height: 64,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                ),
              )
            else
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.all(Radius.circular(8)),
                  border: Border.all(color: palette.textMuted),
                ),
                child: Icon(
                  Icons.add_a_photo_rounded,
                  color: palette.textMuted,
                ),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodyLarge,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProgressCard extends StatelessWidget {
  final AiMealScanPhase phase;

  const _ProgressCard({required this.phase});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final label = switch (phase) {
      AiMealScanPhase.reading => s.aiScanStepReadingLabel,
      AiMealScanPhase.researching => s.aiScanStepResearchLabel,
      AiMealScanPhase.completing => s.aiScanStepCompletingLabel,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 16),
            Expanded(child: Text(label)),
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _ErrorCard({required this.message, this.actionLabel, this.onAction});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: onAction,
                  child: Text(actionLabel!),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The review surface: every value the scan produced with the tag of where
/// it came from, so the numbers worth double-checking against the can in
/// hand are the ones that say "Estimated".
class _ResultCard extends StatelessWidget {
  final AiMealScanResult result;
  final VoidCallback onApply;

  const _ResultCard({required this.result, required this.onApply});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = isDark ? AppPalette.dark : AppPalette.light;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              s.aiScanResultTitle,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            if (result.name case final name?)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  [name, ?result.brand].join(' — '),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            if (result.matchedFoodName case final matched?)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  s.aiScanBasedOnLabel(matched),
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: palette.textMuted),
                ),
              ),
            const SizedBox(height: 8),
            for (final entry in result.nutrients.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        // The same label (and unit) the edit-meal form
                        // shows for this field — one mapping, shared.
                        '${nutrientFieldLabel(s, entry.key)} '
                        '(${aiScanNutrientUnits[entry.key]})',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    Text(
                      _formatValue(entry.value),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _SourceChip(source: result.sources[entry.key]),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Semantics(
              identifier: 'ai-scan-apply',
              child: FilledButton(
                onPressed: onApply,
                child: Text(s.aiScanApplyLabel),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatValue(double value) => value == value.roundToDouble()
      ? '${value.toInt()}'
      : value.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');
}

class _SourceChip extends StatelessWidget {
  final AiLabelValueSource? source;

  const _SourceChip({required this.source});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = isDark ? AppPalette.dark : AppPalette.light;
    final (label, color) = switch (source ?? AiLabelValueSource.estimated) {
      AiLabelValueSource.label => (s.aiScanSourceLabelLabel, Colors.green),
      AiLabelValueSource.database => (s.aiScanSourceDatabaseLabel, Colors.blue),
      AiLabelValueSource.web => (s.aiScanSourceWebLabel, Colors.teal),
      AiLabelValueSource.estimated => (
        s.aiScanSourceEstimatedLabel,
        Colors.orange,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.25 : 0.12),
        borderRadius: const BorderRadius.all(Radius.circular(8)),
      ),
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: palette.textMuted),
      ),
    );
  }
}

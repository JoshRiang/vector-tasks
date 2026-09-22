/// VECTOR Tasks — state an end goal, get a startable plan.
///
/// DESIGN PREMISE
/// --------------
/// The user's problem is not a missing to-do list; it is that a long flat list
/// produces paralysis, so nothing starts. This screen therefore shows exactly
/// ONE task at a time, with a timer that matches that task's own estimate.
/// The rest of the plan exists but stays out of sight until the current task
/// is finished.
///
/// The app never invents a plan locally: the plan comes from the backend,
/// which is the only component that can call a model.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';

void main() => runApp(const VectorTasksApp());

class AppColors {
  static const bgBase = Color(0xFFF5F5F7);
  static const bgTop = Color(0xFFEEF1FF);
  static const glass = Color(0xCCFFFFFF);
  static const accent = Color(0xFF6366F1);
  static const accentSoft = Color(0xFF8B5CF6);
  static const success = Color(0xFF10B981);
  static const danger = Color(0xFFEF4444);
  static const warning = Color(0xFFF59E0B);
  static const textPrimary = Color(0xFF1C1C1E);
  static const textSecondary = Color(0xFF6B7280);
  static const textTertiary = Color(0xFF9CA3AF);
}

class VectorTasksApp extends StatelessWidget {
  const VectorTasksApp({super.key});

  @override
  Widget build(BuildContext context) => const CupertinoApp(
        title: 'Vector Tasks',
        debugShowCheckedModeBanner: false,
        theme: CupertinoThemeData(
          primaryColor: AppColors.accent,
          scaffoldBackgroundColor: AppColors.bgBase,
        ),
        home: GoalPage(),
      );
}

class GoalPage extends StatefulWidget {
  const GoalPage({super.key});

  @override
  State<GoalPage> createState() => _GoalPageState();
}

class _GoalPageState extends State<GoalPage> {
  final _goalController = TextEditingController();
  late final Api _api;

  bool _busy = false;
  String? _error;
  GoalResult? _result;
  int _activeIndex = 0;

  @override
  void initState() {
    super.initState();
    _api = Api(userId: Api.defaultUserId);
    Future.microtask(_loadUserId);
  }

  Future<void> _loadUserId() async {
    final prefs = await SharedPreferences.getInstance();
    // Stable owner id so the server-side morning brief reads the same rows.
    // A random per-install id would split the data and the brief would always
    // report "no goals".
    final id = prefs.getString('vector.user_id') ?? Api.defaultUserId;
    setState(() => _api = Api(userId: id));
  }

  Future<void> _submit() async {
    final goal = _goalController.text.trim();
    if (goal.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await _api.createGoal(goal);
      if (!mounted) return;
      setState(() {
        _result = res;
        _activeIndex = 0;
        _busy = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
  }

  Future<void> _completeCurrent() async {
    final res = _result;
    if (res == null || _activeIndex >= res.tasks.length) return;
    final task = res.tasks[_activeIndex];
    try {
      await _api.setTaskStatus(task['id'].toString(), 'done');
    } on ApiException {
      // Completing locally still moves the user forward; the next sync fixes
      // the server. Blocking here would punish a network blip.
    }
    if (!mounted) return;
    setState(() {
      if (_activeIndex < res.tasks.length - 1) _activeIndex++;
    });
  }

  void _reset() => setState(() {
        _result = null;
        _activeIndex = 0;
        _goalController.clear();
      });

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.bgTop, AppColors.bgBase],
          ),
        ),
        child: SafeArea(
          child: _result == null ? _buildGoalInput() : _buildPlan(),
        ),
      ),
    );
  }

  Widget _buildGoalInput() => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 48, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Vector',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.accent,
                    letterSpacing: 0.4)),
            const SizedBox(height: 10),
            const Text('What do you want\nto be true?',
                style: TextStyle(
                    fontSize: 34,
                    height: 1.15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary)),
            const SizedBox(height: 10),
            const Text(
              'Type one end goal. Not a list of steps — just the outcome. '
              'You will get back the smallest set of tasks that gets you there, '
              'starting with one you can do in under 30 minutes.',
              style: TextStyle(
                  fontSize: 15, height: 1.45, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 26),
            _glass(
              child: CupertinoTextField(
                controller: _goalController,
                placeholder: 'e.g. Get a quant internship in Germany',
                placeholderStyle:
                    const TextStyle(color: AppColors.textTertiary),
                padding: const EdgeInsets.all(16),
                minLines: 3,
                maxLines: 5,
                style: const TextStyle(
                    fontSize: 16, color: AppColors.textPrimary),
                decoration: null,
                onSubmitted: (_) => _submit(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 14),
              Row(children: [
                const Icon(CupertinoIcons.exclamationmark_circle,
                    color: AppColors.danger, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_error!,
                      style: const TextStyle(
                          fontSize: 14, color: AppColors.danger)),
                ),
              ]),
            ],
            const SizedBox(height: 22),
            _primaryButton(
              label: _busy ? 'Thinking…' : 'Build my plan',
              onTap: _busy ? null : _submit,
            ),
          ],
        ),
      );

  Widget _buildPlan() {
    final res = _result!;
    if (res.tasks.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(CupertinoIcons.wifi_slash,
                size: 44, color: AppColors.textTertiary),
            const SizedBox(height: 14),
            const Text('Could not build a plan',
                style: TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              res.note.isEmpty
                  ? 'The server did not return tasks.'
                  : 'Reason: ${res.note}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 14, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 20),
            _primaryButton(label: 'Try another goal', onTap: _reset),
          ],
        ),
      );
    }

    final done = _activeIndex >= res.tasks.length;
    if (done) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(CupertinoIcons.checkmark_circle_fill,
                size: 56, color: AppColors.success),
            const SizedBox(height: 16),
            const Text('Plan complete',
                style: TextStyle(
                    fontSize: 24, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text('${res.tasks.length} tasks · ${res.totalMinutes} minutes',
                style: const TextStyle(
                    fontSize: 15, color: AppColors.textSecondary)),
            const SizedBox(height: 24),
            _primaryButton(label: 'Start a new goal', onTap: _reset),
          ],
        ),
      );
    }

    final task = res.tasks[_activeIndex];
    final total = res.tasks.length;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('STEP ${_activeIndex + 1} OF $total',
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textTertiary,
                      letterSpacing: 0.8)),
              CupertinoButton(
                padding: EdgeInsets.zero,
                minSize: 0,
                onPressed: _reset,
                child: const Text('New goal',
                    style: TextStyle(fontSize: 14, color: AppColors.accent)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Progress is shown as a bar, not a list: the user sees how far
          // along they are without being shown everything left to do.
          // Built from plain containers because LinearProgressIndicator is a
          // Material widget and this app is Cupertino-only.
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Container(
              height: 5,
              color: const Color(0x22000000),
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: total == 0 ? 0 : _activeIndex / total,
                child: Container(color: AppColors.accent),
              ),
            ),
          ),
          const SizedBox(height: 26),
          if (res.degraded) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0x1AF59E0B),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(children: [
                Icon(CupertinoIcons.info,
                    size: 16, color: AppColors.warning),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'This plan is thinner than usual — the assistant could not '
                    'do its best work. You can still start.',
                    style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 18),
          ],
          _glass(
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(task['title']?.toString() ?? '',
                      style: const TextStyle(
                          fontSize: 22,
                          height: 1.3,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary)),
                  if ((task['why'] ?? '').toString().isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(task['why'].toString(),
                        style: const TextStyle(
                            fontSize: 14,
                            height: 1.4,
                            color: AppColors.textSecondary)),
                  ],
                  const SizedBox(height: 18),
                  Row(children: [
                    const Icon(CupertinoIcons.time,
                        size: 16, color: AppColors.textTertiary),
                    const SizedBox(width: 6),
                    Text('about ${task['minutes']} min',
                        style: const TextStyle(
                            fontSize: 14, color: AppColors.textSecondary)),
                  ]),
                ],
              ),
            ),
          ),
          const SizedBox(height: 22),
          _primaryButton(label: 'Done — next', onTap: _completeCurrent),
          const SizedBox(height: 10),
          CupertinoButton(
            padding: const EdgeInsets.symmetric(vertical: 12),
            onPressed: () => setState(() => _activeIndex++),
            child: const Text('Skip this one',
                style: TextStyle(fontSize: 15, color: AppColors.textSecondary)),
          ),
        ],
      ),
    );
  }

  Widget _glass({required Widget child}) => Container(
        decoration: BoxDecoration(
          color: AppColors.glass,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0x14000000)),
          boxShadow: const [
            BoxShadow(
                color: Color(0x0F000000), blurRadius: 24, offset: Offset(0, 8)),
          ],
        ),
        child: child,
      );

  Widget _primaryButton({required String label, VoidCallback? onTap}) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 17),
          decoration: BoxDecoration(
            gradient: onTap == null
                ? null
                : const LinearGradient(
                    colors: [AppColors.accent, AppColors.accentSoft]),
            color: onTap == null ? AppColors.textTertiary : null,
            borderRadius: BorderRadius.circular(16),
            boxShadow: onTap == null
                ? null
                : const [
                    BoxShadow(
                        color: Color(0x336366F1),
                        blurRadius: 18,
                        offset: Offset(0, 8)),
                  ],
          ),
          child: Text(label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: CupertinoColors.white)),
        ),
      );
}

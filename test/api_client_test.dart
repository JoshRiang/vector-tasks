/// Tests for the VECTOR Tasks app.
///
/// These cover the parsing and decision logic that CI can verify without a
/// device or a live server. They are deliberately about BEHAVIOUR (what the
/// app does with a given server response) rather than about widget layout.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_tasks/api_client.dart';

void main() {
  group('GoalResult parsing', () {
    test('reads a healthy plan', () {
      final r = GoalResult.fromJson({
        'goal': {'id': 'g1', 'title': 'Ship it'},
        'tasks': [
          {'id': 't1', 'title': 'A', 'minutes': 20, 'why': 'w'},
          {'id': 't2', 'title': 'B', 'minutes': 40, 'why': 'w'},
        ],
        'degraded': false,
        'note': 'ok',
      });
      expect(r.tasks.length, 2);
      expect(r.degraded, isFalse);
      expect(r.totalMinutes, 60);
    });

    test('sums total minutes across the plan', () {
      final r = GoalResult.fromJson({
        'goal': {},
        'tasks': [
          {'minutes': 15},
          {'minutes': 45},
          {'minutes': 30},
        ],
      });
      expect(r.totalMinutes, 90);
    });

    test('tolerates missing minutes instead of crashing', () {
      final r = GoalResult.fromJson({
        'goal': {},
        'tasks': [
          {'title': 'no minutes field'},
          {'title': 'null minutes', 'minutes': null},
        ],
      });
      expect(r.totalMinutes, 0);
      expect(r.tasks.length, 2);
    });

    test('surfaces a degraded plan', () {
      final r = GoalResult.fromJson({
        'goal': {'id': 'g1'},
        'tasks': [],
        'degraded': true,
        'note': 'llm_unreachable',
      });
      expect(r.degraded, isTrue);
      expect(r.note, 'llm_unreachable');
      expect(r.tasks, isEmpty);
    });

    test('handles an empty body without throwing', () {
      final r = GoalResult.fromJson({});
      expect(r.tasks, isEmpty);
      expect(r.goal, isEmpty);
      expect(r.degraded, isFalse);
    });
  });

  group('ApiException', () {
    test('carries the offline flag so the UI can say "check Tailscale"', () {
      final e = ApiException('Cannot reach the server.', offline: true);
      expect(e.offline, isTrue);
      expect(e.toString(), contains('Cannot reach'));
    });

    test('carries a status code for server errors', () {
      final e = ApiException('db_500', statusCode: 502);
      expect(e.statusCode, 502);
      expect(e.offline, isFalse);
    });
  });

  group('default base url', () {
    test('points at the private Tailscale address, never a public host', () {
      expect(Api.defaultBaseUrl, contains('100.89.180.23'));
      expect(Api.defaultBaseUrl.startsWith('http://'), isTrue);
    });
  });

  group('stable owner id', () {
    test('defaults to a constant so the server-side brief sees the same rows',
        () {
      expect(Api.defaultUserId, 'josh');
    });

    test('is not randomised per install', () {
      // A random id would split data between the app and the cron brief.
      expect(Api.defaultUserId.contains(r'$'), isFalse);
      expect(Api.defaultUserId.length < 40, isTrue);
    });
  });
}

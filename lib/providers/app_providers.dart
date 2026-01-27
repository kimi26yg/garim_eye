import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// Moving Enum here for cleaner architecture if possible, or importing it.
// Ideally, RiskLevel should be defined in a shared model or here.
// For now, I'll redefine it here to avoid circular imports if I move it out of video_call_screen.
// OR better yet, let's create a dedicated models file?
// To keep it simple as per instructions, I will assume RiskLevel is accessible or I will move it.
// Let's first read video_call_screen.dart to see where RiskLevel is defined.
// Ah, it is in video_call_screen.dart. I should probably move it to a shared place or just import it.
// But importing screen in provider is bad practice.
// I will move RiskLevel enum to this file or a separate model file.
// Let's put the Enum here for now.

enum RiskLevel { safe, warning, critical }

final riskLevelProvider = NotifierProvider<RiskLevelNotifier, RiskLevel>(
  RiskLevelNotifier.new,
);

class RiskLevelNotifier extends Notifier<RiskLevel> {
  @override
  RiskLevel build() => RiskLevel.safe;

  @override
  set state(RiskLevel value) => super.state = value;
}

final pipPositionProvider = NotifierProvider<PiPPositionNotifier, Offset?>(
  PiPPositionNotifier.new,
);

class PiPPositionNotifier extends Notifier<Offset?> {
  @override
  Offset? build() => null;

  @override
  set state(Offset? value) => super.state = value; // Helper setter to match previous API usage if possible, or just assign to state
}

final garimProtectionProvider = NotifierProvider<GarimProtectionNotifier, bool>(
  GarimProtectionNotifier.new,
);

class GarimProtectionNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  @override
  set state(bool value) => super.state = value;
}

class CallRecord {
  final String name;
  final DateTime timestamp;
  final bool isScanned;
  final String role; // optional, for display

  CallRecord({
    required this.name,
    required this.timestamp,
    this.isScanned = true,
    this.role = '',
  });
}

final callHistoryProvider =
    NotifierProvider<CallHistoryNotifier, List<CallRecord>>(
      CallHistoryNotifier.new,
    );

class CallHistoryNotifier extends Notifier<List<CallRecord>> {
  @override
  List<CallRecord> build() => [
    CallRecord(
      name: '강혜린',
      timestamp: DateTime.now().subtract(const Duration(hours: 2)),
      role: '팀장님',
    ),
    CallRecord(
      name: '최은선',
      timestamp: DateTime.now().subtract(const Duration(days: 1)),
      role: '팀원',
    ),
  ];

  void addRecord(CallRecord record) {
    state = [record, ...state];
  }
}

final demoPanelPositionProvider =
    NotifierProvider<DemoPanelPositionNotifier, Offset>(
      DemoPanelPositionNotifier.new,
    );

class DemoPanelPositionNotifier extends Notifier<Offset> {
  @override
  // 초기 위치: 화면 우측 하단 적절한 곳
  Offset build() => const Offset(230, 700);

  @override
  set state(Offset value) => super.state = value;
}

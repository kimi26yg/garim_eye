import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import '../providers/app_providers.dart';
import '../providers/call_provider.dart';
import '../theme/app_theme.dart';
import '../services/detection/deepfake_inference_service.dart';

class VideoCallScreen extends ConsumerStatefulWidget {
  const VideoCallScreen({super.key});

  @override
  ConsumerState<VideoCallScreen> createState() => _VideoCallScreenState();
}

class _VideoCallScreenState extends ConsumerState<VideoCallScreen>
    with TickerProviderStateMixin {
  late AnimationController _pulseController;
  late AnimationController _slowPulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..repeat(reverse: true);
    _slowPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000), // 더 천천히 움직임
    )..repeat(reverse: true);

    _initCall();
  }

  Future<void> _initCall() async {
    await [Permission.camera, Permission.microphone].request();

    final status = ref.read(callProvider).status;
    // Only start a new call if we are idle (i.e., pure demo flow).
    // If we are connecting/calling (from Accept), don't reset.
    if (status == CallStatus.idle) {
      ref.read(callProvider.notifier).startCall('test_room');
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _slowPulseController.dispose();
    super.dispose();
  }

  Color _getGlowColor(RiskLevel level) {
    switch (level) {
      case RiskLevel.safe:
        return AppTheme.riskLow;
      case RiskLevel.warning:
        return AppTheme.riskMedium;
      case RiskLevel.critical:
        return AppTheme.riskHigh;
    }
  }

  @override
  Widget build(BuildContext context) {
    final riskLevel = ref.watch(riskLevelProvider);
    final isGarimActive = ref.watch(garimProtectionProvider);
    final pipPosition = ref.watch(pipPositionProvider);
    final demoPos = ref.watch(demoPanelPositionProvider);

    final glowColor = _getGlowColor(riskLevel);

    // Trigger haptics on critical state
    ref.listen(riskLevelProvider, (previous, next) {
      if (next == RiskLevel.critical) {
        HapticFeedback.vibrate();
      }
    });

    // Initialize PiP position if null
    if (pipPosition == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final size = MediaQuery.of(context).size;
        ref.read(pipPositionProvider.notifier).state = Offset(
          size.width - 100 - 16,
          size.height - 140 - 100,
        );
      });
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 1. Background Placeholder (Gradient)
          // 1. Remote Video View (Background)
          // 1. Remote Video View (Background)
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(color: Colors.black),
              child: RTCVideoView(
                ref.watch(callProvider).remoteRenderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              ),
            ),
          ),

          // 2. Vignette Ambient Glow (4방향 완전 정복 버전)
          // 2. Vignette Ambient Glow
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                // 두 컨트롤러 중 하나라도 변하면 화면을 리빌드합니다.
                animation: Listenable.merge([
                  _pulseController,
                  _slowPulseController,
                ]),
                builder: (context, child) {
                  double opacity = 0.4;
                  double baseThickness = 40.0;

                  switch (riskLevel) {
                    case RiskLevel.safe:
                      baseThickness = 40.0;
                      opacity = 0.15;
                      break;

                    case RiskLevel.warning:
                      // 주황색: 느린 컨트롤러(_slowPulseController) 사용
                      // 두께가 70에서 85 사이를 천천히 왕복합니다.
                      baseThickness =
                          70.0 + (_slowPulseController.value * 15.0);
                      opacity = 0.25 + (_slowPulseController.value * 0.15);
                      break;

                    case RiskLevel.critical:
                      // 빨간색: 빠른 컨트롤러(_pulseController) 사용
                      // 두께가 100에서 130 사이를 빠르게 왕복합니다.
                      baseThickness = 100.0 + (_pulseController.value * 30.0);
                      opacity = 0.3 + (_pulseController.value * 0.5);
                      break;
                  }

                  return Stack(
                    children: [
                      _buildEdge(Alignment.topCenter, [
                        glowColor.withValues(alpha: opacity),
                        Colors.transparent,
                      ], thickness: baseThickness),
                      _buildEdge(Alignment.bottomCenter, [
                        Colors.transparent,
                        glowColor.withValues(alpha: opacity),
                      ], thickness: baseThickness),
                      _buildEdge(
                        Alignment.centerLeft,
                        [
                          glowColor.withValues(alpha: opacity),
                          Colors.transparent,
                        ],
                        thickness: baseThickness,
                        isVertical: false,
                      ),
                      _buildEdge(
                        Alignment.centerRight,
                        [
                          Colors.transparent,
                          glowColor.withValues(alpha: opacity),
                        ],
                        thickness: baseThickness,
                        isVertical: false,
                      ),
                    ],
                  );
                },
              ),
            ),
          ),

          // 3. Main Call Content Placeholder
          // 3. Main Call Content Placeholder (Hidden when connected)
          if (ref.watch(callProvider).status != CallStatus.connected)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(color: Colors.white),
                  const SizedBox(height: 16),
                  Text(
                    'Connecting...',
                    style: Theme.of(
                      context,
                    ).textTheme.titleMedium?.copyWith(color: Colors.white),
                  ),
                ],
              ),
            ),

          // 4. Interaction Guide (Bottom Banner) - Only for Critical
          // 4. Interaction Guide (Bottom Banner) - Warning & Critical 모두 대응
          Positioned(
            left: 0,
            right: 0,
            bottom: 120,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 300),
              opacity: riskLevel != RiskLevel.safe ? 1.0 : 0.0,
              child: ClipRRect(
                // 테두리를 깎고 내부를 블러 처리하기 위함
                borderRadius: BorderRadius.circular(12),
                child: BackdropFilter(
                  // 뒤쪽 배경을 흐릿하게 만듦
                  filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 20),
                    padding: const EdgeInsets.symmetric(
                      vertical: 12,
                      horizontal: 16,
                    ),
                    decoration: BoxDecoration(
                      // alpha를 0.4로 낮춰서 더 투명하게 설정
                      color: glowColor.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.2),
                        width: 1.5,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          riskLevel == RiskLevel.critical
                              ? Icons.gpp_maybe
                              : Icons.info_outline,
                          color: Colors.white,
                          size: 28,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            riskLevel == RiskLevel.warning
                                ? '보안 주의: 의심스러운 패턴이 감지되었습니다.'
                                : '딥페이크 감지: 즉시 통화를 종료하세요!',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: Colors.white.withValues(
                                    alpha: 0.9,
                                  ), // 글자는 잘 보여야 하므로 0.9
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // 5. Draggable PiP Window (My View)
          Positioned(
            left: pipPosition?.dx ?? 0,
            top: pipPosition?.dy ?? 0,
            child: GestureDetector(
              onPanUpdate: (details) {
                final size = MediaQuery.of(context).size;
                final pipWidth = 100.0;
                final pipHeight = 140.0;

                double newX = (pipPosition?.dx ?? 0) + details.delta.dx;
                double newY = (pipPosition?.dy ?? 0) + details.delta.dy;

                // Clamping logic
                newX = newX.clamp(0.0, size.width - pipWidth);
                newY = newY.clamp(0.0, size.height - pipHeight);

                ref.read(pipPositionProvider.notifier).state = Offset(
                  newX,
                  newY,
                );
              },
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: 100,
                  height: 140,
                  decoration: BoxDecoration(
                    color: AppTheme.surface,
                    border: Border.all(color: AppTheme.textSecondary, width: 1),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.5),
                        blurRadius: 8,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: RTCVideoView(
                    ref.watch(callProvider).localRenderer,
                    mirror: true,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                ),
              ),
            ),
          ),

          // 6. Top Bar (Back Button & Garim Button)
          Positioned(
            top: 50,
            left: 16,
            right: 16,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_ios, color: Colors.white),
                  onPressed: () => context.go('/'),
                ),
                InkWell(
                  onTap: () {
                    ref.read(garimProtectionProvider.notifier).state =
                        !isGarimActive;
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: isGarimActive
                          ? AppTheme.riskLow.withValues(alpha: 0.2)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: isGarimActive
                            ? AppTheme.riskLow
                            : AppTheme.textSecondary,
                      ),
                      boxShadow: isGarimActive
                          ? [
                              BoxShadow(
                                color: AppTheme.riskLow.withValues(alpha: 0.5),
                                blurRadius: 12,
                              ),
                            ]
                          : [],
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.shield,
                          size: 18,
                          color: isGarimActive
                              ? AppTheme.riskLow
                              : AppTheme.textSecondary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'GARIM',
                          style: TextStyle(
                            color: isGarimActive
                                ? AppTheme.riskLow
                                : AppTheme.textSecondary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 7. Call Controls (Bottom Center)
          Positioned(
            bottom: 30,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildCallControl(
                  Icons.mic_off,
                  Colors.white,
                  Colors.grey.shade800,
                  null,
                ),
                _buildCallControl(
                  Icons.call_end,
                  Colors.white,
                  AppTheme.riskHigh,
                  () {
                    ref.read(callProvider.notifier).hangup();
                    context.go('/ended');
                  },
                ),
                _buildCallControl(
                  Icons.videocam_off,
                  Colors.white,
                  Colors.grey.shade800,
                  null,
                ),
              ],
            ),
          ),
          Positioned(
            left: demoPos.dx,
            top: demoPos.dy,
            child: GestureDetector(
              onPanUpdate: (details) {
                final size = MediaQuery.of(context).size;
                // 버튼의 대략적인 크기 (가로 140, 세로 50 정도로 가정)
                const btnWidth = 50.0;
                const btnHeight = 50.0;

                double newX = demoPos.dx + details.delta.dx;
                double newY = demoPos.dy + details.delta.dy;

                // 화면 밖으로 나가지 않게 가두기 (Clamping)
                newX = newX.clamp(0.0, size.width - btnWidth);
                newY = newY.clamp(0.0, size.height - btnHeight);

                ref.read(demoPanelPositionProvider.notifier).state = Offset(
                  newX,
                  newY,
                );
              },
              child: FloatingActionButton(
                backgroundColor: AppTheme.surface,
                onPressed: () => _showDemoControlPanel(context, ref),
                child: const Icon(Icons.tune, color: AppTheme.primary),
              ),
            ),
          ),
          // Test Overlay
          const Positioned(top: 100, right: 20, child: _DeepfakeMonitor()),
        ],
      ),
    );
  }

  // 헬퍼 위젯 (VideoCallScreen 클래스 내부에 추가)
  Widget _buildEdge(
    Alignment alignment,
    List<Color> colors, {
    required double thickness, // 외부에서 두께를 받습니다.
    bool isVertical = true,
  }) {
    return Align(
      alignment: alignment,
      child: Container(
        // 수직(상/하)일 때는 높이가 두께가 되고, 수평(좌/우)일 때는 너비가 두께가 됩니다.
        width: isVertical ? double.infinity : thickness,
        height: isVertical ? thickness : double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: isVertical ? Alignment.topCenter : Alignment.centerLeft,
            end: isVertical ? Alignment.bottomCenter : Alignment.centerRight,
            colors: colors,
          ),
        ),
      ),
    );
  }

  Widget _buildCallControl(
    IconData icon,
    Color iconColor,
    Color bgColor,
    VoidCallback? onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: bgColor, shape: BoxShape.circle),
        child: Icon(icon, color: iconColor, size: 28),
      ),
    );
  }

  void _showDemoControlPanel(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Demo Control Panel',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildRiskButton(context, ref, RiskLevel.safe, 'Safe'),
                  _buildRiskButton(context, ref, RiskLevel.warning, 'Warning'),
                  _buildRiskButton(
                    context,
                    ref,
                    RiskLevel.critical,
                    'Critical',
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildRiskButton(
    BuildContext context,
    WidgetRef ref,
    RiskLevel level,
    String label,
  ) {
    Color color;
    switch (level) {
      case RiskLevel.safe:
        color = AppTheme.riskLow;
        break;
      case RiskLevel.warning:
        color = AppTheme.riskMedium;
        break;
      case RiskLevel.critical:
        color = AppTheme.riskHigh;
        break;
    }

    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: color.withValues(alpha: 0.2),
        foregroundColor: color,
        side: BorderSide(color: color),
      ),
      onPressed: () {
        ref.read(riskLevelProvider.notifier).state = level;
        Navigator.pop(context); // Close the sheet
      },
      child: Text(label),
    );
  }
}

class _DeepfakeMonitor extends ConsumerStatefulWidget {
  const _DeepfakeMonitor();

  @override
  ConsumerState<_DeepfakeMonitor> createState() => _DeepfakeMonitorState();
}

class _DeepfakeMonitorState extends ConsumerState<_DeepfakeMonitor> {
  final DeepfakeInferenceService _service = DeepfakeInferenceService();
  bool _isActive = false;
  double _lastScore = 0.0;

  @override
  void initState() {
    super.initState();
    _service.initialize();
    _service.scoreStream.listen((score) {
      if (mounted) {
        setState(() => _lastScore = score);
      }
    });
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_isActive) {
      await _service.stop();
      setState(() => _isActive = false);
    } else {
      final remote = ref.read(callProvider).remoteRenderer;
      if (remote.srcObject != null &&
          remote.srcObject!.getVideoTracks().isNotEmpty) {
        final track = remote.srcObject!.getVideoTracks().first;
        await _service.start(track);
        setState(() => _isActive = true);
      } else {
        debugPrint("No remote track found");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    Color statusColor = Colors.green;
    if (_lastScore > 0.8)
      statusColor = Colors.red;
    else if (_lastScore > 0.5)
      statusColor = Colors.orange;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: statusColor, width: 2),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            "Deepfake Probability",
            style: TextStyle(color: Colors.white70, fontSize: 10),
          ),
          const SizedBox(height: 4),
          Text(
            "${(_lastScore * 100).toStringAsFixed(1)}%",
            style: TextStyle(
              color: statusColor,
              fontWeight: FontWeight.bold,
              fontSize: 20,
            ),
          ),
          const SizedBox(height: 8),
          if (_isActive)
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          else
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white24,
                minimumSize: const Size(80, 30),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              onPressed: _toggle,
              child: const Text(
                "Start Detection",
                style: TextStyle(fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }
}

import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/webrtc_service.dart';

enum CallStatus { idle, connecting, calling, connected }

class CallState {
  final CallStatus status;
  final RTCVideoRenderer localRenderer;
  final RTCVideoRenderer remoteRenderer;

  CallState({
    required this.status,
    required this.localRenderer,
    required this.remoteRenderer,
  });

  CallState copyWith({CallStatus? status}) {
    return CallState(
      status: status ?? this.status,
      localRenderer: localRenderer,
      remoteRenderer: remoteRenderer,
    );
  }
}

class CallNotifier extends StateNotifier<CallState> {
  late WebRTCService _webRTCService;

  CallNotifier() : super(_initialState()) {
    _init();
  }

  static CallState _initialState() {
    return CallState(
      status: CallStatus.idle,
      localRenderer: RTCVideoRenderer(),
      remoteRenderer: RTCVideoRenderer(),
    );
  }

  void _init() {
    _initRenderers(state.localRenderer, state.remoteRenderer);

    _webRTCService = WebRTCService();

    _webRTCService.onLocalStream = (stream) {
      state.localRenderer.srcObject = stream;
      // Force update to trigger UI rebuild
      state = state.copyWith(status: state.status);
    };

    _webRTCService.onRemoteStream = (stream) {
      state.remoteRenderer.srcObject = stream;
      state = state.copyWith(status: CallStatus.connected);
    };
  }

  @override
  void dispose() {
    _webRTCService.dispose();
    state.localRenderer.srcObject = null;
    state.remoteRenderer.srcObject = null;
    state.localRenderer.dispose();
    state.remoteRenderer.dispose();
    super.dispose();
  }

  Future<void> _initRenderers(
    RTCVideoRenderer local,
    RTCVideoRenderer remote,
  ) async {
    await local.initialize();
    await remote.initialize();
  }

  Future<void> startCall(String roomId) async {
    state = state.copyWith(status: CallStatus.connecting);
    await _webRTCService.startLocalStream();
    _webRTCService.init(roomId);
    state = state.copyWith(status: CallStatus.calling);
  }

  // Validates or re-initializes; mainly for manual triggering if needed
  Future<void> initialize() async {
    // Renderers are already initialized in constructor -> _init -> _initRenderers
    // But _initRenderers is async, so they might not be ready immediately.
    // However, RTCVideoView handles uninitialized renderers gracefully usually.
  }
}

final callProvider = StateNotifierProvider.autoDispose<CallNotifier, CallState>(
  (ref) {
    return CallNotifier();
  },
);

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

typedef StreamStateCallback = void Function(MediaStream stream);

class WebRTCService {
  IO.Socket? _socket;
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;

  StreamStateCallback? onLocalStream;
  StreamStateCallback? onRemoteStream;

  // Replace with your development machine's local IP
  // Android Emulator: 10.0.2.2
  // Real Device: 192.168.x.x
  static const String _signalingServerUrl = 'http://192.168.45.247:3000';

  final Map<String, dynamic> _configuration = {
    'iceServers': [
      {
        'urls': [
          'stun:stun.l.google.com:19302',
          'stun:stun1.l.google.com:19302',
        ],
      },
    ],
  };

  void init(String roomId) {
    _connectSocket(roomId);
  }

  void _connectSocket(String roomId) {
    _socket = IO.io(_signalingServerUrl, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': false,
    });

    _socket?.connect();

    _socket?.onConnect((_) {
      print('Connected to signaling server');
      _socket?.emit('join', roomId);
    });

    _socket?.on('user-connected', (userId) {
      print('User connected: $userId');
      _createOffer(roomId);
    });

    _socket?.on('offer', (data) async {
      print('Received offer');
      await _handleOffer(data, roomId);
    });

    _socket?.on('answer', (data) async {
      print('Received answer');
      await _handleAnswer(data);
    });

    _socket?.on('ice-candidate', (data) async {
      print('Received ICE candidate');
      await _handleIceCandidate(data);
    });
  }

  Future<void> startLocalStream() async {
    final Map<String, dynamic> mediaConstraints = {
      'audio': true,
      'video': {'facingMode': 'user'},
    };

    try {
      _localStream = await navigator.mediaDevices.getUserMedia(
        mediaConstraints,
      );
      onLocalStream?.call(_localStream!);
    } catch (e) {
      print('Error getting user media: $e');
    }
  }

  Future<void> _createPeerConnection(String roomId) async {
    _peerConnection = await createPeerConnection(_configuration);

    _peerConnection?.onIceCandidate = (RTCIceCandidate candidate) {
      _socket?.emit('ice-candidate', {
        'roomId': roomId,
        'candidate': {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        },
      });
    };

    _peerConnection?.onTrack = (RTCTrackEvent event) {
      if (event.streams.isNotEmpty) {
        onRemoteStream?.call(event.streams[0]);
      }
    };

    _localStream?.getTracks().forEach((track) {
      _peerConnection?.addTrack(track, _localStream!);
    });
  }

  Future<void> _createOffer(String roomId) async {
    await _createPeerConnection(roomId);

    RTCSessionDescription offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);

    _socket?.emit('offer', {'roomId': roomId, 'sdp': offer.toMap()});
  }

  Future<void> _handleOffer(dynamic data, String roomId) async {
    await _createPeerConnection(roomId);

    // Check if sdp is string or map (logic from user context)
    // Assuming simple map for now based on my server implementation
    var sdpData = data['sdp'];

    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(sdpData['sdp'], sdpData['type']),
    );

    RTCSessionDescription answer = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(answer);

    _socket?.emit('answer', {'roomId': roomId, 'sdp': answer.toMap()});
  }

  Future<void> _handleAnswer(dynamic data) async {
    var sdpData = data['sdp'];
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(sdpData['sdp'], sdpData['type']),
    );
  }

  Future<void> _handleIceCandidate(dynamic data) async {
    var candidateData = data['candidate'];
    await _peerConnection!.addCandidate(
      RTCIceCandidate(
        candidateData['candidate'],
        candidateData['sdpMid'],
        candidateData['sdpMLineIndex'],
      ),
    );
  }

  void dispose() {
    _localStream?.dispose();
    _peerConnection?.dispose();
    _socket?.dispose();
  }
}

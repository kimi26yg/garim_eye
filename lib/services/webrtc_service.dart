import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:socket_io_client/socket_io_client.dart' as socket_io;

typedef StreamStateCallback = void Function(MediaStream stream);

class WebRTCService {
  socket_io.Socket? _socket;
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;

  StreamStateCallback? onLocalStream;
  StreamStateCallback? onRemoteStream;

  // Replace with your development machine's local IP
  // Android Emulator: 10.0.2.2
  // Real Device: 192.168.x.x
  static const String _signalingServerUrl = 'http://192.168.45.207:3000';

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
    _socket = socket_io.io(_signalingServerUrl, <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': false,
    });

    _socket?.connect();

    _socket?.onConnect((_) {
      debugPrint('Connected to signaling server');
      debugPrint(
        'Emitting hello join event to room: $roomId (Type: ${roomId.runtimeType})',
      );
      _socket?.emit('join', roomId);
    });

    _socket?.on('user-connected', (userId) {
      debugPrint('User connected: $userId');
      _createOffer(roomId);
    });

    _socket?.on('offer', (data) async {
      debugPrint('Received offer: $data');
      var unwrapped = _unwrapData(data);
      await _handleOffer(unwrapped, roomId);
    });

    _socket?.on('answer', (data) async {
      debugPrint('Received answer: $data');
      var unwrapped = _unwrapData(data);
      await _handleAnswer(unwrapped);
    });

    _socket?.on('ice-candidate', (data) async {
      debugPrint('Received ICE candidate: $data');
      var unwrapped = _unwrapData(data);
      await _handleIceCandidate(unwrapped);
    });
  }

  dynamic _unwrapData(dynamic data) {
    if (data is List && data.isNotEmpty) {
      return data[0];
    }
    return data;
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
      debugPrint('Error getting user media: $e');
    }
  }

  Future<void> _createPeerConnection(String roomId) async {
    _peerConnection = await createPeerConnection(_configuration);

    _peerConnection?.onIceCandidate = (RTCIceCandidate candidate) {
      _socket?.emit('ice-candidate', {
        'roomId': roomId,
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    _peerConnection?.onTrack = (RTCTrackEvent event) {
      debugPrint(
        'WebRTC: onTrack called - kind: ${event.track.kind}, id: ${event.track.id}',
      );

      if (event.streams.isEmpty) {
        debugPrint('WebRTC: Warning - onTrack called but no streams found');
        return;
      }

      var stream = event.streams[0];
      debugPrint(
        'WebRTC: Stream id: ${stream.id}, tracks: ${stream.getTracks().length}',
      );

      if (event.track.kind == 'video') {
        debugPrint('WebRTC: Video track detected! Assigning to provider.');
        onRemoteStream?.call(stream);
      } else if (event.track.kind == 'audio') {
        debugPrint('WebRTC: Audio track detected. Ensuring audio output.');
        event.track.enabled = true;
        if (stream.getVideoTracks().isNotEmpty) {
          onRemoteStream?.call(stream);
        }
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
    if (data is List && data.isNotEmpty) {
      data = data[0];
    }

    await _createPeerConnection(roomId);

    var sdpData = data['sdp'];
    String sdp;
    String type;

    if (sdpData is String) {
      sdp = sdpData;
      type = 'offer';
      debugPrint('Warning: Received SDP as String, assuming type="offer"');
    } else {
      sdp = sdpData['sdp'];
      type = sdpData['type'];
    }

    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(sdp, type),
    );

    RTCSessionDescription answer = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(answer);

    // Flattened Answer Payload
    _socket?.emit('answer', {
      'roomId': roomId,
      'sdp': answer.sdp,
      'type': answer.type,
    });
  }

  Future<void> _handleAnswer(dynamic data) async {
    if (data is List && data.isNotEmpty) {
      data = data[0];
    }

    var sdpData = data['sdp'];
    String sdp;
    String type;

    if (sdpData is String) {
      sdp = sdpData;
      type = 'answer';
      debugPrint('Warning: Received SDP as String, assuming type="answer"');
    } else {
      sdp = sdpData['sdp'];
      type = sdpData['type'];
    }

    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(sdp, type),
    );
  }

  Future<void> _handleIceCandidate(dynamic data) async {
    if (data is List && data.isNotEmpty) {
      data = data[0];
    }

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

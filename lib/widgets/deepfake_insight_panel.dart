import 'package:flutter/material.dart';
import '../services/detection/deepfake_inference_service.dart';

class DeepfakeInsightPanel extends StatelessWidget {
  final DeepfakeState state;
  final VoidCallback? onClose;

  const DeepfakeInsightPanel({Key? key, required this.state, this.onClose})
    : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 280,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.85),
        border: Border(left: BorderSide(color: Colors.white12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          const SizedBox(height: 20),
          _buildGaugeSection(),
          const Divider(color: Colors.white24, height: 30),
          _buildDetailSection(),
          const Divider(color: Colors.white24, height: 30),
          _buildIntervalSection(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Icon(Icons.shield, color: _getStatusColor(state.status)),
            const SizedBox(width: 8),
            Text(
              "SECURITY INSIGHT",
              style: TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
        if (onClose != null)
          GestureDetector(
            onTap: onClose,
            child: Icon(Icons.close, color: Colors.white54, size: 20),
          ),
      ],
    );
  }

  Widget _buildGaugeSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("TRUST SCORE", style: _labelStyle()),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              state.finalScore.toStringAsFixed(1),
              style: TextStyle(
                color: _getStatusColor(state.status),
                fontSize: 48,
                fontWeight: FontWeight.w200, // Thin font for futuristic look
                fontFamily: 'Courier', // Monospace-ish
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 8, left: 4),
              child: Text("/ 100.0", style: TextStyle(color: Colors.white38)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _buildProgressBar(
          state.finalScore / 100.0,
          _getStatusColor(state.status),
        ),
        const SizedBox(height: 4),
        Text(
          _getStatusText(state.status, state.finalScore),
          style: TextStyle(color: _getStatusColor(state.status), fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildDetailSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("ENGINE BREAKDOWN", style: _labelStyle()),
        const SizedBox(height: 12),
        _buildStatRow("FFT Signal (10)", state.fftScore.toStringAsFixed(1)),
        if (state.isPenalized)
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 2),
            child: Text(
              "⚠️ Variance Penalty Applied",
              style: TextStyle(color: Colors.orange, fontSize: 10),
            ),
          ),
        _buildStatRow("Variance", state.fftVariance.toStringAsFixed(0)),
        const SizedBox(height: 8),
        _buildStatRow("AI Vision (90)", state.aiScore.toStringAsFixed(1)),
      ],
    );
  }

  Widget _buildIntervalSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("SAMPLING", style: _labelStyle()),
        const SizedBox(height: 12),
        _buildStatRow("Interval", "${state.interval}s"),
        const SizedBox(height: 8),
        // Visualize Interval
        Row(
          children: [
            _buildIntervalDot(10.0),
            const SizedBox(width: 4),
            _buildIntervalDot(5.0),
            const SizedBox(width: 4),
            _buildIntervalDot(1.25),
          ],
        ),
      ],
    );
  }

  Widget _buildIntervalDot(double val) {
    bool active = state.interval == val;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: active ? Colors.blue : Colors.white10,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        "${val}s",
        style: TextStyle(
          fontSize: 10,
          color: active ? Colors.white : Colors.white38,
        ),
      ),
    );
  }

  Widget _buildStatRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(color: Colors.white70, fontSize: 13)),
        Text(
          value,
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontFamily: 'Courier',
          ),
        ),
      ],
    );
  }

  Widget _buildProgressBar(double value, Color color) {
    return Container(
      height: 4,
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(2),
      ),
      child: FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: value.clamp(0.0, 1.0),
        child: Container(
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }

  TextStyle _labelStyle() => TextStyle(
    color: Colors.white38,
    fontSize: 10,
    fontWeight: FontWeight.bold,
  );

  Color _getStatusColor(DetectionStatus status) {
    if (status.name == 'safe') return Colors.greenAccent;
    if (status.name == 'warning') return Colors.orangeAccent;
    return Colors.redAccent;
  }

  String _getStatusText(DetectionStatus status, double score) {
    if (score >= 95.0) return "ULTRA HD SAFE";
    if (status.name == 'safe') return "SAFE";
    if (status.name == 'warning') return "LOW SIGNAL QUALITY";
    return "DANGER DETECTED";
  }
}

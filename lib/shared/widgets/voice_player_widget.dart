import 'dart:async';

import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:syncnote/shared/services/upload_service.dart';

class VoicePlayerWidget extends StatefulWidget {
  final String url;

  const VoicePlayerWidget({super.key, required this.url});

  @override
  State<VoicePlayerWidget> createState() => _VoicePlayerWidgetState();
}

class _VoicePlayerWidgetState extends State<VoicePlayerWidget> {
  late final AudioPlayer _audioPlayer;
  bool _isPlaying = false;
  bool _isDownloading = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  StreamSubscription? _durationSub;
  StreamSubscription? _positionSub;
  StreamSubscription? _playerStateSub;

  @override
  void initState() {
    super.initState();
    _audioPlayer = AudioPlayer();

    _durationSub = _audioPlayer.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });

    _positionSub = _audioPlayer.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });

    _playerStateSub = _audioPlayer.onPlayerStateChanged.listen((state) {
      if (mounted) {
        setState(() {
          _isPlaying = state == PlayerState.playing;
        });
      }
    });
  }

  @override
  void dispose() {
    _durationSub?.cancel();
    _positionSub?.cancel();
    _playerStateSub?.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _togglePlay() async {
    try {
      if (_isPlaying) {
        await _audioPlayer.pause();
      } else {
        if (widget.url.startsWith('webdav://')) {
          setState(() => _isDownloading = true);
          final localPath = await WebdavCacheManager.instance.resolveLocalPath(
            widget.url,
          );
          if (mounted) setState(() => _isDownloading = false);
          await _audioPlayer.play(DeviceFileSource(localPath));
        } else {
          final Source source;
          if (widget.url.startsWith('http://') ||
              widget.url.startsWith('https://')) {
            source = UrlSource(widget.url);
          } else {
            source = DeviceFileSource(widget.url);
          }
          await _audioPlayer.play(source);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isDownloading = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('录音加载失败：$e')));
      }
      debugPrint('Voice playback error: $e');
    }
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cardBg = theme.brightness == Brightness.dark
        ? Colors.grey.withValues(alpha: 0.1)
        : theme.colorScheme.primary.withValues(alpha: 0.05);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.1)),
      ),
      child: Row(
        children: [
          IconButton(
            icon: _isDownloading
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                : Icon(
                    _isPlaying
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_fill,
                    color: theme.colorScheme.primary,
                    size: 32,
                  ),
            onPressed: _isDownloading ? null : _togglePlay,
          ),
          const SizedBox(width: 8),
          Text(_formatDuration(_position), style: theme.textTheme.bodySmall),
          Expanded(
            child: Slider(
              min: 0,
              max: _duration.inMilliseconds.toDouble() > 0
                  ? _duration.inMilliseconds.toDouble()
                  : 1.0,
              value: _position.inMilliseconds.toDouble().clamp(
                0.0,
                _duration.inMilliseconds.toDouble() > 0
                    ? _duration.inMilliseconds.toDouble()
                    : 1.0,
              ),
              activeColor: theme.colorScheme.primary,
              inactiveColor: theme.colorScheme.primary.withValues(alpha: 0.2),
              onChanged: (val) async {
                final targetPosition = Duration(milliseconds: val.toInt());
                await _audioPlayer.seek(targetPosition);
              },
            ),
          ),
          Text(_formatDuration(_duration), style: theme.textTheme.bodySmall),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

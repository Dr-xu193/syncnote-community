import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

class AudioRecordService {
  AudioRecordService._();
  static final AudioRecordService instance = AudioRecordService._();

  final AudioRecorder _audioRecorder = AudioRecorder();

  /// Requests permission and starts recording an audio file.
  Future<bool> startRecording() async {
    try {
      if (await _audioRecorder.hasPermission()) {
        final dir = await getTemporaryDirectory();
        final path = '${dir.path}/syncnote_voice_${const Uuid().v4()}.m4a';

        await _audioRecorder.start(
          const RecordConfig(encoder: AudioEncoder.aacLc, numChannels: 1),
          path: path,
        );
        return true;
      }
    } catch (e) {
      // Ignore
    }
    return false;
  }

  /// Stops recording and returns the path to the recorded audio file.
  Future<String?> stopRecording() async {
    try {
      final path = await _audioRecorder.stop();
      return path;
    } catch (e) {
      return null;
    }
  }

  /// Cleans up any resources
  void dispose() {
    _audioRecorder.dispose();
  }
}

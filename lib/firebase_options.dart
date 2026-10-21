import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'core/community_config.dart';

/// Each installation connects to the Firebase project its user supplies.
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform => CommunityConfig.firebaseOptions;
}

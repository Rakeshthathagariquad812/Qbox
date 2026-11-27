import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Taps on notifications QBOX shows itself (calendar reminders, and push
/// notifications that came while QBOX was open), by their payload.
/// Every part of the app that sets up local notifications passes [onLocalNotificationTap],
/// so a later setup never drops an earlier one's taps.
final StreamController<String?> notificationTaps = StreamController<String?>.broadcast();

void onLocalNotificationTap(NotificationResponse response) => notificationTaps.add(response.payload);

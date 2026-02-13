import 'package:dio/dio.dart';
import 'api_service.dart';

class UserNotificationSettings {
  final bool meetingInviteEmailEnabled;
  final bool meetingRsvpEmailToOrganizerEnabled;
  final bool meetingUpdateEmailEnabled;
  final bool meetingCancelEmailEnabled;
  final bool meetingSelfInviteEmailEnabled;

  const UserNotificationSettings({
    required this.meetingInviteEmailEnabled,
    required this.meetingRsvpEmailToOrganizerEnabled,
    required this.meetingUpdateEmailEnabled,
    required this.meetingCancelEmailEnabled,
    required this.meetingSelfInviteEmailEnabled,
  });

  factory UserNotificationSettings.fromJson(Map<String, dynamic> json) {
    return UserNotificationSettings(
      meetingInviteEmailEnabled: json['meetingInviteEmailEnabled'] == true,
      meetingRsvpEmailToOrganizerEnabled:
          json['meetingRsvpEmailToOrganizerEnabled'] == true,
      meetingUpdateEmailEnabled: json['meetingUpdateEmailEnabled'] == true,
      meetingCancelEmailEnabled: json['meetingCancelEmailEnabled'] == true,
      meetingSelfInviteEmailEnabled:
          json['meetingSelfInviteEmailEnabled'] == true,
    );
  }
}

class UserNotificationSettingsService {
  static Future<UserNotificationSettings> fetch() async {
    await ApiService.instance.init();
    final response = await ApiService.instance.get(
      '/api/user/notification-settings',
    );
    return UserNotificationSettings.fromJson(
      Map<String, dynamic>.from(response.data as Map),
    );
  }

  static Future<UserNotificationSettings> update({
    bool? meetingInviteEmailEnabled,
    bool? meetingRsvpEmailToOrganizerEnabled,
    bool? meetingUpdateEmailEnabled,
    bool? meetingCancelEmailEnabled,
    bool? meetingSelfInviteEmailEnabled,
  }) async {
    await ApiService.instance.init();

    final data = <String, dynamic>{};
    if (meetingInviteEmailEnabled != null) {
      data['meetingInviteEmailEnabled'] = meetingInviteEmailEnabled;
    }
    if (meetingRsvpEmailToOrganizerEnabled != null) {
      data['meetingRsvpEmailToOrganizerEnabled'] =
          meetingRsvpEmailToOrganizerEnabled;
    }
    if (meetingUpdateEmailEnabled != null) {
      data['meetingUpdateEmailEnabled'] = meetingUpdateEmailEnabled;
    }
    if (meetingCancelEmailEnabled != null) {
      data['meetingCancelEmailEnabled'] = meetingCancelEmailEnabled;
    }
    if (meetingSelfInviteEmailEnabled != null) {
      data['meetingSelfInviteEmailEnabled'] = meetingSelfInviteEmailEnabled;
    }

    final response = await ApiService.instance.patch(
      '/api/user/notification-settings',
      data: data,
      options: Options(
        contentType: 'application/json',
        extra: const {'withCredentials': true},
      ),
    );

    final body = Map<String, dynamic>.from(response.data as Map);
    return UserNotificationSettings(
      meetingInviteEmailEnabled: body['meetingInviteEmailEnabled'] == true,
      meetingRsvpEmailToOrganizerEnabled:
          body['meetingRsvpEmailToOrganizerEnabled'] == true,
      meetingUpdateEmailEnabled: body['meetingUpdateEmailEnabled'] == true,
      meetingCancelEmailEnabled: body['meetingCancelEmailEnabled'] == true,
      meetingSelfInviteEmailEnabled:
          body['meetingSelfInviteEmailEnabled'] == true,
    );
  }
}

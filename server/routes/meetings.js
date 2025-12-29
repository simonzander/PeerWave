const express = require('express');
const router = express.Router();
const meetingService = require('../services/meetingService');
const presenceService = require('../services/presenceService');
const { verifySessionAuth, verifyAuthEither } = require('../middleware/sessionAuth');
const { hasServerPermission } = require('../db/roleHelpers');
const nodemailer = require('nodemailer');
const config = require('../config/config');
const writeQueue = require('../db/writeQueue');
const { MeetingRsvp, User, ServerSettings } = require('../db/model');
const emailService = require('../services/emailService');
const { createRsvpToken, verifyRsvpToken } = require('../services/meetingRsvpTokenService');

const RSVP_STATUSES = new Set(['accepted', 'tentative', 'declined']);

const isEmailLike = (value) => {
  if (!value) return false;
  const s = String(value).trim();
  return s.includes('@') && isValidEmail(s);
};

const uniqLower = (values) => {
  const out = [];
  const seen = new Set();
  for (const v of values || []) {
    const k = normalizeInviteeKey(v);
    if (!k || seen.has(k)) continue;
    seen.add(k);
    out.push(v);
  }
  return out;
};

function diffInvitees(oldList, newList) {
  const oldKeys = new Set((oldList || []).map(normalizeInviteeKey).filter(Boolean));
  const newKeys = new Set((newList || []).map(normalizeInviteeKey).filter(Boolean));

  const added = [];
  const removed = [];

  for (const v of newList || []) {
    const k = normalizeInviteeKey(v);
    if (!k) continue;
    if (!oldKeys.has(k)) added.push(v);
  }
  for (const v of oldList || []) {
    const k = normalizeInviteeKey(v);
    if (!k) continue;
    if (!newKeys.has(k)) removed.push(v);
  }

  return { added: uniqLower(added), removed: uniqLower(removed) };
}

async function loadServerName() {
  const settings = await ServerSettings.findOne({ where: { id: 1 } });
  return settings?.server_name || 'PeerWave Server';
}

function buildMeetingUrls(req, meetingId) {
  const baseUrl = getBaseUrl(req);
  return {
    baseUrl,
    openMeetingsUrl: `${baseUrl}/#/app/meetings`,
    prejoinUrl: `${baseUrl}/#/meeting/prejoin/${encodeURIComponent(meetingId)}`,
  };
}

function buildRsvpUrls(req, meetingId, normalizedEmail) {
  const rsvpToken = createRsvpToken({ meetingId, email: normalizedEmail });
  const baseUrl = getBaseUrl(req);
  const rsvpBase = `${baseUrl}/api/meetings/${meetingId}/rsvp`;
  return {
    rsvpToken,
    accepted: `${rsvpBase}/accepted?email=${encodeURIComponent(normalizedEmail)}&token=${encodeURIComponent(rsvpToken)}`,
    tentative: `${rsvpBase}/tentative?email=${encodeURIComponent(normalizedEmail)}&token=${encodeURIComponent(rsvpToken)}`,
    declined: `${rsvpBase}/declined?email=${encodeURIComponent(normalizedEmail)}&token=${encodeURIComponent(rsvpToken)}`,
  };
}

function buildIcsUid(meeting, meetingId, serverName) {
  const uidDomain = String(serverName || 'PeerWave').replace(/\s/g, '');
  const stableId = meeting?.meeting_id || meeting?.meetingId || meetingId || meeting?.id || 'meeting';
  return `${stableId}@${uidDomain}`;
}

function buildIcsSequence(meeting, fallback = 1) {
  const updated = meeting.updated_at || meeting.updatedAt || meeting.updatedAt;
  const dt = updated ? new Date(updated) : null;
  if (!dt || Number.isNaN(dt.getTime())) return fallback;
  return Math.max(1, Math.floor(dt.getTime() / 1000));
}

async function sendInternalInviteEmail({ req, meeting, meetingId, user, inviterUsername, serverName }) {
  if (!user?.email) return;
  if (!config.smtp?.auth?.user) throw new Error('SMTP is not configured');
  if (user.meeting_invite_email_enabled !== true) return;

  const email = String(user.email).trim();
  if (!isValidEmail(email)) return;

  const normalizedEmail = email.toLowerCase();
  const urls = buildMeetingUrls(req, meetingId);
  const rsvp = buildRsvpUrls(req, meetingId, normalizedEmail);

  const startTime = new Date(meeting.start_time);
  const endTime = new Date(meeting.end_time);
  const dateOptions = { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' };
  const timeOptions = { hour: '2-digit', minute: '2-digit', timeZoneName: 'short' };

  const uid = buildIcsUid(meeting, meetingId, serverName);

  const icsContent = `BEGIN:VCALENDAR
PRODID:-//PeerWave//Meeting Invite//EN
VERSION:2.0
CALSCALE:GREGORIAN
METHOD:REQUEST
BEGIN:VEVENT
UID:${uid}
DTSTAMP:${formatICalDateUtc(new Date())}
DTSTART:${formatICalDateUtc(startTime)}
DTEND:${formatICalDateUtc(endTime)}
SUMMARY:${meeting.title}
DESCRIPTION:${meeting.description || ''}\n\nOpen Meetings: ${urls.openMeetingsUrl}\nJoin: ${urls.prejoinUrl}
ORGANIZER;CN=${inviterUsername}:mailto:${config.smtp.auth.user}
ATTENDEE;CN=${email};ROLE=REQ-PARTICIPANT;RSVP=TRUE:mailto:${email}
LOCATION:${urls.prejoinUrl}
STATUS:CONFIRMED
SEQUENCE:0
END:VEVENT
END:VCALENDAR`.trim();

  await emailService.sendEmail({
    smtpConfig: config.smtp,
    message: {
      from: config.smtp.auth.user,
      to: email,
      subject: `${inviterUsername} invited you to "${meeting.title}" on ${serverName}`,
      html: `
        <div style="font-family:'Nunito Sans', system-ui, -apple-system, sans-serif; background-color:#0f1419; padding:40px 16px; color:#d6dde3;">
          <div style="max-width:600px; margin:0 auto; background-color:#141b22; border-radius:12px; padding:32px; box-shadow:0 0 0 1px rgba(0, 188, 212, 0.08);">
            <h2 style="margin-top:0; color:#2dd4bf; font-weight:600; letter-spacing:0.3px;">You're Invited to a Meeting!</h2>
            <p style="color:#cbd5dc; line-height:1.6;"><strong style="color:#ffffff;">${inviterUsername}</strong> invited you to a meeting on ${serverName}.</p>
            <div style="margin:24px 0; padding:20px; background-color:#0f1419; border-radius:10px; border:1px solid rgba(45, 212, 191, 0.15);">
              <h3 style="margin-top:0; color:#2dd4bf; font-size:16px;">Meeting Details</h3>
              <p style="margin:0 0 8px 0; color:#cbd5dc;"><strong style="color:#2dd4bf;">Title</strong><br>${meeting.title}</p>
              ${meeting.description ? `<p style="margin:0 0 8px 0; color:#cbd5dc;"><strong style="color:#2dd4bf;">Description</strong><br>${meeting.description}</p>` : ''}
              <p style="margin:0 0 8px 0; color:#cbd5dc;"><strong style="color:#2dd4bf;">Date</strong><br>${startTime.toLocaleDateString('en-US', dateOptions)}</p>
              <p style="margin:0; color:#cbd5dc;"><strong style="color:#2dd4bf;">Time</strong><br>${startTime.toLocaleTimeString('en-US', timeOptions)} – ${endTime.toLocaleTimeString('en-US', timeOptions)}</p>
            </div>
            <div style="margin:28px 0;">
              <a href="${urls.openMeetingsUrl}" style="background-color:#2dd4bf; color:#062726; padding:14px 22px; text-decoration:none; border-radius:8px; font-weight:600; display:inline-block; margin-right:8px;">Open Meetings</a>
              <a href="${urls.prejoinUrl}" style="background-color:#1f8f78; color:#e6fffa; padding:14px 22px; text-decoration:none; border-radius:8px; font-weight:600; display:inline-block;">Join Meeting</a>
            </div>
            <div style="margin:32px 0;">
              <p style="margin:0 0 12px 0; color:#9fb3bf;"><strong>RSVP</strong></p>
              <a href="${rsvp.accepted}" style="background-color:#1f8f78; color:#e6fffa; padding:10px 16px; text-decoration:none; border-radius:6px; display:inline-block; margin-right:8px; font-weight:500;">Accept</a>
              <a href="${rsvp.tentative}" style="background-color:#3b3f46; color:#e5e7eb; padding:10px 16px; text-decoration:none; border-radius:6px; display:inline-block; margin-right:8px; font-weight:500;">Tentative</a>
              <a href="${rsvp.declined}" style="background-color:#7f1d1d; color:#fee2e2; padding:10px 16px; text-decoration:none; border-radius:6px; display:inline-block; font-weight:500;">Decline</a>
              <p style="margin-top:12px; font-size:12px; color:#7b8a94;">These links expire in 30 days.</p>
            </div>
            <hr style="border:none; border-top:1px solid rgba(255,255,255,0.06); margin:32px 0;">
            <p style="font-size:12px; color:#6b7c86; margin:0;">Sent from ${serverName}<br><a href="https://peerwave.org" style="text-decoration: none; display: flex; align-items: center;"><img src="https://peerwave.org/logo_28.png" style="width:24px;height:24px;padding-right: 0.25rem;"/><span style="color:white;">PeerWave</span><span style="color:#4fbfb3;"> - Private communication you fully control.</span></a></p>
          </div>
        </div>
      `,
      alternatives: [
        {
          contentType: 'text/calendar; method=REQUEST; charset=UTF-8',
          content: icsContent,
        },
      ],
      attachments: [
        {
          filename: 'invite.ics',
          content: icsContent,
          contentType: 'text/calendar; charset=UTF-8; method=REQUEST',
        },
      ],
    },
  });
}

async function sendMeetingUpdateEmail({ req, meeting, meetingId, recipientEmail, recipientLabel, inviterUsername, serverName, isInternalUser }) {
  if (!recipientEmail || !isValidEmail(recipientEmail)) return;
  if (!config.smtp?.auth?.user) throw new Error('SMTP is not configured');

  const normalizedEmail = String(recipientEmail).toLowerCase();
  const urls = buildMeetingUrls(req, meetingId);
  const rsvp = buildRsvpUrls(req, meetingId, normalizedEmail);

  const startTime = new Date(meeting.start_time);
  const endTime = new Date(meeting.end_time);
  const dateOptions = { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' };
  const timeOptions = { hour: '2-digit', minute: '2-digit', timeZoneName: 'short' };

  const uid = buildIcsUid(meeting, meetingId, serverName);
  const sequence = buildIcsSequence(meeting, 1);

  const icsContent = `BEGIN:VCALENDAR
PRODID:-//PeerWave//Meeting Update//EN
VERSION:2.0
CALSCALE:GREGORIAN
METHOD:REQUEST
BEGIN:VEVENT
UID:${uid}
DTSTAMP:${formatICalDateUtc(new Date())}
DTSTART:${formatICalDateUtc(startTime)}
DTEND:${formatICalDateUtc(endTime)}
SUMMARY:${meeting.title}
DESCRIPTION:${meeting.description || ''}\n\nOpen Meetings: ${urls.openMeetingsUrl}\nJoin: ${urls.prejoinUrl}
ORGANIZER;CN=${inviterUsername}:mailto:${config.smtp.auth.user}
ATTENDEE;CN=${recipientLabel || recipientEmail};ROLE=REQ-PARTICIPANT;RSVP=TRUE:mailto:${recipientEmail}
LOCATION:${urls.prejoinUrl}
STATUS:CONFIRMED
SEQUENCE:${sequence}
END:VEVENT
END:VCALENDAR`.trim();

  const actionUrl = isInternalUser ? urls.openMeetingsUrl : urls.prejoinUrl;
  const actionLabel = isInternalUser ? 'Open Meetings' : 'Join Meeting';

  await emailService.sendEmail({
    smtpConfig: config.smtp,
    message: {
      from: config.smtp.auth.user,
      to: recipientEmail,
      subject: `Updated: "${meeting.title}" on ${serverName}`,
      html: `
        <div style="font-family:'Nunito Sans', system-ui, -apple-system, sans-serif; background-color:#0f1419; padding:40px 16px; color:#d6dde3;">
          <div style="max-width:600px; margin:0 auto; background-color:#141b22; border-radius:12px; padding:32px; box-shadow:0 0 0 1px rgba(0, 188, 212, 0.08);">
            <h2 style="margin-top:0; color:#2dd4bf; font-weight:600; letter-spacing:0.3px;">Meeting Updated</h2>
            <p style="color:#cbd5dc; line-height:1.6;">The meeting <strong style="color:#ffffff;">${meeting.title}</strong> has been updated.</p>
            <div style="margin:24px 0; padding:20px; background-color:#0f1419; border-radius:10px; border:1px solid rgba(45, 212, 191, 0.15);">
              <p style="margin:0 0 8px 0; color:#cbd5dc;"><strong style="color:#2dd4bf;">Date</strong><br>${startTime.toLocaleDateString('en-US', dateOptions)}</p>
              <p style="margin:0; color:#cbd5dc;"><strong style="color:#2dd4bf;">Time</strong><br>${startTime.toLocaleTimeString('en-US', timeOptions)} – ${endTime.toLocaleTimeString('en-US', timeOptions)}</p>
            </div>
            <div style="margin:28px 0;">
              <a href="${actionUrl}" style="background-color:#2dd4bf; color:#062726; padding:14px 22px; text-decoration:none; border-radius:8px; font-weight:600; display:inline-block;">${actionLabel}</a>
            </div>
            <div style="margin:32px 0;">
              <p style="margin:0 0 12px 0; color:#9fb3bf;"><strong>RSVP</strong></p>
              <a href="${rsvp.accepted}" style="background-color:#1f8f78; color:#e6fffa; padding:10px 16px; text-decoration:none; border-radius:6px; display:inline-block; margin-right:8px; font-weight:500;">Accept</a>
              <a href="${rsvp.tentative}" style="background-color:#3b3f46; color:#e5e7eb; padding:10px 16px; text-decoration:none; border-radius:6px; display:inline-block; margin-right:8px; font-weight:500;">Tentative</a>
              <a href="${rsvp.declined}" style="background-color:#7f1d1d; color:#fee2e2; padding:10px 16px; text-decoration:none; border-radius:6px; display:inline-block; font-weight:500;">Decline</a>
              <p style="margin-top:12px; font-size:12px; color:#7b8a94;">These links expire in 30 days.</p>
            </div>
            <hr style="border:none; border-top:1px solid rgba(255,255,255,0.06); margin:32px 0;">
            <p style="font-size:12px; color:#6b7c86; margin:0;">Sent from ${serverName}<br><a href="https://peerwave.org" style="text-decoration: none; display: flex; align-items: center;"><img src="https://peerwave.org/logo_28.png" style="width:24px;height:24px;padding-right: 0.25rem;"/><span style="color:white;">PeerWave</span><span style="color:#4fbfb3;"> - Private communication you fully control.</span></a></p>
          </div>
        </div>
      `,
      alternatives: [
        {
          contentType: 'text/calendar; method=REQUEST; charset=UTF-8',
          content: icsContent,
        },
      ],
      attachments: [
        {
          filename: 'update.ics',
          content: icsContent,
          contentType: 'text/calendar; charset=UTF-8; method=REQUEST',
        },
      ],
    },
  });
}

async function sendMeetingCancelEmail({ meeting, meetingId, attendeeEmail, organizerLabel, serverName }) {
  if (!attendeeEmail || !isValidEmail(attendeeEmail)) return;
  if (!config.smtp?.auth?.user) return;

  const startTime = new Date(meeting.start_time);
  const endTime = new Date(meeting.end_time);

  const uid = buildIcsUid(meeting, meetingId, serverName);
  const icsCancelContent = `BEGIN:VCALENDAR
PRODID:-//PeerWave//Meeting Cancel//EN
VERSION:2.0
CALSCALE:GREGORIAN
METHOD:CANCEL
BEGIN:VEVENT
UID:${uid}
DTSTAMP:${formatICalDateUtc(new Date())}
DTSTART:${formatICalDateUtc(startTime)}
DTEND:${formatICalDateUtc(endTime)}
SUMMARY:${meeting.title}
DESCRIPTION:${meeting.description || ''}
ORGANIZER;CN=${organizerLabel}:mailto:${config.smtp.auth.user}
ATTENDEE;CN=${attendeeEmail};ROLE=REQ-PARTICIPANT:mailto:${attendeeEmail}
STATUS:CANCELLED
SEQUENCE:${buildIcsSequence(meeting, 1)}
END:VEVENT
END:VCALENDAR`.trim();

  await emailService.sendEmail({
    smtpConfig: config.smtp,
    message: {
      from: config.smtp.auth.user,
      to: attendeeEmail,
      subject: `Cancelled: "${meeting.title}" on ${serverName}`,
      html: `
        <div style="font-family:'Nunito Sans', system-ui, -apple-system, sans-serif; background-color:#0f1419; padding:40px 16px; color:#d6dde3;">
          <div style="max-width:600px; margin:0 auto; background-color:#141b22; border-radius:12px; padding:32px; box-shadow:0 0 0 1px rgba(0, 188, 212, 0.08);">
            <h2 style="margin-top:0; color:#ef4444; font-weight:600; letter-spacing:0.3px;">Meeting Cancelled</h2>
            <p style="color:#cbd5dc; line-height:1.6;"><strong style="color:#ffffff;">${meeting.title}</strong> was cancelled or you were removed from the invite list.</p>
            <hr style="border:none; border-top:1px solid rgba(255,255,255,0.06); margin:32px 0;">
            <p style="font-size:12px; color:#6b7c86; margin:0;">Sent from ${serverName}<br><a href="https://peerwave.org" style="text-decoration: none; display: flex; align-items: center;"><img src="https://peerwave.org/logo_28.png" style="width:24px;height:24px;padding-right: 0.25rem;"/><span style="color:white;">PeerWave</span><span style="color:#4fbfb3;"> - Private communication you fully control.</span></a></p>
          </div>
        </div>
      `,
      alternatives: [
        {
          contentType: 'text/calendar; method=CANCEL; charset=UTF-8',
          content: icsCancelContent,
        },
      ],
      attachments: [
        {
          filename: 'cancel.ics',
          content: icsCancelContent,
          contentType: 'text/calendar; charset=UTF-8; method=CANCEL',
        },
      ],
    },
  });
}

async function resolveUsersForIds(userIds) {
  const ids = (userIds || []).filter(Boolean);
  if (ids.length === 0) return new Map();
  const rows = await User.findAll({
    where: { uuid: ids },
    attributes: [
      'uuid',
      'email',
      'displayName',
      'atName',
      'meeting_invite_email_enabled',
      'meeting_update_email_enabled',
      'meeting_cancel_email_enabled',
      'meeting_self_invite_email_enabled',
    ],
  });
  const map = new Map();
  for (const u of rows) map.set(u.uuid, u);
  return map;
}

const normalizeInviteeKey = (value) => {
  if (value == null) return '';
  return String(value).trim().toLowerCase();
};

const parseInviteesFromRequest = ({ participant_ids, email_invitations, invited_participants }) => {
  const out = [];

  const pushUnique = (v) => {
    const key = normalizeInviteeKey(v);
    if (!key) return;
    if (out.some((x) => normalizeInviteeKey(x) === key)) return;
    out.push(v);
  };

  if (Array.isArray(invited_participants)) {
    invited_participants.forEach(pushUnique);
  }

  if (Array.isArray(participant_ids)) {
    participant_ids.forEach(pushUnique);
  }

  if (Array.isArray(email_invitations)) {
    email_invitations
      .map((e) => String(e).trim())
      .filter((e) => e && isValidEmail(e))
      .forEach((e) => pushUnique(e.toLowerCase()));
  }

  return out;
};

async function buildRsvpIndexForMeetings(meetingIds) {
  if (!Array.isArray(meetingIds) || meetingIds.length === 0) return new Map();
  const rows = await MeetingRsvp.findAll({
    where: { meeting_id: meetingIds },
    attributes: ['meeting_id', 'invitee_user_id', 'invitee_email', 'status'],
  });

  const byMeeting = new Map();
  for (const row of rows) {
    const meetingId = row.meeting_id;
    const key = row.invitee_user_id || row.invitee_email;
    if (!key) continue;
    const normKey = normalizeInviteeKey(key);
    if (!byMeeting.has(meetingId)) byMeeting.set(meetingId, new Map());
    byMeeting.get(meetingId).set(normKey, String(row.status || '').toLowerCase());
  }
  return byMeeting;
}

function attachRsvpSummary(meeting, statusIndex = new Map()) {
  const invited = Array.isArray(meeting.invited_participants) ? meeting.invited_participants : [];
  const summary = { invited: 0, accepted: 0, tentative: 0, declined: 0 };
  const invitedStatuses = {};

  for (const invitee of invited) {
    const key = normalizeInviteeKey(invitee);
    if (!key) continue;
    const status = statusIndex.get(key) || 'invited';
    invitedStatuses[key] = status;

    if (status === 'accepted') summary.accepted += 1;
    else if (status === 'tentative') summary.tentative += 1;
    else if (status === 'declined') summary.declined += 1;
    else summary.invited += 1;
  }

  meeting.rsvp_summary = summary;
  meeting.invited_rsvp_statuses = invitedStatuses;
  return meeting;
}

const isValidEmail = (email) => {
  const emailRegex = /^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/;
  return emailRegex.test(email);
};

const formatICalDateUtc = (date) => {
  return date.toISOString().replace(/[-:]/g, '').split('.')[0] + 'Z';
};

const getBaseUrl = (req) => {
  return config.app?.url || `${req.protocol}://${req.get('host')}`;
};

async function sendExternalInviteEmail({ req, meeting, meetingId, email, inviterUserId, inviterUsername }) {
  if (!email || !isValidEmail(email)) {
    throw new Error('Invalid email format');
  }

  if (!config.smtp?.auth?.user) {
    throw new Error('SMTP is not configured');
  }

  if (meeting?.allow_external !== true) {
    throw new Error('External guests are not enabled for this meeting');
  }

  // Generate invitation link with label for email recipient
  const invitation = await meetingService.generateInvitationLink(meetingId, {
    label: `Email invite: ${email}`,
    created_by: inviterUserId,
  });
  const invitationToken = invitation.token;
  const invitationUrl = `${req.protocol}://${req.get('host')}/#/join/meeting/${invitationToken}`;

  // Ensure invited_participants contains this email for tracking
  const normalizedEmail = String(email).toLowerCase();
  if (Array.isArray(meeting.invited_participants)) {
    const alreadyInvited = meeting.invited_participants
      .map((v) => String(v).toLowerCase())
      .includes(normalizedEmail);
    if (!alreadyInvited) {
      const updatedInvited = [...meeting.invited_participants, normalizedEmail];
      await meetingService.updateMeeting(meetingId, { invited_participants: updatedInvited });
      meeting.invited_participants = updatedInvited;
    }
  }

  // Get server settings for server name
  const settings = await ServerSettings.findOne({ where: { id: 1 } });
  const serverName = settings?.server_name || 'PeerWave Server';

  // Format meeting time
  const startTime = new Date(meeting.start_time);
  const endTime = new Date(meeting.end_time);
  const dateOptions = { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' };
  const timeOptions = { hour: '2-digit', minute: '2-digit', timeZoneName: 'short' };

  // RSVP action URLs (tokenized, 30d expiry, reusable across actions)
  const rsvpToken = createRsvpToken({ meetingId, email: normalizedEmail });
  const baseUrl = getBaseUrl(req);
  const rsvpBase = `${baseUrl}/api/meetings/${meetingId}/rsvp`;
  const rsvpAcceptedUrl = `${rsvpBase}/accepted?email=${encodeURIComponent(normalizedEmail)}&token=${encodeURIComponent(rsvpToken)}`;
  const rsvpTentativeUrl = `${rsvpBase}/tentative?email=${encodeURIComponent(normalizedEmail)}&token=${encodeURIComponent(rsvpToken)}`;
  const rsvpDeclinedUrl = `${rsvpBase}/declined?email=${encodeURIComponent(normalizedEmail)}&token=${encodeURIComponent(rsvpToken)}`;

  // Create iCal event for calendar integration
  const icsContent = `BEGIN:VCALENDAR
PRODID:-//PeerWave//Meeting Invite//EN
VERSION:2.0
CALSCALE:GREGORIAN
METHOD:REQUEST
BEGIN:VEVENT
UID:${meeting.id}@${serverName.replace(/\s/g, '')}
DTSTAMP:${formatICalDateUtc(new Date())}
DTSTART:${formatICalDateUtc(startTime)}
DTEND:${formatICalDateUtc(endTime)}
SUMMARY:${meeting.title}
DESCRIPTION:${meeting.description || 'Join meeting at: ' + invitationUrl}\n\nJoin URL: ${invitationUrl}
ORGANIZER;CN=${inviterUsername}:mailto:${config.smtp.auth.user}
ATTENDEE;CN=${email};ROLE=REQ-PARTICIPANT;RSVP=TRUE:mailto:${email}
LOCATION:${invitationUrl}
STATUS:CONFIRMED
SEQUENCE:0
END:VEVENT
END:VCALENDAR`.trim();

  await emailService.sendEmail({
    smtpConfig: config.smtp,
    message: {
      from: config.smtp.auth.user,
      to: email,
      subject: `${inviterUsername} invited you to "${meeting.title}" on ${serverName}`,
      html: `
          <div style="font-family:'Nunito Sans', system-ui, -apple-system, sans-serif; background-color:#0f1419; padding:40px 16px; color:#d6dde3;">
            <div style="max-width:600px; margin:0 auto; background-color:#141b22; border-radius:12px; padding:32px; box-shadow:0 0 0 1px rgba(0, 188, 212, 0.08);">
              <h2 style="margin-top:0; color:#2dd4bf; font-weight:600; letter-spacing:0.3px;">You're Invited to a Meeting!</h2>
              <p style="color:#cbd5dc; line-height:1.6;"><strong style="color:#ffffff;">${inviterUsername}</strong> has invited you to join a meeting on ${serverName}.</p>
              <div style="margin:24px 0; padding:20px; background-color:#0f1419; border-radius:10px; border:1px solid rgba(45, 212, 191, 0.15);">
                <h3 style="margin-top:0; color:#2dd4bf; font-size:16px;">Meeting Details</h3>
                <p style="margin:0 0 8px 0; color:#cbd5dc;"><strong style="color:#2dd4bf;">Title</strong><br>${meeting.title}</p>
                ${meeting.description ? `<p style="margin:0 0 8px 0; color:#cbd5dc;"><strong style="color:#2dd4bf;">Description</strong><br>${meeting.description}</p>` : ''}
                <p style="margin:0 0 8px 0; color:#cbd5dc;"><strong style="color:#2dd4bf;">Date</strong><br>${startTime.toLocaleDateString('en-US', dateOptions)}</p>
                <p style="margin:0; color:#cbd5dc;"><strong style="color:#2dd4bf;">Time</strong><br>${startTime.toLocaleTimeString('en-US', timeOptions)} – ${endTime.toLocaleTimeString('en-US', timeOptions)}</p>
              </div>
              <div style="margin:28px 0;">
                <a href="${invitationUrl}" style="background-color:#2dd4bf; color:#062726; padding:14px 22px; text-decoration:none; border-radius:8px; font-weight:600; display:inline-block;">Join Meeting</a>
              </div>
              <div style="margin:32px 0;">
                <p style="margin:0 0 12px 0; color:#9fb3bf;"><strong>RSVP</strong></p>
                <a href="${rsvpAcceptedUrl}" style="background-color:#1f8f78; color:#e6fffa; padding:10px 16px; text-decoration:none; border-radius:6px; display:inline-block; margin-right:8px; font-weight:500;">Accept</a>
                <a href="${rsvpTentativeUrl}" style="background-color:#3b3f46; color:#e5e7eb; padding:10px 16px; text-decoration:none; border-radius:6px; display:inline-block; margin-right:8px; font-weight:500;">Tentative</a>
                <a href="${rsvpDeclinedUrl}" style="background-color:#7f1d1d; color:#fee2e2; padding:10px 16px; text-decoration:none; border-radius:6px; display:inline-block; font-weight:500;">Decline</a>
                <p style="margin-top:12px; font-size:12px; color:#7b8a94;">These links expire in 30 days.</p>
              </div>
              <div style="margin:24px 0; padding:16px; background-color:#0f1419; border-radius:8px; border:1px solid rgba(255,255,255,0.06);">
                <p style="margin:0 0 8px 0; color:#9fb3bf; font-size:13px;">Or copy and paste this link:</p>
                <a href="${invitationUrl}" style="color:#2dd4bf; word-break:break-all; font-size:13px;">${invitationUrl}</a>
              </div>
              <hr style="border:none; border-top:1px solid rgba(255,255,255,0.06); margin:32px 0;">
              <p style="font-size:12px; color:#6b7c86; margin:0;">This invitation was sent from ${serverName}. If you received this email in error, please ignore it.<br><a href="https://peerwave.org" style="text-decoration: none; display: flex; align-items: center;"><img src="https://peerwave.org/logo_28.png" style="width:24px;height:24px;padding-right: 0.25rem;"/><span style="color:white;">PeerWave</span><span style="color:#4fbfb3;"> - Private communication you fully control.</span></a></p>
            </div>
          </div>
        `,
      alternatives: [
        {
          contentType: 'text/calendar; method=REQUEST; charset=UTF-8',
          content: icsContent,
        },
      ],
      attachments: [
        {
          filename: 'invite.ics',
          content: icsContent,
          contentType: 'text/calendar; charset=UTF-8; method=REQUEST',
        },
      ],
    },
  });

  return { invitationToken, invitationUrl };
}

async function upsertRsvpForUser(meetingId, userId, status) {
  const now = new Date();
  await writeQueue.enqueue(async () => {
    const existing = await MeetingRsvp.findOne({
      where: { meeting_id: meetingId, invitee_user_id: userId },
    });
    if (existing) {
      await existing.update({ status, responded_at: now });
      return;
    }
    await MeetingRsvp.create({
      meeting_id: meetingId,
      invitee_user_id: userId,
      status,
      responded_at: now,
    });
  });
}

async function upsertRsvpForEmail(meetingId, email, status) {
  const now = new Date();
  const normalizedEmail = String(email).toLowerCase();
  await writeQueue.enqueue(async () => {
    const existing = await MeetingRsvp.findOne({
      where: { meeting_id: meetingId, invitee_email: normalizedEmail },
    });
    if (existing) {
      await existing.update({ status, responded_at: now });
      return;
    }
    await MeetingRsvp.create({
      meeting_id: meetingId,
      invitee_email: normalizedEmail,
      status,
      responded_at: now,
    });
  });
}

async function removeFromInvitedParticipants(meeting, meetingId, valueToRemove) {
  if (!Array.isArray(meeting.invited_participants)) return;
  const needle = String(valueToRemove).toLowerCase();
  const updated = meeting.invited_participants.filter((v) => {
    return String(v).toLowerCase() !== needle;
  });
  if (updated.length === meeting.invited_participants.length) return;
  await meetingService.updateMeeting(meetingId, { invited_participants: updated });
}

async function maybeEmailOrganizerOnRsvp({ meeting, responderLabel, status }) {
  try {
    const organizer = await User.findByPk(meeting.created_by);
    if (!organizer?.email) return;
    if (organizer.meeting_rsvp_email_to_organizer_enabled !== true) return;

    const settings = await ServerSettings.findOne({ where: { id: 1 } });
    const serverName = settings?.server_name || 'PeerWave Server';

    await emailService.sendEmail({
      smtpConfig: config.smtp,
      message: {
        from: config.smtp.auth.user,
        to: organizer.email,
        subject: `RSVP: ${responderLabel} responded ${status} to "${meeting.title}"`,
        html: `
          <div style="font-family:'Nunito Sans', system-ui, -apple-system, sans-serif; background-color:#0f1419; padding:40px 16px; color:#d6dde3;">
            <div style="max-width:600px; margin:0 auto; background-color:#141b22; border-radius:12px; padding:32px; box-shadow:0 0 0 1px rgba(0, 188, 212, 0.08);">
              <h2 style="margin-top:0; color:#2dd4bf; font-weight:600; letter-spacing:0.3px;">Meeting RSVP Updated</h2>
              <p style="color:#cbd5dc; line-height:1.6;"><strong style="color:#ffffff;">${responderLabel}</strong> responded: <strong style="color:#2dd4bf;">${status}</strong></p>
              <div style="margin:24px 0; padding:16px; background-color:#0f1419; border-radius:8px; border:1px solid rgba(45, 212, 191, 0.15);">
                <p style="margin:0; color:#cbd5dc;"><strong style="color:#2dd4bf;">Meeting</strong><br>${meeting.title}</p>
              </div>
              <hr style="border:none; border-top:1px solid rgba(255,255,255,0.06); margin:32px 0;">
              <p style="font-size:12px; color:#6b7c86; margin:0;">Sent from ${serverName}<br><a href="https://peerwave.org" style="text-decoration: none; display: flex; align-items: center;"><img src="https://peerwave.org/logo_28.png" style="width:24px;height:24px;padding-right: 0.25rem;"/><span style="color:white;">PeerWave</span><span style="color:#4fbfb3;"> - Private communication you fully control.</span></a></p>
            </div>
          </div>
        `,
      },
    });
  } catch (e) {
    console.warn('[MEETING_RSVP] Failed to email organizer:', e?.message || e);
  }
}

async function maybeSendAttendeeCancelEmail({ meeting, attendeeEmail, username, serverName }) {
  try {
    if (!config.smtp?.auth?.user) return;

    const startTime = new Date(meeting.start_time);
    const endTime = new Date(meeting.end_time);
    const baseUrl = config.app?.url || '';

    const uidDomain = String(serverName || 'PeerWave').replace(/\s/g, '');
    const uid = `${meeting.id}@${uidDomain}`;

    const icsCancelContent = `BEGIN:VCALENDAR
PRODID:-//PeerWave//Meeting RSVP//EN
VERSION:2.0
CALSCALE:GREGORIAN
METHOD:CANCEL
BEGIN:VEVENT
UID:${uid}
DTSTAMP:${formatICalDateUtc(new Date())}
DTSTART:${formatICalDateUtc(startTime)}
DTEND:${formatICalDateUtc(endTime)}
SUMMARY:${meeting.title}
DESCRIPTION:${meeting.description || ''}
ORGANIZER;CN=${username}:mailto:${config.smtp.auth.user}
ATTENDEE;CN=${attendeeEmail};ROLE=REQ-PARTICIPANT:mailto:${attendeeEmail}
STATUS:CANCELLED
SEQUENCE:1
END:VEVENT
END:VCALENDAR`.trim();

    await emailService.sendEmail({
      smtpConfig: config.smtp,
      message: {
        from: config.smtp.auth.user,
        to: attendeeEmail,
        subject: `Cancelled (per your decline): "${meeting.title}"`,
        html: `
          <div style="font-family:'Nunito Sans', system-ui, -apple-system, sans-serif; background-color:#0f1419; padding:40px 16px; color:#d6dde3;">
            <div style="max-width:600px; margin:0 auto; background-color:#141b22; border-radius:12px; padding:32px; box-shadow:0 0 0 1px rgba(0, 188, 212, 0.08);">
              <h2 style="margin-top:0; color:#f59e0b; font-weight:600; letter-spacing:0.3px;">Meeting Removed From Your Calendar</h2>
              <p style="color:#cbd5dc; line-height:1.6;">You declined <strong style="color:#ffffff;">${meeting.title}</strong>. This email updates your calendar entry.</p>
              ${baseUrl ? `<div style="margin:24px 0; padding:16px; background-color:#0f1419; border-radius:8px; border:1px solid rgba(255,255,255,0.06);"><p style="margin:0; color:#9fb3bf; font-size:13px;">PeerWave: <a href="${baseUrl}" style="color:#2dd4bf;">${baseUrl}</a></p></div>` : ''}
              <hr style="border:none; border-top:1px solid rgba(255,255,255,0.06); margin:32px 0;">
              <p style="font-size:12px; color:#6b7c86; margin:0;">Sent from ${serverName}<br><a href="https://peerwave.org" style="text-decoration: none; display: flex; align-items: center;"><img src="https://peerwave.org/logo_28.png" style="width:24px;height:24px;padding-right: 0.25rem;"/><span style="color:white;">PeerWave</span><span style="color:#4fbfb3;"> - Private communication you fully control.</span></a></p>
            </div>
          </div>
        `,
        alternatives: [
          {
            contentType: 'text/calendar; method=CANCEL; charset=UTF-8',
            content: icsCancelContent,
          },
        ],
        attachments: [
          {
            filename: 'cancel.ics',
            content: icsCancelContent,
            contentType: 'text/calendar; charset=UTF-8; method=CANCEL',
          },
        ],
      },
    });
  } catch (e) {
    console.warn('[MEETING_RSVP] Failed to send attendee CANCEL email:', e?.message || e);
  }
}

/**
 * Create a new meeting
 * POST /api/meetings
 */
router.post('/meetings', verifyAuthEither, async (req, res) => {
  try {
    const {
      title,
      description,
      start_time,
      end_time,
      allow_external,
      voice_only,
      mute_on_join,
      max_participants,
      participant_ids,
      email_invitations,
      invited_participants
    } = req.body;

    const created_by = req.userId;

    // If we were asked to email external guests, ensure the meeting allows it.
    if (Array.isArray(email_invitations) && email_invitations.length > 0 && allow_external !== true) {
      return res.status(400).json({ error: 'External guests are not enabled for this meeting' });
    }

    // Validation
    if (!title || !start_time || !end_time) {
      return res.status(400).json({ error: 'Missing required fields: title, start_time, end_time' });
    }

    const meeting = await meetingService.createMeeting({
      title,
      description,
      created_by,
      start_time: new Date(start_time),
      end_time: new Date(end_time),
      is_instant_call: false,
      allow_external: allow_external || false,
      voice_only: voice_only || false,
      mute_on_join: mute_on_join || false,
      max_participants: max_participants || null,
      invited_participants: parseInviteesFromRequest({ participant_ids, email_invitations, invited_participants }),
    });

    const inviterUsername = req.username || req.session?.userinfo?.username || 'A user';
    const serverName = await loadServerName();

    // Send invite emails to internal users (respecting their settings)
    const invitees = Array.isArray(meeting.invited_participants) ? meeting.invited_participants : [];
    const internalUserIds = invitees.filter((v) => v && !isEmailLike(v));
    const usersById = await resolveUsersForIds(internalUserIds);

    // Optional: organizer can receive an invite mail for their own meetings
    const organizer = await User.findByPk(created_by, {
      attributes: ['uuid', 'email', 'meeting_self_invite_email_enabled', 'meeting_invite_email_enabled'],
    });
    const shouldEmailOrganizerSelfInvite = organizer?.meeting_self_invite_email_enabled === true;

    for (const userId of internalUserIds) {
      if (!userId) continue;
      if (userId === created_by && !shouldEmailOrganizerSelfInvite) continue;
      const user = usersById.get(userId);
      if (!user) continue;
      try {
        await sendInternalInviteEmail({
          req,
          meeting,
          meetingId: meeting.meeting_id,
          user,
          inviterUsername,
          serverName,
        });
      } catch (e) {
        console.warn('[MEETING_CREATE] Failed to send internal invite email:', userId, e?.message || e);
      }
    }

    // Auto-send external email invitations if provided (best-effort).
    if (Array.isArray(email_invitations) && email_invitations.length > 0) {
      for (const rawEmail of email_invitations) {
        const email = String(rawEmail || '').trim();
        if (!email) continue;
        try {
          await sendExternalInviteEmail({
            req,
            meeting,
            meetingId: meeting.meeting_id,
            email,
            inviterUserId: created_by,
            inviterUsername,
          });
        } catch (e) {
          console.warn('[MEETING_CREATE] Failed to send external invite email:', email, e?.message || e);
        }
      }
    }

    res.status(201).json(meeting);
  } catch (error) {
    console.error('Error creating meeting:', error);
    res.status(500).json({ error: 'Failed to create meeting' });
  }
});

/**
 * List meetings with filters
 * GET /api/meetings?filter=upcoming|past|my&user_id=xxx
 */
router.get('/meetings', verifyAuthEither, async (req, res) => {
  try {
    const { filter, user_id } = req.query;
    const currentUserId = req.userId;

    let filters = {};

    // Default to showing meetings for current user
    if (filter === 'my' || !filter) {
      filters.user_id = currentUserId;
    } else if (filter === 'upcoming') {
      filters.start_after = new Date();
      filters.status = 'scheduled';
      filters.user_id = currentUserId;
    } else if (filter === 'past') {
      const eightHoursAgo = new Date(Date.now() - 8 * 60 * 60 * 1000);
      filters.end_before = new Date();
      filters.start_after = eightHoursAgo;
      filters.user_id = currentUserId;
    }

    // Allow admins to view all meetings or filter by user
    const isAdmin = await hasServerPermission(currentUserId, 'server.manage');
    if (isAdmin && user_id) {
      filters.user_id = user_id;
    }

    const meetings = await meetingService.listMeetings(filters);

    const meetingIds = meetings.map((m) => m.meeting_id).filter(Boolean);
    const rsvpByMeeting = await buildRsvpIndexForMeetings(meetingIds);

    const withSummaries = meetings.map((m) => {
      const idx = rsvpByMeeting.get(m.meeting_id) || new Map();
      return attachRsvpSummary(m, idx);
    });

    res.json(withSummaries);
  } catch (error) {
    console.error('Error listing meetings:', error);
    res.status(500).json({ error: 'Failed to list meetings' });
  }
});

/**
 * Get upcoming meetings (starting within 24 hours)
 * GET /api/meetings/upcoming
 */
router.get('/meetings/upcoming', verifyAuthEither, async (req, res) => {
  try {
    const userId = req.userId;
    const now = new Date();
    const tomorrow = new Date(now.getTime() + 24 * 60 * 60 * 1000);

    const meetings = await meetingService.listMeetings({
      user_id: userId,
      start_after: now,
      end_before: tomorrow,
      status: 'scheduled'
    });

    res.json(meetings);
  } catch (error) {
    console.error('Error getting upcoming meetings:', error);
    res.status(500).json({ error: 'Failed to get upcoming meetings' });
  }
});

/**
 * Get past meetings (ended within 8 hours)
 * GET /api/meetings/past
 */
router.get('/meetings/past', verifyAuthEither, async (req, res) => {
  try {
    const userId = req.userId;
    const now = new Date();
    const eightHoursAgo = new Date(now.getTime() - 8 * 60 * 60 * 1000);

    const meetings = await meetingService.listMeetings({
      user_id: userId,
      start_after: eightHoursAgo,
      end_before: now
    });

    res.json(meetings);
  } catch (error) {
    console.error('Error getting past meetings:', error);
    res.status(500).json({ error: 'Failed to get past meetings' });
  }
});

/**
 * Get user's meetings (created or invited)
 * GET /api/meetings/my
 */
router.get('/meetings/my', verifyAuthEither, async (req, res) => {
  try {
    const userId = req.userId;

    const meetings = await meetingService.listMeetings({
      user_id: userId
    });

    res.json(meetings);
  } catch (error) {
    console.error('Error getting my meetings:', error);
    res.status(500).json({ error: 'Failed to get meetings' });
  }
});

/**
 * Get specific meeting
 * GET /api/meetings/:meetingId
 */
router.get('/meetings/:meetingId', verifyAuthEither, async (req, res) => {
  try {
    const { meetingId } = req.params;
    const userId = req.userId;
    
    const meeting = await meetingService.getMeeting(meetingId);

    if (!meeting) {
      return res.status(404).json({ error: 'Meeting not found' });
    }

    // Check if user is authorized to view this meeting
    // User must be: owner, participant, invited, or source user (for instant calls)
    const isParticipant = meeting.participants.some(p => p.user_id === userId);
    const isSourceUser = meeting.source_user_id === userId;
    const isCreator = meeting.created_by === userId;
    // invited_participants is an array of strings (user IDs or emails)
    const isInvited = Array.isArray(meeting.invited_participants) 
      && meeting.invited_participants.includes(userId);
    
    if (!isParticipant && !isSourceUser && !isCreator && !isInvited) {
      console.log(`[MEETING] User ${userId} not authorized for meeting ${meetingId}`);
      return res.status(403).json({ error: 'Not authorized to access this meeting' });
    }

    const rsvpByMeeting = await buildRsvpIndexForMeetings([meetingId]);
    const idx = rsvpByMeeting.get(meetingId) || new Map();
    res.json(attachRsvpSummary(meeting, idx));
  } catch (error) {
    console.error('Error getting meeting:', error);
    res.status(500).json({ error: 'Failed to get meeting' });
  }
});

/**
 * Update meeting
 * PATCH /api/meetings/:meetingId
 */
router.patch('/meetings/:meetingId', verifyAuthEither, async (req, res) => {
  try {
    const { meetingId } = req.params;
    const userId = req.userId;

    const meeting = await meetingService.getMeeting(meetingId);
    if (!meeting) {
      return res.status(404).json({ error: 'Meeting not found' });
    }

    // Check if user is owner, manager, or admin.
    // Note: scheduled meetings can be loaded from DB with an empty runtime participants list.
    const isOwner = meeting.created_by === userId;
    const participant = meeting.participants?.find(p => p.user_id === userId);
    const isManager = participant?.role === 'meeting_manager' || participant?.role === 'meeting_owner';
    const isAdmin = await hasServerPermission(userId, 'server.manage');

    if (!isOwner && !isManager && !isAdmin) {
      return res.status(403).json({ error: 'Only owner or manager can update meeting' });
    }

    const before = meeting;
    const beforeInvited = Array.isArray(before.invited_participants) ? before.invited_participants : [];

    // Normalize invitee fields if client sent participant_ids/email_invitations.
    const updatePayload = { ...req.body };
    if (
      updatePayload.participant_ids !== undefined ||
      updatePayload.email_invitations !== undefined ||
      updatePayload.invited_participants !== undefined
    ) {
      const allowExternalNext = updatePayload.allow_external ?? before.allow_external;
      const hasExternal = Array.isArray(updatePayload.email_invitations) && updatePayload.email_invitations.length > 0;
      if (hasExternal && allowExternalNext !== true) {
        return res.status(400).json({ error: 'External guests are not enabled for this meeting' });
      }
      updatePayload.invited_participants = parseInviteesFromRequest({
        participant_ids: updatePayload.participant_ids,
        email_invitations: updatePayload.email_invitations,
        invited_participants: updatePayload.invited_participants,
      });
      delete updatePayload.participant_ids;
      delete updatePayload.email_invitations;
    }

    const updated = await meetingService.updateMeeting(meetingId, updatePayload);

    const inviterUsername = req.username || req.session?.userinfo?.username || 'A user';
    const serverName = await loadServerName();

    const afterInvited = Array.isArray(updated.invited_participants) ? updated.invited_participants : [];
    const { added, removed } = diffInvitees(beforeInvited, afterInvited);

    // Send invite emails for newly added invitees
    if (added.length > 0) {
      const addedInternal = added.filter((v) => v && !isEmailLike(v));
      const usersById = await resolveUsersForIds(addedInternal);
      for (const userIdToInvite of addedInternal) {
        const u = usersById.get(userIdToInvite);
        if (!u) continue;
        try {
          // Respect organizer self-invite setting
          if (userIdToInvite === updated.created_by && u.meeting_self_invite_email_enabled !== true) continue;
          await sendInternalInviteEmail({
            req,
            meeting: updated,
            meetingId,
            user: u,
            inviterUsername,
            serverName,
          });
        } catch (e) {
          console.warn('[MEETING_UPDATE] Failed to send internal invite email:', userIdToInvite, e?.message || e);
        }
      }

      const addedExternal = added.filter((v) => isEmailLike(v));
      if (addedExternal.length > 0 && updated.allow_external === true) {
        for (const email of addedExternal) {
          try {
            await sendExternalInviteEmail({
              req,
              meeting: updated,
              meetingId,
              email,
              inviterUserId: updated.created_by,
              inviterUsername,
            });
          } catch (e) {
            console.warn('[MEETING_UPDATE] Failed to send external invite email:', email, e?.message || e);
          }
        }
      }
    }

    // Send cancel emails for removed invitees
    if (removed.length > 0) {
      const removedInternal = removed.filter((v) => v && !isEmailLike(v));
      const usersById = await resolveUsersForIds(removedInternal);
      for (const removedUserId of removedInternal) {
        const u = usersById.get(removedUserId);
        if (!u?.email) continue;
        if (u.meeting_cancel_email_enabled !== true) continue;
        try {
          await sendMeetingCancelEmail({
            meeting: before,
            meetingId,
            attendeeEmail: u.email,
            organizerLabel: inviterUsername,
            serverName,
          });
        } catch (e) {
          console.warn('[MEETING_UPDATE] Failed to send internal cancel email:', removedUserId, e?.message || e);
        }
      }

      const removedExternal = removed.filter((v) => isEmailLike(v));
      for (const email of removedExternal) {
        try {
          await sendMeetingCancelEmail({
            meeting: before,
            meetingId,
            attendeeEmail: String(email),
            organizerLabel: inviterUsername,
            serverName,
          });
        } catch (e) {
          console.warn('[MEETING_UPDATE] Failed to send external cancel email:', email, e?.message || e);
        }
      }
    }

    // Send update emails if schedule/details changed
    const scheduleChanged =
      (updatePayload.start_time && String(updatePayload.start_time) !== String(before.start_time)) ||
      (updatePayload.end_time && String(updatePayload.end_time) !== String(before.end_time)) ||
      (updatePayload.title && String(updatePayload.title) !== String(before.title)) ||
      (updatePayload.description !== undefined && String(updatePayload.description || '') !== String(before.description || ''));

    if (scheduleChanged) {
      const rsvpByMeeting = await buildRsvpIndexForMeetings([meetingId]);
      const idx = rsvpByMeeting.get(meetingId) || new Map();

      const recipients = afterInvited;
      const internalIds = recipients.filter((v) => v && !isEmailLike(v));
      const usersById = await resolveUsersForIds(internalIds);
      for (const recipientId of internalIds) {
        const u = usersById.get(recipientId);
        if (!u?.email) continue;
        if (u.meeting_update_email_enabled !== true) continue;
        const status = idx.get(normalizeInviteeKey(recipientId)) || 'invited';
        if (status === 'declined') continue;
        if (recipientId === updated.created_by && u.meeting_self_invite_email_enabled !== true) continue;
        try {
          await sendMeetingUpdateEmail({
            req,
            meeting: updated,
            meetingId,
            recipientEmail: u.email,
            recipientLabel: u.displayName || u.atName || u.email,
            inviterUsername,
            serverName,
            isInternalUser: true,
          });
        } catch (e) {
          console.warn('[MEETING_UPDATE] Failed to send internal update email:', recipientId, e?.message || e);
        }
      }

      const externalEmails = recipients.filter((v) => isEmailLike(v));
      for (const email of externalEmails) {
        const status = idx.get(normalizeInviteeKey(email)) || 'invited';
        if (status === 'declined') continue;
        try {
          await sendMeetingUpdateEmail({
            req,
            meeting: updated,
            meetingId,
            recipientEmail: String(email),
            recipientLabel: String(email),
            inviterUsername,
            serverName,
            isInternalUser: false,
          });
        } catch (e) {
          console.warn('[MEETING_UPDATE] Failed to send external update email:', email, e?.message || e);
        }
      }
    }

    res.json(updated);
  } catch (error) {
    console.error('Error updating meeting:', error);
    res.status(500).json({ error: 'Failed to update meeting' });
  }
});

/**
 * RSVP to a meeting (authenticated)
 * PATCH /api/meetings/:meetingId/rsvp
 * Body: { status: 'accepted' | 'tentative' | 'declined' }
 */
router.patch('/meetings/:meetingId/rsvp', verifyAuthEither, async (req, res) => {
  try {
    const { meetingId } = req.params;
    const userId = req.userId;
    const status = String(req.body?.status || '').toLowerCase();

    if (!RSVP_STATUSES.has(status)) {
      return res.status(400).json({ error: 'Invalid status' });
    }

    const meeting = await meetingService.getMeeting(meetingId);
    if (!meeting) {
      return res.status(404).json({ error: 'Meeting not found' });
    }

    const isInvited = meeting.invited_participants?.includes(userId);
    const isParticipant = meeting.participants?.some(p => p.user_id === userId);
    const isCreator = meeting.created_by === userId;

    if (!isInvited && !isParticipant && !isCreator) {
      return res.status(403).json({ error: 'Not authorized to RSVP' });
    }

    await upsertRsvpForUser(meetingId, userId, status);

    const responderUser = await User.findByPk(userId);
    const responderLabel = responderUser?.displayName || responderUser?.atName || responderUser?.email || req.username || 'A user';
    await maybeEmailOrganizerOnRsvp({ meeting, responderLabel, status });

    res.json({ success: true, meetingId, status });
  } catch (error) {
    console.error('[MEETING_RSVP] Error (auth):', error);
    res.status(500).json({ error: 'Failed to RSVP' });
  }
});

/**
 * RSVP to a meeting (unauthenticated, email action buttons)
 * GET /api/meetings/:meetingId/rsvp/:status?email=...&token=...&format=json
 */
router.get('/meetings/:meetingId/rsvp/:status', async (req, res) => {
  try {
    const { meetingId, status: statusRaw } = req.params;
    const status = String(statusRaw || '').toLowerCase();
    const email = String(req.query.email || '').trim();
    const token = String(req.query.token || '').trim();
    const format = String(req.query.format || '').toLowerCase();

    if (!RSVP_STATUSES.has(status)) {
      return res.status(400).send('Invalid RSVP status');
    }

    if (!email || !isValidEmail(email)) {
      return res.status(400).send('Invalid email');
    }

    const meeting = await meetingService.getMeeting(meetingId);
    if (!meeting) {
      return res.status(404).send('Meeting not found');
    }

    const verification = verifyRsvpToken({ token, meetingId, email });
    if (!verification.valid) {
      if (format === 'json' || req.accepts('json')) {
        return res.status(403).json({ success: false, error: verification.error });
      }
      return res.status(403).send('Invalid or expired token');
    }

    await upsertRsvpForEmail(meetingId, email, status);

    const settings = await ServerSettings.findOne({ where: { id: 1 } });
    const serverName = settings?.server_name || 'PeerWave Server';
    const username = req.username || req.session?.userinfo?.username || 'A user';

    // Optional: attendee-only CANCEL email on decline (calendar cleanup)
    if (status === 'declined') {
      await maybeSendAttendeeCancelEmail({
        meeting,
        attendeeEmail: email,
        username,
        serverName,
      });
    }

    // Optional: email organizer on RSVP if enabled
    await maybeEmailOrganizerOnRsvp({ meeting, responderLabel: email, status });

    if (format === 'json' || req.accepts('json')) {
      return res.json({
        success: true,
        meetingId,
        status,
        meetingTitle: meeting.title,
        startTime: meeting.start_time,
        endTime: meeting.end_time,
      });
    }

    const baseUrl = getBaseUrl(req);
    const openAppUrl = `${baseUrl}/#/meeting/rsvp?meetingId=${encodeURIComponent(meetingId)}&status=${encodeURIComponent(status)}&email=${encodeURIComponent(email)}&token=${encodeURIComponent(token)}`;

    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    res.send(`<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>RSVP Confirmation</title>
</head>
<body style="font-family:'Nunito Sans', system-ui, -apple-system, sans-serif; background:#0f1419; padding:40px 16px; margin:0;">
  <div style="max-width:600px; margin:0 auto; background-color:#141b22; border-radius:12px; padding:32px; box-shadow:0 0 0 1px rgba(0, 188, 212, 0.08);">
    <h2 style="margin-top:0; color:#2dd4bf; font-weight:600; letter-spacing:0.3px;">RSVP Confirmed</h2>
    <p style="color:#cbd5dc; line-height:1.6;">You responded: <strong style="color:#2dd4bf;">${status}</strong></p>
    <div style="margin:24px 0; padding:20px; background-color:#0f1419; border-radius:10px; border:1px solid rgba(45, 212, 191, 0.15);">
      <p style="margin:0 0 8px 0; color:#cbd5dc;"><strong style="color:#2dd4bf;">Meeting</strong><br>${meeting.title}</p>
      <p style="margin:0; color:#9fb3bf; font-size:14px;">${serverName}</p>
    </div>
    <div style="margin:28px 0;">
      <a href="${openAppUrl}" style="display:inline-block; padding:14px 22px; background-color:#2dd4bf; color:#062726; text-decoration:none; border-radius:8px; font-weight:600;">Open PeerWave</a>
    </div>
    <p style="margin-top:24px; color:#7b8a94; font-size:12px;">This page does not require login.</p>
    <hr style="border:none; border-top:1px solid rgba(255,255,255,0.06); margin:32px 0;">
    <p style="font-size:12px; color:#6b7c86; margin:0;"><a href="https://peerwave.org" style="text-decoration: none; display: flex; align-items: center;"><img src="https://peerwave.org/logo_28.png" style="width:24px;height:24px;padding-right: 0.25rem;"/><span style="color:white;">PeerWave</span><span style="color:#4fbfb3;"> - Private communication you fully control.</span></a></p>
  </div>
</body>
</html>`);
  } catch (error) {
    console.error('[MEETING_RSVP] Error (unauth):', error);
    res.status(500).send('Failed to record RSVP');
  }
});

/**
 * Delete meeting
 * DELETE /api/meetings/:meetingId
 */
router.delete('/meetings/:meetingId', verifyAuthEither, async (req, res) => {
  try {
    const { meetingId } = req.params;
    const userId = req.userId;

    const meeting = await meetingService.getMeeting(meetingId);
    if (!meeting) {
      return res.status(404).json({ error: 'Meeting not found' });
    }

    // Check if user is owner
    if (meeting.created_by !== userId) {
      const isAdmin = await hasServerPermission(userId, 'server.manage');
      if (!isAdmin) {
        return res.status(403).json({ error: 'Only owner can delete meeting' });
      }
    }

    // Best-effort: email cancellations to invitees (respecting settings)
    try {
      const inviterUsername = req.username || req.session?.userinfo?.username || 'A user';
      const serverName = await loadServerName();

      const invitees = Array.isArray(meeting.invited_participants) ? meeting.invited_participants : [];
      const internalIds = invitees.filter((v) => v && !isEmailLike(v));
      const usersById = await resolveUsersForIds(internalIds);
      for (const id of internalIds) {
        const u = usersById.get(id);
        if (!u?.email) continue;
        if (u.meeting_cancel_email_enabled !== true) continue;
        if (id === meeting.created_by && u.meeting_self_invite_email_enabled !== true) continue;
        await sendMeetingCancelEmail({
          meeting,
          meetingId,
          attendeeEmail: u.email,
          organizerLabel: inviterUsername,
          serverName,
        });
      }

      const externalEmails = invitees.filter((v) => isEmailLike(v));
      for (const email of externalEmails) {
        await sendMeetingCancelEmail({
          meeting,
          meetingId,
          attendeeEmail: String(email),
          organizerLabel: inviterUsername,
          serverName,
        });
      }
    } catch (e) {
      console.warn('[MEETING_DELETE] Failed to send cancellation emails:', e?.message || e);
    }

    await meetingService.deleteMeeting(meetingId);
    res.json({ success: true });
  } catch (error) {
    console.error('Error deleting meeting:', error);
    res.status(500).json({ error: 'Failed to delete meeting' });
  }
});

/**
 * Bulk delete meetings
 * DELETE /api/meetings/bulk
 */
router.delete('/meetings/bulk', verifyAuthEither, async (req, res) => {
  try {
    const { meetingIds } = req.body;
    const userId = req.userId;

    if (!Array.isArray(meetingIds) || meetingIds.length === 0) {
      return res.status(400).json({ error: 'meetingIds array required' });
    }

    const isAdmin = await hasServerPermission(userId, 'server.manage');
    const results = await meetingService.bulkDeleteMeetings(meetingIds, userId, isAdmin);

    res.json(results);
  } catch (error) {
    console.error('Error bulk deleting meetings:', error);
    res.status(500).json({ error: 'Failed to bulk delete meetings' });
  }
});

/**
 * Get meeting participants (from memory for E2EE key exchange)
 * GET /api/meetings/:meetingId/participants
 * Note: Also supports unauthenticated access for external guests to check if host is present
 */
router.get('/meetings/:meetingId/participants', async (req, res) => {
  try {
    const { meetingId } = req.params;
    const { status, exclude_external } = req.query;

    // Try to extract userId from session/auth, but don't fail if missing (guest access)
    let currentUserId = req.userId || req.session?.userinfo?.uuid;

    const meeting = await meetingService.getMeeting(meetingId);
    if (!meeting) {
      return res.status(404).json({ error: 'Meeting not found' });
    }

    // If authenticated, check authorization
    if (currentUserId) {
      const isAuthorized = meeting.created_by === currentUserId ||
                          meeting.participants?.some(p => p.user_id === currentUserId) ||
                          meeting.invited_participants?.includes(currentUserId);

      if (!isAuthorized) {
        return res.status(403).json({ error: 'Not authorized to view participants' });
      }
    }
    // For unauthenticated (guest) access, allow read-only access to participant list

    // Filter participants based on query parameters
    let participants = (meeting.participants || []).map(p => ({
      uuid: p.user_id,
      deviceId: p.device_id || null,
      role: p.role || 'meeting_member',
      joined_at: p.joined_at,
      status: p.status || 'invited'
    }));

    // Filter by status if provided
    if (status) {
      participants = participants.filter(p => p.status === status);
    }

    // Exclude external participants if requested
    if (exclude_external === 'true') {
      // External participants don't have UUIDs (they have session_ids instead)
      // So this filter keeps only server users
      participants = participants.filter(p => p.uuid && p.uuid.length > 0);
    }

    res.json({ participants });
  } catch (error) {
    console.error('Error getting meeting participants:', error);
    res.status(500).json({ error: 'Failed to get participants' });
  }
});

/**
 * Add participant to meeting
 * POST /api/meetings/:meetingId/participants
 */
router.post('/meetings/:meetingId/participants', verifyAuthEither, async (req, res) => {
  try {
    const { meetingId } = req.params;
    const { user_id, role } = req.body;
    const currentUserId = req.userId;

    if (!user_id) {
      return res.status(400).json({ error: 'user_id is required' });
    }

    const meeting = await meetingService.getMeeting(meetingId);
    if (!meeting) {
      return res.status(404).json({ error: 'Meeting not found' });
    }

    // Check permissions (must be owner or manager)
    const isOwner = meeting.created_by === currentUserId;
    const currentParticipant = meeting.participants?.find(p => p.user_id === currentUserId);
    const isManager = currentParticipant?.role === 'meeting_manager';

    if (!isOwner && !isManager) {
      return res.status(403).json({ error: 'Only owner or manager can add participants' });
    }

    // Add participant
    const participant = await meetingService.addParticipant(meetingId, {
      user_id,
      role: role || 'meeting_member'
    });

    // Get user online status for notification
    const isOnline = await presenceService.isOnline(user_id);

    res.status(201).json({
      participant,
      isOnline
    });
  } catch (error) {
    console.error('Error adding participant:', error);
    res.status(500).json({ error: 'Failed to add participant: ' + error.message });
  }
});

/**
 * Remove participant from meeting
 * DELETE /api/meetings/:meetingId/participants/:userId
 */
router.delete('/meetings/:meetingId/participants/:userId', verifyAuthEither, async (req, res) => {
  try {
    const { meetingId, userId } = req.params;
    const currentUserId = req.userId;

    const meeting = await meetingService.getMeeting(meetingId);
    if (!meeting) {
      return res.status(404).json({ error: 'Meeting not found' });
    }

    // Check permissions (must be owner, manager, or removing self)
    const isOwner = meeting.created_by === currentUserId;
    const currentParticipant = meeting.participants?.find(p => p.user_id === currentUserId);
    const isManager = currentParticipant?.role === 'meeting_manager';
    const isSelf = userId === currentUserId;

    if (!isOwner && !isManager && !isSelf) {
      return res.status(403).json({ error: 'Not authorized to remove participant' });
    }

    // Best-effort: send cancellation email to removed user if enabled.
    try {
      const removedUser = await User.findByPk(userId, {
        attributes: ['uuid', 'email', 'meeting_cancel_email_enabled'],
      });
      if (removedUser?.email && removedUser.meeting_cancel_email_enabled === true) {
        const inviterUsername = req.username || req.session?.userinfo?.username || 'A user';
        const serverName = await loadServerName();
        await sendMeetingCancelEmail({
          meeting,
          meetingId,
          attendeeEmail: removedUser.email,
          organizerLabel: inviterUsername,
          serverName,
        });
      }
    } catch (e) {
      console.warn('[MEETING_PARTICIPANT_REMOVE] Failed to send cancel email:', e?.message || e);
    }

    await meetingService.removeParticipant(meetingId, userId);
    await removeFromInvitedParticipants(meeting, meetingId, userId);

    res.json({ status: 'ok', message: 'Participant removed' });
  } catch (error) {
    console.error('Error removing participant:', error);
    res.status(500).json({ error: 'Failed to remove participant' });
  }
});

/**
 * Update participant status
 * PATCH /api/meetings/:meetingId/participants/:userId
 */
router.patch('/meetings/:meetingId/participants/:userId', verifyAuthEither, async (req, res) => {
  try {
    const { meetingId, userId } = req.params;
    const { status } = req.body;
    const currentUserId = req.userId;

    if (!status) {
      return res.status(400).json({ error: 'status is required' });
    }

    const meeting = await meetingService.getMeeting(meetingId);
    if (!meeting) {
      return res.status(404).json({ error: 'Meeting not found' });
    }

    // User can only update their own status
    if (userId !== currentUserId) {
      return res.status(403).json({ error: 'Can only update your own status' });
    }

    await meetingService.updateParticipantStatus(meetingId, userId, status);

    res.json({ status: 'ok', message: 'Status updated' });
  } catch (error) {
    console.error('Error updating participant status:', error);
    res.status(500).json({ error: 'Failed to update status' });
  }
});

/**
 * Generate external invitation link
 * POST /api/meetings/:meetingId/generate-link
 */
router.post('/meetings/:meetingId/generate-link', verifyAuthEither, async (req, res) => {
  try {
    const { meetingId } = req.params;
    const { label, expires_at, max_uses } = req.body;
    const userId = req.userId;

    const meeting = await meetingService.getMeeting(meetingId);
    if (!meeting) {
      return res.status(404).json({ error: 'Meeting not found' });
    }

    // Check permissions
    const isOwner = meeting.created_by === userId;
    const participant = meeting.participants?.find(p => p.user_id === userId);
    const isManager = participant?.role === 'meeting_manager' || participant?.role === 'meeting_owner';
    const isAdmin = await hasServerPermission(userId, 'server.manage');

    if (!isOwner && !isManager && !isAdmin) {
      return res.status(403).json({ error: 'Only owner or manager can generate invitation link' });
    }

    const invitation = await meetingService.generateInvitationLink(meetingId, {
      label,
      expires_at,
      max_uses,
      created_by: userId
    });
    
    res.json({
      invitation,
      invitation_token: invitation.token,
      invitation_url: `${req.protocol}://${req.get('host')}/#/join/meeting/${invitation.token}`
    });
  } catch (error) {
    console.error('Error generating invitation link:', error);
    res.status(500).json({ error: 'Failed to generate invitation link' });
  }
});

/**
 * Send email invitation to external participant
 * POST /api/meetings/:meetingId/invite-email
 */
router.post('/meetings/:meetingId/invite-email', verifyAuthEither, async (req, res) => {
  try {
    const { meetingId } = req.params;
    const { email } = req.body;
    const userId = req.userId;
    const username = req.username || req.session?.userinfo?.username || 'A user';

    if (!email) {
      return res.status(400).json({ error: 'Email is required' });
    }

    // Validate email format
    if (!isValidEmail(email)) {
      return res.status(400).json({ error: 'Invalid email format' });
    }

    const meeting = await meetingService.getMeeting(meetingId);
    if (!meeting) {
      return res.status(404).json({ error: 'Meeting not found' });
    }

    // Check permissions (must be owner or manager)
    const isOwner = meeting.created_by === userId;
    const participant = meeting.participants?.find(p => p.user_id === userId);
    const isManager = participant?.role === 'meeting_manager';

    if (!isOwner && !isManager) {
      return res.status(403).json({ error: 'Only owner or manager can send invitations' });
    }

    await sendExternalInviteEmail({
      req,
      meeting,
      meetingId,
      email,
      inviterUserId: userId,
      inviterUsername: username,
    });
    
    res.json({
      status: 'ok',
      message: 'Invitation sent successfully',
      email: email
    });
  } catch (error) {
    console.error('[MEETING_INVITE] Error:', error);
    res.status(500).json({ error: 'Failed to send invitation: ' + error.message });
  }
});

/**
 * Get all invitation tokens for a meeting
 * GET /api/meetings/:meetingId/invitations
 */
router.get('/meetings/:meetingId/invitations', verifyAuthEither, async (req, res) => {
  try {
    const { meetingId } = req.params;
    const userId = req.userId;

    const meeting = await meetingService.getMeeting(meetingId);
    if (!meeting) {
      return res.status(404).json({ error: 'Meeting not found' });
    }

    // Check permissions
    const participant = meeting.participants?.find(p => p.user_id === userId);
    const isOwner = meeting.created_by === userId;
    if (!isOwner && (!participant || (participant.role !== 'meeting_owner' && participant.role !== 'meeting_manager'))) {
      return res.status(403).json({ error: 'Only owner or manager can view invitations' });
    }

    const invitations = await meetingService.getInvitationTokens(meetingId);
    
    // Add URLs to each invitation
    const baseUrl = `${req.protocol}://${req.get('host')}`;
    const invitationsWithUrls = invitations.map(inv => ({
      ...inv,
      invitation_url: `${baseUrl}/#/join/meeting/${inv.token}`
    }));

    res.json({ invitations: invitationsWithUrls });
  } catch (error) {
    console.error('Error getting invitations:', error);
    res.status(500).json({ error: 'Failed to get invitations' });
  }
});

/**
 * Revoke an invitation token
 * POST /api/meetings/:meetingId/invitations/:token/revoke
 */
router.post('/meetings/:meetingId/invitations/:token/revoke', verifyAuthEither, async (req, res) => {
  try {
    const { meetingId, token } = req.params;
    const userId = req.userId;

    const meeting = await meetingService.getMeeting(meetingId);
    if (!meeting) {
      return res.status(404).json({ error: 'Meeting not found' });
    }

    // Check permissions
    const participant = meeting.participants?.find(p => p.user_id === userId);
    const isOwner = meeting.created_by === userId;
    if (!isOwner && (!participant || (participant.role !== 'meeting_owner' && participant.role !== 'meeting_manager'))) {
      return res.status(403).json({ error: 'Only owner or manager can revoke invitations' });
    }

    const success = await meetingService.revokeInvitationToken(token);
    
    if (!success) {
      return res.status(404).json({ error: 'Invitation not found' });
    }

    res.json({ status: 'ok', message: 'Invitation revoked successfully' });
  } catch (error) {
    console.error('Error revoking invitation:', error);
    res.status(500).json({ error: 'Failed to revoke invitation' });
  }
});

/**
 * Delete an invitation token permanently
 * DELETE /api/meetings/:meetingId/invitations/:token
 */
router.delete('/meetings/:meetingId/invitations/:token', verifyAuthEither, async (req, res) => {
  try {
    const { meetingId, token } = req.params;
    const userId = req.userId;

    const meeting = await meetingService.getMeeting(meetingId);
    if (!meeting) {
      return res.status(404).json({ error: 'Meeting not found' });
    }

    // Check permissions
    const participant = meeting.participants?.find(p => p.user_id === userId);
    const isOwner = meeting.created_by === userId;
    if (!isOwner && (!participant || (participant.role !== 'meeting_owner' && participant.role !== 'meeting_manager'))) {
      return res.status(403).json({ error: 'Only owner or manager can delete invitations' });
    }

    const success = await meetingService.deleteInvitationToken(token);
    
    if (!success) {
      return res.status(404).json({ error: 'Invitation not found' });
    }

    res.json({ status: 'ok', message: 'Invitation deleted successfully' });
  } catch (error) {
    console.error('Error deleting invitation:', error);
    res.status(500).json({ error: 'Failed to delete invitation' });
  }
});

module.exports = router;

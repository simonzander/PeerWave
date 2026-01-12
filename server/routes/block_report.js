const express = require('express');
const { BlockedUser, AbuseReport, User } = require('../db/model');
const { verifyAuthEither } = require('../middleware/sessionAuth');
const { hasServerPermission } = require('../db/roleHelpers');
const nodemailer = require('nodemailer');
const config = require('../config/config');
const { sanitizeForLog } = require('../utils/logSanitizer');
const writeQueue = require('../db/writeQueue');
const { Op } = require('sequelize');
const { v4: uuidv4 } = require('uuid');
const router = express.Router();

// Middleware to check if user is admin
async function requireAdmin(req, res, next) {
  const userId = req.userId || req.session.uuid;
  try {
    const hasPermission = await hasServerPermission(userId, 'server.manage');
    if (!hasPermission) {
      return res.status(403).json({ error: 'Admin permission required' });
    }
    next();
  } catch (error) {
    console.error('[REQUIRE_ADMIN] Error checking permissions:', error);
    return res.status(500).json({ error: 'Failed to verify permissions' });
  }
}

// === BLOCKING ENDPOINTS ===

// POST /api/block - Block a user
router.post('/block', verifyAuthEither, async (req, res) => {
  try {
    const blockerUuid = req.userId || req.session.uuid;
    const { blockedUuid, reason } = req.body;

    if (!blockedUuid) {
      return res.status(400).json({ error: 'blockedUuid required' });
    }

    if (blockerUuid === blockedUuid) {
      return res.status(400).json({ error: 'Cannot block yourself' });
    }

    // Check if already blocked
    const existing = await BlockedUser.findOne({
      where: { blocker_uuid: blockerUuid, blocked_uuid: blockedUuid }
    });

    if (existing) {
      return res.status(200).json({ message: 'Already blocked' });
    }

    await writeQueue.enqueue(
      () => BlockedUser.create({
        blocker_uuid: blockerUuid,
        blocked_uuid: blockedUuid,
        reason: reason || 'manual'
      }),
      'blockUser'
    );

    console.log(`[BLOCK] User ${sanitizeForLog(blockerUuid)} blocked ${sanitizeForLog(blockedUuid)}`);
    res.status(200).json({ success: true });
  } catch (error) {
    console.error('[BLOCK] Error:', error);
    res.status(500).json({ error: 'Failed to block user' });
  }
});

// POST /api/unblock - Unblock a user
router.post('/unblock', verifyAuthEither, async (req, res) => {
  try {
    const blockerUuid = req.userId || req.session.uuid;
    const { blockedUuid } = req.body;

    if (!blockedUuid) {
      return res.status(400).json({ error: 'blockedUuid required' });
    }

    await writeQueue.enqueue(
      () => BlockedUser.destroy({
        where: { blocker_uuid: blockerUuid, blocked_uuid: blockedUuid }
      }),
      'unblockUser'
    );

    console.log(`[BLOCK] User ${sanitizeForLog(blockerUuid)} unblocked ${sanitizeForLog(blockedUuid)}`);
    res.status(200).json({ success: true });
  } catch (error) {
    console.error('[UNBLOCK] Error:', error);
    res.status(500).json({ error: 'Failed to unblock user' });
  }
});

// GET /api/blocked-users - Get list of blocked users
router.get('/blocked-users', verifyAuthEither, async (req, res) => {
  try {
    const blockerUuid = req.userId || req.session.uuid;

    const blocked = await BlockedUser.findAll({
      where: { blocker_uuid: blockerUuid },
      include: [{
        model: User,
        as: 'blockedUser',
        attributes: ['uuid', 'displayName', 'email']
      }],
      order: [['blocked_at', 'DESC']]
    });

    res.status(200).json(blocked);
  } catch (error) {
    console.error('[BLOCKED_LIST] Error:', error);
    res.status(500).json({ error: 'Failed to fetch blocked users' });
  }
});

// GET /api/check-blocked/:targetUuid - Check if specific user is blocked
router.get('/check-blocked/:targetUuid', verifyAuthEither, async (req, res) => {
  try {
    const userId = req.userId || req.session.uuid;
    const { targetUuid } = req.params;

    // Check both directions (A blocks B OR B blocks A)
    const blocked = await BlockedUser.findOne({
      where: {
        [Op.or]: [
          { blocker_uuid: userId, blocked_uuid: targetUuid },
          { blocker_uuid: targetUuid, blocked_uuid: userId }
        ]
      }
    });

    res.status(200).json({
      blocked: !!blocked,
      direction: blocked
        ? (blocked.blocker_uuid === userId ? 'you_blocked' : 'they_blocked')
        : null
    });
  } catch (error) {
    console.error('[CHECK_BLOCKED] Error:', error);
    res.status(500).json({ error: 'Failed to check block status' });
  }
});

// === ABUSE REPORT ENDPOINTS ===

// POST /api/report-abuse - Submit abuse report (also blocks user)
router.post('/report-abuse', verifyAuthEither, async (req, res) => {
  try {
    const reporterUuid = req.userId || req.session.uuid;
    const { reportedUuid, description, photos } = req.body;

    if (!reportedUuid || !description) {
      return res.status(400).json({ error: 'reportedUuid and description required' });
    }

    if (reporterUuid === reportedUuid) {
      return res.status(400).json({ error: 'Cannot report yourself' });
    }

    // Validate photos (max 5, base64 format)
    if (photos && (!Array.isArray(photos) || photos.length > 5)) {
      return res.status(400).json({ error: 'Maximum 5 photos allowed' });
    }

    const reportUuid = uuidv4();

    // Create report
    await writeQueue.enqueue(
      () => AbuseReport.create({
        report_uuid: reportUuid,
        reporter_uuid: reporterUuid,
        reported_uuid: reportedUuid,
        description,
        photos: photos ? JSON.stringify(photos) : null,
        status: 'pending'
      }),
      'createAbuseReport'
    );

    // Auto-block the reported user (if not already blocked)
    try {
      await writeQueue.enqueue(
        () => BlockedUser.findOrCreate({
          where: {
            blocker_uuid: reporterUuid,
            blocked_uuid: reportedUuid
          },
          defaults: {
            blocker_uuid: reporterUuid,
            blocked_uuid: reportedUuid,
            reason: 'after_report'
          }
        }),
        'blockUserAfterReport'
      );
    } catch (blockError) {
      console.warn('[ABUSE_REPORT] Failed to auto-block user:', blockError);
      // Continue even if blocking fails
    }

    // Send email to admins
    try {
      // Get users with server.manage permission
      const { getUsersWithPermission } = require('../db/roleHelpers');
      const admins = await getUsersWithPermission('server.manage');

      if (config.smtp && admins && admins.length > 0) {
        const transporter = nodemailer.createTransport(config.smtp);
        const reporter = await User.findOne({ where: { uuid: reporterUuid } });
        const reported = await User.findOne({ where: { uuid: reportedUuid } });

        const emailPromises = admins.map(admin => 
          transporter.sendMail({
            from: config.smtp.senderaddress,
            to: admin.email,
            subject: '⚠️ New Abuse Report - PeerWave',
            html: `
              <h2>New Abuse Report Submitted</h2>
              <p><strong>Reporter:</strong> ${reporter?.displayName || 'Unknown'} (${reporter?.email || 'Unknown'})</p>
              <p><strong>Reported User:</strong> ${reported?.displayName || 'Unknown'} (${reported?.email || 'Unknown'})</p>
              <p><strong>Description:</strong></p>
              <p>${description}</p>
              <p><strong>Report ID:</strong> ${reportUuid}</p>
              <p><a href="${config.serverUrl || 'http://localhost'}/app/settings/abuse-center">View in Abuse Center</a></p>
            `
          }).catch(err => console.error('[ABUSE_REPORT] Email error:', err))
        );

        await Promise.all(emailPromises);
        console.log(`[ABUSE_REPORT] Notification emails sent to ${admins.length} admin(s)`);
      }
    } catch (emailError) {
      console.error('[ABUSE_REPORT] Failed to send admin emails:', emailError);
      // Continue even if email fails
    }

    console.log(`[ABUSE_REPORT] ${sanitizeForLog(reporterUuid)} reported ${sanitizeForLog(reportedUuid)}`);
    res.status(200).json({ success: true, reportUuid });
  } catch (error) {
    console.error('[ABUSE_REPORT] Error:', error);
    res.status(500).json({ error: 'Failed to submit report' });
  }
});

// GET /api/abuse-reports - Get all abuse reports (admin only)
router.get('/abuse-reports', verifyAuthEither, requireAdmin, async (req, res) => {
  try {
    const { status } = req.query; // Filter by status: pending, under_review, resolved, dismissed

    const where = status ? { status } : {};

    const reports = await AbuseReport.findAll({
      where,
      include: [
        { model: User, as: 'reporter', attributes: ['uuid', 'displayName', 'email'] },
        { model: User, as: 'reported', attributes: ['uuid', 'displayName', 'email'] },
        { model: User, as: 'resolver', attributes: ['uuid', 'displayName'], required: false }
      ],
      order: [['created_at', 'DESC']]
    });

    res.status(200).json(reports);
  } catch (error) {
    console.error('[ABUSE_REPORTS] Error:', error);
    res.status(500).json({ error: 'Failed to fetch reports' });
  }
});

// PUT /api/abuse-reports/:reportUuid/status - Update report status (admin only)
router.put('/abuse-reports/:reportUuid/status', verifyAuthEither, requireAdmin, async (req, res) => {
  try {
    const { reportUuid } = req.params;
    const { status, adminNotes } = req.body;
    const adminUuid = req.userId || req.session.uuid;

    const validStatuses = ['pending', 'under_review', 'resolved', 'dismissed'];
    if (!validStatuses.includes(status)) {
      return res.status(400).json({ error: 'Invalid status' });
    }

    const updateData = { status };
    if (adminNotes !== undefined) updateData.admin_notes = adminNotes;
    if (status === 'resolved' || status === 'dismissed') {
      updateData.resolved_by = adminUuid;
      updateData.resolved_at = new Date();
    }

    await writeQueue.enqueue(
      () => AbuseReport.update(updateData, { where: { report_uuid: reportUuid } }),
      'updateReportStatus'
    );

    console.log(`[ABUSE_REPORT] Report ${sanitizeForLog(reportUuid)} status updated to ${status}`);
    res.status(200).json({ success: true });
  } catch (error) {
    console.error('[UPDATE_REPORT] Error:', error);
    res.status(500).json({ error: 'Failed to update report' });
  }
});

// DELETE /api/abuse-reports/:reportUuid - Delete report (admin only, requires confirmation)
router.delete('/abuse-reports/:reportUuid', verifyAuthEither, requireAdmin, async (req, res) => {
  try {
    const { reportUuid } = req.params;
    const { confirmed } = req.body;

    if (!confirmed) {
      return res.status(400).json({ error: 'Confirmation required' });
    }

    await writeQueue.enqueue(
      () => AbuseReport.destroy({ where: { report_uuid: reportUuid } }),
      'deleteReport'
    );

    console.log(`[ABUSE_REPORT] Report ${sanitizeForLog(reportUuid)} deleted by admin`);
    res.status(200).json({ success: true });
  } catch (error) {
    console.error('[DELETE_REPORT] Error:', error);
    res.status(500).json({ error: 'Failed to delete report' });
  }
});

module.exports = router;

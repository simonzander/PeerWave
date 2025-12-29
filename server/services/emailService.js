const nodemailer = require('nodemailer');

let cachedTransporter = null;
let cachedSmtpConfigKey = null;

function getSmtpConfigKey(smtpConfig) {
  try {
    return JSON.stringify({
      host: smtpConfig?.host,
      port: smtpConfig?.port,
      secure: smtpConfig?.secure,
      authUser: smtpConfig?.auth?.user,
    });
  } catch {
    return String(Date.now());
  }
}

function getTransporter(smtpConfig) {
  const key = getSmtpConfigKey(smtpConfig);
  if (!cachedTransporter || cachedSmtpConfigKey !== key) {
    cachedTransporter = nodemailer.createTransport(smtpConfig);
    cachedSmtpConfigKey = key;
  }
  return cachedTransporter;
}

async function sendEmail({ smtpConfig, message }) {
  if (!smtpConfig) {
    throw new Error('SMTP config missing');
  }
  if (!message?.to) {
    throw new Error('Email recipient missing');
  }

  const transporter = getTransporter(smtpConfig);
  return transporter.sendMail(message);
}

module.exports = {
  sendEmail,
};

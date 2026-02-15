const { Item } = require('../db/model');

function normalizePagination({ rawLimit, rawOffset, defaultLimit = 20 }) {
  const limit = Number.isFinite(parseInt(rawLimit, 10))
    ? parseInt(rawLimit, 10)
    : defaultLimit;
  const offset = Number.isFinite(parseInt(rawOffset, 10))
    ? parseInt(rawOffset, 10)
    : 0;

  return { limit, offset };
}

async function fetchPendingMessagesForDevice({
  userId,
  deviceId,
  limit,
  offset,
}) {
  const items = await Item.findAll({
    where: {
      receiver: userId,
      deviceReceiver: deviceId,
    },
    limit,
    offset,
    order: [['createdAt', 'ASC']],
  });

  const hasMore = items.length === limit;
  const responseItems = items.map(item => ({
    sender: item.sender,
    senderDeviceId: item.deviceSender,
    recipient: item.receiver,
    type: item.type,
    payload: item.payload,
    cipherType: item.cipherType,
    itemId: item.itemId,
  }));

  return { responseItems, hasMore };
}

module.exports = {
  normalizePagination,
  fetchPendingMessagesForDevice,
};

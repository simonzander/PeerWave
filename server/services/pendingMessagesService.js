const { Item, GroupItem, GroupItemRead, ChannelMembers } = require('../db/model');
const { Op } = require('sequelize');

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

async function fetchPendingMessagesForDeviceV2({
  userId,
  deviceId,
  limit,
  offset,
}) {
  const fetchLimit = limit + offset;
  const fetchLimitPlusOne = fetchLimit + 1;

  const directItemsRaw = await Item.findAll({
    where: {
      receiver: userId,
      deviceReceiver: deviceId,
    },
    limit: fetchLimitPlusOne,
    order: [['createdAt', 'ASC']],
  });
  const directHasMore = directItemsRaw.length > fetchLimit;
  const directItems = directItemsRaw.slice(0, fetchLimit);

  const directResponse = directItems.map(item => ({
    sender: item.sender,
    senderDeviceId: item.deviceSender,
    recipient: item.receiver,
    type: item.type,
    payload: item.payload,
    cipherType: item.cipherType,
    itemId: item.itemId,
    originalRecipient: item.originalRecipient || null,
    timestamp: item.createdAt?.toISOString?.() ?? item.createdAt,
  }));

  const channelMemberships = await ChannelMembers.findAll({
    where: { userId },
    attributes: ['channelId'],
  });
  const channelIds = channelMemberships.map(row => row.channelId);

  let groupResponse = [];
  let groupHasMore = false;
  if (channelIds.length > 0) {
    const readRows = await GroupItemRead.findAll({
      where: { userId, deviceId },
      attributes: ['itemId'],
    });
    const readItemIds = readRows.map(row => row.itemId);

    const groupWhere = {
      channel: { [Op.in]: channelIds },
    };
    if (readItemIds.length > 0) {
      groupWhere.uuid = { [Op.notIn]: readItemIds };
    }

    const groupItemsRaw = await GroupItem.findAll({
      where: groupWhere,
      limit: fetchLimitPlusOne,
      order: [['timestamp', 'ASC']],
    });

    groupHasMore = groupItemsRaw.length > fetchLimit;
    const groupItems = groupItemsRaw.slice(0, fetchLimit);

    groupResponse = groupItems.map(item => ({
      sender: item.sender,
      senderDeviceId: item.senderDevice,
      type: item.type,
      payload: item.payload,
      cipherType: item.cipherType,
      itemId: item.itemId,
      channel: item.channel,
      channelId: item.channel,
      timestamp: item.timestamp?.toISOString?.() ?? item.timestamp,
    }));
  }

  const merged = [...directResponse, ...groupResponse].sort((a, b) => {
    const aTime = Date.parse(a.timestamp || '') || 0;
    const bTime = Date.parse(b.timestamp || '') || 0;
    return aTime - bTime;
  });

  const responseItems = merged.slice(offset, offset + limit);
  const hasMore = directHasMore || groupHasMore || merged.length > offset + limit;

  return { responseItems, hasMore, totalAvailable: merged.length };
}

module.exports = {
  normalizePagination,
  fetchPendingMessagesForDevice,
  fetchPendingMessagesForDeviceV2,
};

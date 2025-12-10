const { sequelize } = require('../db/model');

async function up() {
  const queryInterface = sequelize.getQueryInterface();

  // Helper function to check if table exists
  const tableExists = async (tableName) => {
    const tables = await queryInterface.showAllTables();
    return tables.includes(tableName);
  };

  // Helper function to check if index exists
  const indexExists = async (tableName, indexName) => {
    try {
      const [results] = await sequelize.query(
        `SELECT name FROM sqlite_master WHERE type='index' AND name='${indexName}'`
      );
      return results.length > 0;
    } catch (error) {
      return false;
    }
  };

  // Create meetings table (stores both scheduled meetings and instant calls)
  if (!(await tableExists('meetings'))) {
    await queryInterface.createTable('meetings', {
    meeting_id: {
      type: sequelize.Sequelize.STRING,
      primaryKey: true,
      // Format: 'mtg_abc123' (meetings) or 'call_abc123' (instant calls)
    },
    title: {
      type: sequelize.Sequelize.STRING,
      allowNull: false
    },
    description: {
      type: sequelize.Sequelize.TEXT,
      allowNull: true
    },
    created_by: {
      type: sequelize.Sequelize.STRING,
      allowNull: false
    },
    start_time: {
      type: sequelize.Sequelize.DATE,
      allowNull: false
    },
    end_time: {
      type: sequelize.Sequelize.DATE,
      allowNull: false
    },
    status: {
      type: sequelize.Sequelize.STRING,
      allowNull: false,
      defaultValue: 'scheduled'
      // Values: 'scheduled', 'in_progress', 'ended', 'cancelled'
    },
    is_instant_call: {
      type: sequelize.Sequelize.BOOLEAN,
      allowNull: false,
      defaultValue: false
      // TRUE = instant call, FALSE = scheduled meeting
    },
    source_channel_id: {
      type: sequelize.Sequelize.STRING,
      allowNull: true
      // Channel where call was initiated (for instant calls)
    },
    source_user_id: {
      type: sequelize.Sequelize.STRING,
      allowNull: true
      // User who was called (for 1:1 instant calls)
    },
    allow_external: {
      type: sequelize.Sequelize.BOOLEAN,
      allowNull: false,
      defaultValue: false
    },
    invitation_token: {
      type: sequelize.Sequelize.STRING,
      allowNull: true,
      unique: true
      // For external participants
    },
    voice_only: {
      type: sequelize.Sequelize.BOOLEAN,
      allowNull: false,
      defaultValue: false
    },
    mute_on_join: {
      type: sequelize.Sequelize.BOOLEAN,
      allowNull: false,
      defaultValue: false
    },
    max_participants: {
      type: sequelize.Sequelize.INTEGER,
      allowNull: true
    },
    created_at: {
      type: sequelize.Sequelize.DATE,
      allowNull: false,
      defaultValue: sequelize.Sequelize.literal('CURRENT_TIMESTAMP')
    },
    updated_at: {
      type: sequelize.Sequelize.DATE,
      allowNull: false,
      defaultValue: sequelize.Sequelize.literal('CURRENT_TIMESTAMP')
    }
  });
  }

  // Create indexes for meetings (with existence checks)
  if (!(await indexExists('meetings', 'meetings_created_by'))) {
    await queryInterface.addIndex('meetings', ['created_by'], { name: 'meetings_created_by' });
  }
  if (!(await indexExists('meetings', 'meetings_start_time'))) {
    await queryInterface.addIndex('meetings', ['start_time'], { name: 'meetings_start_time' });
  }
  if (!(await indexExists('meetings', 'meetings_end_time'))) {
    await queryInterface.addIndex('meetings', ['end_time'], { name: 'meetings_end_time' });
  }
  if (!(await indexExists('meetings', 'meetings_status'))) {
    await queryInterface.addIndex('meetings', ['status'], { name: 'meetings_status' });
  }
  if (!(await indexExists('meetings', 'meetings_is_instant_call'))) {
    await queryInterface.addIndex('meetings', ['is_instant_call'], { name: 'meetings_is_instant_call' });
  }

  // Create meeting_participants table
  if (!(await tableExists('meeting_participants'))) {
  await queryInterface.createTable('meeting_participants', {
    participant_id: {
      type: sequelize.Sequelize.INTEGER,
      primaryKey: true,
      autoIncrement: true
    },
    meeting_id: {
      type: sequelize.Sequelize.STRING,
      allowNull: false,
      references: {
        model: 'meetings',
        key: 'meeting_id'
      },
      onDelete: 'CASCADE'
    },
    user_id: {
      type: sequelize.Sequelize.STRING,
      allowNull: false
    },
    role: {
      type: sequelize.Sequelize.STRING,
      allowNull: false,
      defaultValue: 'meeting_member'
      // Values: 'meeting_owner', 'meeting_manager', 'meeting_member'
    },
    status: {
      type: sequelize.Sequelize.STRING,
      allowNull: false,
      defaultValue: 'invited'
      // Values: 'invited', 'accepted', 'declined', 'attended', 'ringing', 'left'
    },
    invited_at: {
      type: sequelize.Sequelize.DATE,
      allowNull: false,
      defaultValue: sequelize.Sequelize.literal('CURRENT_TIMESTAMP')
    },
    accepted_at: {
      type: sequelize.Sequelize.DATE,
      allowNull: true
    },
    joined_at: {
      type: sequelize.Sequelize.DATE,
      allowNull: true
    },
    left_at: {
      type: sequelize.Sequelize.DATE,
      allowNull: true
    }
  });
  }

  // Create indexes for meeting_participants (with existence checks)
  if (!(await indexExists('meeting_participants', 'meeting_participants_meeting_id_user_id'))) {
    await queryInterface.addIndex('meeting_participants', ['meeting_id', 'user_id'], { 
      unique: true, 
      name: 'meeting_participants_meeting_id_user_id' 
    });
  }
  if (!(await indexExists('meeting_participants', 'meeting_participants_user_id'))) {
    await queryInterface.addIndex('meeting_participants', ['user_id'], { 
      name: 'meeting_participants_user_id' 
    });
  }

  // Create meeting_roles table
  if (!(await tableExists('meeting_roles'))) {
  await queryInterface.createTable('meeting_roles', {
    role_id: {
      type: sequelize.Sequelize.STRING,
      primaryKey: true
    },
    role_name: {
      type: sequelize.Sequelize.STRING,
      allowNull: false
    },
    is_default: {
      type: sequelize.Sequelize.BOOLEAN,
      allowNull: false,
      defaultValue: false
    },
    can_start_meeting: {
      type: sequelize.Sequelize.BOOLEAN,
      allowNull: false,
      defaultValue: false
    },
    can_invite_participants: {
      type: sequelize.Sequelize.BOOLEAN,
      allowNull: false,
      defaultValue: false
    },
    can_remove_participants: {
      type: sequelize.Sequelize.BOOLEAN,
      allowNull: false,
      defaultValue: false
    },
    can_mute_participants: {
      type: sequelize.Sequelize.BOOLEAN,
      allowNull: false,
      defaultValue: false
    },
    can_end_meeting: {
      type: sequelize.Sequelize.BOOLEAN,
      allowNull: false,
      defaultValue: false
    },
    can_share_screen: {
      type: sequelize.Sequelize.BOOLEAN,
      allowNull: false,
      defaultValue: false
    },
    can_enable_camera: {
      type: sequelize.Sequelize.BOOLEAN,
      allowNull: false,
      defaultValue: false
    },
    can_enable_microphone: {
      type: sequelize.Sequelize.BOOLEAN,
      allowNull: false,
      defaultValue: false
    },
    created_at: {
      type: sequelize.Sequelize.DATE,
      allowNull: false,
      defaultValue: sequelize.Sequelize.literal('CURRENT_TIMESTAMP')
    }
  });
  }

  // Pre-populate default meeting roles (check if already exists)
  const [existingRoles] = await sequelize.query(
    "SELECT COUNT(*) as count FROM meeting_roles WHERE role_id IN ('meeting_owner', 'meeting_manager', 'meeting_member')"
  );
  
  if (existingRoles[0].count === 0) {
    await queryInterface.bulkInsert('meeting_roles', [
    {
      role_id: 'meeting_owner',
      role_name: 'Owner',
      is_default: true,
      can_start_meeting: true,
      can_invite_participants: true,
      can_remove_participants: true,
      can_mute_participants: true,
      can_end_meeting: true,
      can_share_screen: true,
      can_enable_camera: true,
      can_enable_microphone: true,
      created_at: new Date()
    },
    {
      role_id: 'meeting_manager',
      role_name: 'Manager',
      is_default: true,
      can_start_meeting: true,
      can_invite_participants: true,
      can_remove_participants: false,
      can_mute_participants: true,
      can_end_meeting: false,
      can_share_screen: true,
      can_enable_camera: true,
      can_enable_microphone: true,
      created_at: new Date()
    },
    {
      role_id: 'meeting_member',
      role_name: 'Member',
      is_default: true,
      can_start_meeting: false,
      can_invite_participants: false,
      can_remove_participants: false,
      can_mute_participants: false,
      can_end_meeting: false,
      can_share_screen: true,
      can_enable_camera: true,
      can_enable_microphone: true,
      created_at: new Date()
    }
  ]);
  }

  // Create user_presence table (1-minute heartbeat tracking)
  if (!(await tableExists('user_presence'))) {
  await queryInterface.createTable('user_presence', {
    user_id: {
      type: sequelize.Sequelize.STRING,
      primaryKey: true
    },
    status: {
      type: sequelize.Sequelize.STRING,
      allowNull: false,
      defaultValue: 'offline'
      // Values: 'online', 'offline'
    },
    last_heartbeat: {
      type: sequelize.Sequelize.DATE,
      allowNull: false,
      defaultValue: sequelize.Sequelize.literal('CURRENT_TIMESTAMP')
    },
    connection_id: {
      type: sequelize.Sequelize.STRING,
      allowNull: true
      // Socket.IO connection ID
    },
    updated_at: {
      type: sequelize.Sequelize.DATE,
      allowNull: false,
      defaultValue: sequelize.Sequelize.literal('CURRENT_TIMESTAMP')
    }
  });
  }

  // Create index for last_heartbeat
  if (!(await indexExists('user_presence', 'user_presence_last_heartbeat'))) {
    await queryInterface.addIndex('user_presence', ['last_heartbeat'], { 
      name: 'user_presence_last_heartbeat' 
    });
  }

  // Create external_participants table (temporary guests for meetings)
  if (!(await tableExists('external_participants'))) {
  await queryInterface.createTable('external_participants', {
    session_id: {
      type: sequelize.Sequelize.STRING,
      primaryKey: true
    },
    meeting_id: {
      type: sequelize.Sequelize.STRING,
      allowNull: false,
      references: {
        model: 'meetings',
        key: 'meeting_id'
      },
      onDelete: 'CASCADE'
    },
    display_name: {
      type: sequelize.Sequelize.STRING,
      allowNull: false
    },
    identity_key_public: {
      type: sequelize.Sequelize.TEXT,
      allowNull: false
    },
    signed_pre_key: {
      type: sequelize.Sequelize.TEXT,
      allowNull: false
    },
    pre_keys: {
      type: sequelize.Sequelize.TEXT,
      allowNull: false
      // JSON array of pre-keys
    },
    admission_status: {
      type: sequelize.Sequelize.STRING,
      allowNull: false,
      defaultValue: 'waiting'
      // Values: 'waiting', 'admitted', 'declined'
    },
    admitted_by: {
      type: sequelize.Sequelize.STRING,
      allowNull: true
    },
    joined_at: {
      type: sequelize.Sequelize.DATE,
      allowNull: true
    },
    left_at: {
      type: sequelize.Sequelize.DATE,
      allowNull: true
    },
    expires_at: {
      type: sequelize.Sequelize.DATE,
      allowNull: false
      // Max 24 hours from creation
    },
    created_at: {
      type: sequelize.Sequelize.DATE,
      allowNull: false,
      defaultValue: sequelize.Sequelize.literal('CURRENT_TIMESTAMP')
    }
  });
  }

  // Create indexes for external_participants (with existence checks)
  if (!(await indexExists('external_participants', 'external_participants_meeting_id'))) {
    await queryInterface.addIndex('external_participants', ['meeting_id'], { 
      name: 'external_participants_meeting_id' 
    });
  }
  if (!(await indexExists('external_participants', 'external_participants_admission_status'))) {
    await queryInterface.addIndex('external_participants', ['admission_status'], { 
      name: 'external_participants_admission_status' 
    });
  }

  // Create meeting_notifications table (track which users have been notified)
  if (!(await tableExists('meeting_notifications'))) {
  await queryInterface.createTable('meeting_notifications', {
    notification_id: {
      type: sequelize.Sequelize.INTEGER,
      primaryKey: true,
      autoIncrement: true
    },
    meeting_id: {
      type: sequelize.Sequelize.STRING,
      allowNull: false,
      references: {
        model: 'meetings',
        key: 'meeting_id'
      },
      onDelete: 'CASCADE'
    },
    user_id: {
      type: sequelize.Sequelize.STRING,
      allowNull: false
    },
    notification_type: {
      type: sequelize.Sequelize.STRING,
      allowNull: false
      // Values: '15_min_warning', 'start_time', 'live_invite'
    },
    sent_at: {
      type: sequelize.Sequelize.DATE,
      allowNull: false,
      defaultValue: sequelize.Sequelize.literal('CURRENT_TIMESTAMP')
    },
    dismissed: {
      type: sequelize.Sequelize.BOOLEAN,
      allowNull: false,
      defaultValue: false
    }
  });
  }

  // Create indexes for meeting_notifications (with existence check)
  if (!(await indexExists('meeting_notifications', 'meeting_notifications_meeting_id_user_id'))) {
    await queryInterface.addIndex('meeting_notifications', ['meeting_id', 'user_id'], { 
      name: 'meeting_notifications_meeting_id_user_id' 
    });
  }

  console.log('✓ Meetings system tables created');
}

async function down() {
  const queryInterface = sequelize.getQueryInterface();
  
  await queryInterface.dropTable('meeting_notifications');
  await queryInterface.dropTable('external_participants');
  await queryInterface.dropTable('user_presence');
  await queryInterface.dropTable('meeting_participants');
  await queryInterface.dropTable('meeting_roles');
  await queryInterface.dropTable('meetings');
  
  console.log('✓ Meetings system tables dropped');
}

module.exports = { up, down };

// Auto-run migration if executed directly
if (require.main === module) {
  up()
    .then(() => {
      console.log('Migration completed successfully');
      process.exit(0);
    })
    .catch(err => {
      console.error('Migration failed:', err);
      process.exit(1);
    });
}

const user = db.users.findOne({ user_id: {{ .user_id }} });

  if (!user) {
    print('Error: User not found');
    quit(1);
  }

  const result = db.users.updateOne(
    { user_id: {{ .user_id }} },
    {
      $set: {
        email: '{{ .email }}',
        updated_at: new Date()
      }
    }
  );

  if (result.modifiedCount === 1) {
    print('Email updated successfully');
  } else if (result.matchedCount === 1) {
    print('No changes - email already set');
  } else {
    print('Update failed');
    quit(1);
  }

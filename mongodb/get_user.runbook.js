db.users.find ({ user_id: {{ .user_id | type "number" }} })

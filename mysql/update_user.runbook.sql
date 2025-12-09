UPDATE users
SET email = '{{ .email | required "New email is required" }}'
WHERE user_id = {{ .user_id | type "number" | required "User ID is required"}}
;

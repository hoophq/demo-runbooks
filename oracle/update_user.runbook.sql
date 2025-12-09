UPDATE admin.users
SET email = '{{ .email | required }}'
WHERE user_id = {{ .user_id | type "number" | required }}
;
